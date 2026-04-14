const std = @import("std");
const types = @import("types.zig");
const http = @import("http_helpers.zig");
const shell = @import("shell.zig");
const sync = @import("sync.zig");

const release_id_raw = @embedFile("RELEASE_ID");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const root = std.posix.getenv("PACKBASE_ROOT") orelse "public";
    const port_text = std.posix.getenv("PACKBASE_PORT") orelse "8080";
    const token = std.posix.getenv("PACKBASE_TOKEN");
    const source_url = std.posix.getenv("PACKBASE_SOURCE") orelse "https://zub.javanile.org/packbase.json";
    const port = try std.fmt.parseInt(u16, port_text, 10);

    const address = try std.net.Address.parseIp("0.0.0.0", port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.log.info("serving {s} on 0.0.0.0:{d}", .{ root, port });

    while (true) {
        var connection = try server.accept();
        defer connection.stream.close();

        handleConnection(allocator, &connection, root, token, source_url) catch |err| {
            std.log.warn("request failed: {s}", .{@errorName(err)});
        };
    }
}

fn handleConnection(
    allocator: std.mem.Allocator,
    connection: *std.net.Server.Connection,
    root: []const u8,
    token: ?[]const u8,
    source_url: []const u8,
) !void {
    const buffer = try allocator.alloc(u8, 65536);
    defer allocator.free(buffer);
    const bytes_read = try connection.stream.read(buffer);
    if (bytes_read == 0) return;

    const raw = buffer[0..bytes_read];
    const request = try http.parseRequest(raw);
    const path = http.requestPath(request.target);
    const head_only = std.mem.eql(u8, request.method, "HEAD");

    if (std.mem.eql(u8, request.method, "POST")) {
        if (std.mem.eql(u8, path, "/api/fetch")) {
            try handleFetch(allocator, connection, root, token, raw);
            return;
        }
        if (std.mem.eql(u8, path, "/api/update")) {
            try handleUpdate(allocator, connection, root, source_url);
            return;
        }
    }

    if (!std.mem.eql(u8, request.method, "GET") and !head_only) {
        try http.sendSimpleResponse(connection, "405 Method Not Allowed", "text/plain", "method not allowed\n");
        return;
    }

    if (std.mem.eql(u8, path, "/api/list")) {
        try handleList(allocator, connection, root, head_only);
        return;
    }
    if (std.mem.eql(u8, path, "/api/info")) {
        try handleInfo(allocator, connection, root, head_only);
        return;
    }
    if (std.mem.eql(u8, path, "/")) {
        try http.sendLandingPage(connection, head_only);
        return;
    }

    if (std.mem.eql(u8, request.method, "GET") or std.mem.eql(u8, request.method, "POST")) {
        if (http.isSmartHttpRequest(path)) {
            try handleSmartHttp(allocator, connection, root, request, raw, head_only);
            return;
        }
    }

    const routed_path = try http.routePath(allocator, path);
    defer allocator.free(routed_path);
    const resolved = try http.resolvePath(allocator, root, routed_path);
    defer allocator.free(resolved);

    var file = std.fs.cwd().openFile(resolved, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try http.sendSimpleResponse(connection, "404 Not Found", "text/plain", "not found\n");
            return;
        },
        error.IsDir => {
            try http.sendSimpleResponse(connection, "403 Forbidden", "text/plain", "directory listing disabled\n");
            return;
        },
        else => return err,
    };
    defer file.close();

    const stat = try file.stat();
    try http.writeHeaders(connection, "200 OK", http.contentType(resolved), stat.size);
    if (head_only) return;

    var file_buf: [4096]u8 = undefined;
    while (true) {
        const n = try file.read(&file_buf);
        if (n == 0) break;
        try connection.stream.writeAll(file_buf[0..n]);
    }
}

fn handleFetch(
    allocator: std.mem.Allocator,
    connection: *std.net.Server.Connection,
    root: []const u8,
    token: ?[]const u8,
    raw: []const u8,
) !void {
    if (!try authorizeRequest(connection, token, raw)) return;

    const body = http.findBody(raw);
    if (body.len == 0) {
        try http.sendSimpleResponse(connection, "400 Bad Request", "text/plain", "empty body\n");
        return;
    }

    const parsed = std.json.parseFromSlice(types.FetchPayload, allocator, body, .{}) catch {
        try http.sendSimpleResponse(connection, "400 Bad Request", "text/plain", "invalid json\n");
        return;
    };
    defer parsed.deinit();
    const url = parsed.value.url;

    const http_url = if (std.mem.startsWith(u8, url, "git+")) url[4..] else url;
    const slash_pos = std.mem.lastIndexOfScalar(u8, http_url, '/') orelse 0;
    const raw_name = http_url[slash_pos + 1 ..];
    const pkg_name = if (std.mem.endsWith(u8, raw_name, ".git")) raw_name[0 .. raw_name.len - 4] else raw_name;

    const tmp_path = try std.fmt.allocPrint(allocator, "/tmp/packbase-{d}", .{std.time.nanoTimestamp()});
    defer allocator.free(tmp_path);
    defer std.fs.deleteTreeAbsolute(tmp_path) catch {};

    shell.runCommand(allocator, &[_][]const u8{ "git", "clone", "--quiet", http_url, tmp_path }) catch {
        try http.sendSimpleResponse(connection, "502 Bad Gateway", "text/plain", "git clone failed\n");
        return;
    };

    const tag_raw = shell.runCommandOutput(allocator, &[_][]const u8{
        "git", "-C", tmp_path, "describe", "--tags", "--abbrev=0",
    }) catch {
        try http.sendSimpleResponse(connection, "422 Unprocessable Entity", "text/plain", "no tags found\n");
        return;
    };
    defer allocator.free(tag_raw);
    const tag = std.mem.trim(u8, tag_raw, " \t\r\n");

    const pkg_dir = try std.fmt.allocPrint(allocator, "{s}/p/{s}/tag", .{ root, pkg_name });
    defer allocator.free(pkg_dir);
    try shell.runCommand(allocator, &[_][]const u8{ "mkdir", "-p", pkg_dir });

    const tarball_path = try std.fmt.allocPrint(allocator, "{s}/{s}.tar.gz", .{ pkg_dir, tag });
    defer allocator.free(tarball_path);

    shell.runCommand(allocator, &[_][]const u8{ "git", "-C", tmp_path, "checkout", "--quiet", tag }) catch {
        try http.sendSimpleResponse(connection, "500 Internal Server Error", "text/plain", "checkout failed\n");
        return;
    };

    const stage_path = try std.fmt.allocPrint(allocator, "{s}_stage", .{tmp_path});
    defer allocator.free(stage_path);
    defer std.fs.deleteTreeAbsolute(stage_path) catch {};

    try shell.runCommand(allocator, &[_][]const u8{ "cp", "-r", tmp_path, stage_path });
    const stage_git = try std.fs.path.join(allocator, &.{ stage_path, ".git" });
    defer allocator.free(stage_git);
    std.fs.deleteTreeAbsolute(stage_git) catch {};

    const stage_parent = std.fs.path.dirname(stage_path) orelse "/tmp";
    const stage_base = std.fs.path.basename(stage_path);
    shell.runCommand(allocator, &[_][]const u8{ "tar", "czf", tarball_path, "-C", stage_parent, stage_base }) catch {
        try http.sendSimpleResponse(connection, "500 Internal Server Error", "text/plain", "archive failed\n");
        return;
    };

    const pkg_url = try std.fmt.allocPrint(allocator, "/p/{s}/tag/{s}.tar.gz", .{ pkg_name, tag });
    defer allocator.free(pkg_url);
    const resp_body = try std.fmt.allocPrint(
        allocator,
        "{{\"status\":\"ok\",\"package\":\"{s}\",\"tag\":\"{s}\",\"url\":\"{s}\"}}\n",
        .{ pkg_name, tag, pkg_url },
    );
    defer allocator.free(resp_body);

    try http.writeHeaders(connection, "200 OK", "application/json", resp_body.len);
    try connection.stream.writeAll(resp_body);
}

fn handleUpdate(
    allocator: std.mem.Allocator,
    connection: *std.net.Server.Connection,
    root: []const u8,
    source_url: []const u8,
) !void {
    var stats = try sync.beginUpdateWindow(allocator, root);
    if (stats.queued or stats.rate_limited) {
        std.log.info("update skipped: {s} retry_after={d}", .{
            if (stats.queued) "queued" else "cooldown",
            stats.retry_after,
        });
        const body = try std.fmt.allocPrint(
            allocator,
            "{{\"status\":\"{s}\",\"retry_after\":{d},\"queued\":{s}}}\n",
            .{
                if (stats.queued) "queued" else "cooldown",
                stats.retry_after,
                if (stats.queued) "true" else "false",
            },
        );
        defer allocator.free(body);
        try http.writeHeaders(connection, "200 OK", "application/json", body.len);
        try connection.stream.writeAll(body);
        return;
    }
    std.log.info("update started source={s}", .{source_url});
    defer sync.finishUpdateWindow(allocator, root, &stats) catch {};

    var source_records = sync.syncSourceCatalog(allocator, root, source_url, &stats) catch |err| {
        std.log.warn("source sync failed: {s}", .{@errorName(err)});
        try http.sendSimpleResponse(connection, "500 Internal Server Error", "text/plain", "source sync failed\n");
        return;
    };
    defer sync.freeSourceRecordList(allocator, &source_records);

    sync.syncSourceRepos(allocator, root, source_records.items, stats.source_changed or stats.source_added != 0 or stats.source_changed_count != 0, &stats) catch |err| {
        std.log.warn("source repo materialization failed: {s}", .{@errorName(err)});
        try http.sendSimpleResponse(connection, "500 Internal Server Error", "text/plain", "source repo sync failed\n");
        return;
    };

    const local_stats = sync.syncPackages(allocator, root) catch |err| {
        std.log.warn("sync failed: {s}", .{@errorName(err)});
        try http.sendSimpleResponse(connection, "500 Internal Server Error", "text/plain", "sync failed\n");
        return;
    };
    stats.repos_scanned = local_stats.repos_scanned;
    stats.packages_synced = local_stats.packages_synced;
    stats.tarballs_created = local_stats.tarballs_created;
    stats.tarballs_present = local_stats.tarballs_present;
    stats.default_seeded = local_stats.default_seeded;

    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"status\":\"ok\",\"repos_scanned\":{d},\"packages_synced\":{d},\"tarballs_created\":{d},\"tarballs_present\":{d},\"default_seeded\":{s},\"source_changed\":{s},\"source_packages\":{d},\"source_added\":{d},\"source_updated\":{d},\"source_removed\":{d},\"source_repo_cloned\":{d},\"source_repo_updated\":{d},\"source_repo_failed\":{d}}}\n",
        .{
            stats.repos_scanned,
            stats.packages_synced,
            stats.tarballs_created,
            stats.tarballs_present,
            if (stats.default_seeded) "true" else "false",
            if (stats.source_changed) "true" else "false",
            stats.source_packages,
            stats.source_added,
            stats.source_changed_count,
            stats.source_removed,
            stats.source_repo_cloned,
            stats.source_repo_updated,
            stats.source_repo_failed,
        },
    );
    defer allocator.free(body);

    std.log.info(
        "update completed repos={d} synced={d} created={d} source_changed={any} source_packages={d} cloned={d} updated={d} failed={d}",
        .{
            stats.repos_scanned,
            stats.packages_synced,
            stats.tarballs_created,
            stats.source_changed,
            stats.source_packages,
            stats.source_repo_cloned,
            stats.source_repo_updated,
            stats.source_repo_failed,
        },
    );
    try http.writeHeaders(connection, "200 OK", "application/json", body.len);
    try connection.stream.writeAll(body);
}

fn handleList(
    allocator: std.mem.Allocator,
    connection: *std.net.Server.Connection,
    root: []const u8,
    head_only: bool,
) !void {
    const body = try sync.listPackagesJson(allocator, root);
    defer allocator.free(body);

    try http.writeHeaders(connection, "200 OK", "application/json", body.len);
    if (!head_only) try connection.stream.writeAll(body);
}

fn handleInfo(
    allocator: std.mem.Allocator,
    connection: *std.net.Server.Connection,
    root: []const u8,
    head_only: bool,
) !void {
    const release_id = std.mem.trimRight(u8, release_id_raw, "\r\n");
    const update_status = try sync.readUpdateStatusJson(allocator, root);
    defer allocator.free(update_status);
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"service\":\"packbase\",\"release\":\"{s}\",\"update\":{s}}}\n",
        .{ release_id, update_status },
    );
    defer allocator.free(body);

    try http.writeHeaders(connection, "200 OK", "application/json", body.len);
    if (!head_only) try connection.stream.writeAll(body);
}

fn authorizeRequest(
    connection: *std.net.Server.Connection,
    token: ?[]const u8,
    raw: []const u8,
) !bool {
    if (token) |expected| {
        const auth = http.findHeader(raw, "Authorization") orelse {
            try http.sendSimpleResponse(connection, "401 Unauthorized", "text/plain", "unauthorized\n");
            return false;
        };
        const prefix = "Bearer ";
        if (!std.mem.startsWith(u8, auth, prefix) or !std.mem.eql(u8, auth[prefix.len..], expected)) {
            try http.sendSimpleResponse(connection, "403 Forbidden", "text/plain", "forbidden\n");
            return false;
        }
    }
    return true;
}

fn handleSmartHttp(
    allocator: std.mem.Allocator,
    connection: *std.net.Server.Connection,
    root: []const u8,
    request: types.Request,
    raw: []const u8,
    head_only: bool,
) !void {
    const path = http.requestPath(request.target);
    const routed = try http.routePath(allocator, path);
    defer allocator.free(routed);

    if (std.mem.startsWith(u8, routed, "/git/")) {
        const after_git = routed[5..];
        const question = std.mem.indexOfScalar(u8, after_git, '?') orelse after_git.len;
        var repo_rel = after_git[0..question];
        if (std.mem.endsWith(u8, repo_rel, "/info/refs")) {
            repo_rel = repo_rel[0 .. repo_rel.len - 10];
        } else if (std.mem.endsWith(u8, repo_rel, "/git-upload-pack")) {
            repo_rel = repo_rel[0 .. repo_rel.len - 15];
        } else if (std.mem.endsWith(u8, repo_rel, "/git-receive-pack")) {
            repo_rel = repo_rel[0 .. repo_rel.len - 17];
        }

        const repo_dir = try std.fs.path.join(allocator, &.{ root, "git", repo_rel });
        defer allocator.free(repo_dir);

        var dir = std.fs.cwd().openDir(repo_dir, .{}) catch {
            try http.sendSimpleResponse(connection, "404 Not Found", "text/plain", "not found\n");
            return;
        };
        defer dir.close();

        if (std.mem.eql(u8, request.method, "GET")) {
            try handleUploadPackAdvertise(allocator, connection, repo_dir, head_only);
            return;
        } else if (std.mem.eql(u8, request.method, "POST")) {
            const content_type = http.findHeader(raw, "Content-Type") orelse "";
            if (std.mem.eql(u8, content_type, "application/x-git-upload-pack-request")) {
                try handleUploadPackRequest(allocator, connection, repo_dir, raw, head_only);
                return;
            }
        }

        try http.sendSimpleResponse(connection, "404 Not Found", "text/plain", "not found\n");
        return;
    }

    try http.sendSimpleResponse(connection, "400 Bad Request", "text/plain", "invalid request\n");
}

fn handleUploadPackAdvertise(
    allocator: std.mem.Allocator,
    connection: *std.net.Server.Connection,
    repo_dir: []const u8,
    head_only: bool,
) !void {
    const output = shell.runCommandOutput(allocator, &[_][]const u8{
        "git", "upload-pack", "--stateless-rpc", "--advertise-refs", repo_dir,
    }) catch {
        try http.sendSimpleResponse(connection, "500 Internal Server Error", "text/plain", "upload-pack failed\n");
        return;
    };
    defer allocator.free(output);

    const body_len = output.len + 4;
    var headers: [128]u8 = undefined;
    const resp = try std.fmt.bufPrint(
        &headers,
        "HTTP/1.1 200 OK\r\nContent-Type: application/x-git-upload-pack-advertisement\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{body_len},
    );
    try connection.stream.writeAll(resp);
    if (!head_only) {
        try connection.stream.writeAll("001e# service=git-upload-pack\n");
        try connection.stream.writeAll("0000");
        try connection.stream.writeAll(output);
    }
}

fn handleUploadPackRequest(
    allocator: std.mem.Allocator,
    connection: *std.net.Server.Connection,
    repo_dir: []const u8,
    raw: []const u8,
    head_only: bool,
) !void {
    const body = http.findBody(raw);
    const tmp_input = try std.fs.path.join(allocator, &.{ "/tmp", try std.fmt.allocPrint(allocator, "gitreq-{d}", .{std.time.nanoTimestamp()}) });
    defer {
        allocator.free(tmp_input);
        std.fs.deleteTreeAbsolute(tmp_input) catch {};
    }

    {
        var file = try std.fs.createFileAbsolute(tmp_input, .{});
        defer file.close();
        try file.writeAll(body);
    }

    const output = shell.runCommandOutputAlloc(allocator, &[_][]const u8{
        "git", "upload-pack", "--stateless-rpc", repo_dir,
    }, tmp_input) catch {
        try http.sendSimpleResponse(connection, "500 Internal Server Error", "text/plain", "upload-pack failed\n");
        return;
    };
    defer allocator.free(output);

    const body_len = output.len;
    var headers: [128]u8 = undefined;
    const resp = try std.fmt.bufPrint(
        &headers,
        "HTTP/1.1 200 OK\r\nContent-Type: " ++
            "application/x-git-upload-pack-result\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{body_len},
    );
    try connection.stream.writeAll(resp);
    if (!head_only) {
        try connection.stream.writeAll(output);
    }
}
