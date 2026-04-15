const std = @import("std");
const types = @import("types.zig");
const http = @import("http_helpers.zig");
const shell = @import("shell.zig");
const sync = @import("sync.zig");

const release_id_raw = @embedFile("RELEASE_ID");

const UpdateWorkerArgs = struct {
    root: []u8,
    source_url: []u8,
};

const FetchProbeResult = struct {
    pseudo_git_fetchable: bool,
    commit: ?[]u8 = null,
    probe_error: ?[]u8 = null,

    fn deinit(self: *FetchProbeResult, allocator: std.mem.Allocator) void {
        if (self.commit) |commit| allocator.free(commit);
        if (self.probe_error) |probe_error| allocator.free(probe_error);
        self.* = undefined;
    }
};

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
        {
            defer connection.stream.close();

            handleConnection(allocator, &connection, root, token, source_url) catch |err| {
                std.log.warn("request failed: {s}", .{@errorName(err)});
            };
        }
    }
}

/// Reads a chunked-encoded HTTP/1.1 request body from `connection` into `buffer`
/// starting at `header_end`, then decodes the chunks in-place.
/// Returns the new total_read value (header_end + decoded body length).
///
/// The source (chunked framing) always lies ahead of the write cursor, so the
/// in-place `copyForwards` is safe without extra allocation.
fn readChunkedBody(
    connection: *std.net.Server.Connection,
    buffer: []u8,
    header_end: usize,
    total_read_init: usize,
) !usize {
    var total_read = total_read_init;
    var write_pos: usize = header_end; // decoded bytes land here
    var read_pos: usize = header_end; // next unprocessed byte of raw chunked data

    while (true) {
        // Ensure we have the chunk-size line (terminated by \r\n).
        while (std.mem.indexOf(u8, buffer[read_pos..total_read], "\r\n") == null) {
            if (total_read >= buffer.len) return error.RequestTooLarge;
            const n = try connection.stream.read(buffer[total_read..]);
            if (n == 0) return error.UnexpectedEof;
            total_read += n;
        }

        const crlf = std.mem.indexOf(u8, buffer[read_pos..total_read], "\r\n").?;
        const size_str = std.mem.trim(u8, buffer[read_pos .. read_pos + crlf], " ");
        const chunk_size = std.fmt.parseInt(usize, size_str, 16) catch return error.InvalidChunkedEncoding;
        read_pos += crlf + 2; // skip size-line and its CRLF

        if (chunk_size == 0) break; // terminal chunk

        // Ensure we have the full chunk data plus its trailing CRLF.
        while (total_read - read_pos < chunk_size + 2) {
            if (total_read >= buffer.len) return error.RequestTooLarge;
            const n = try connection.stream.read(buffer[total_read..]);
            if (n == 0) return error.UnexpectedEof;
            total_read += n;
        }

        // Copy chunk data to write_pos. read_pos is always ahead of write_pos by
        // at least the chunk-size line overhead, so copyForwards is safe.
        std.mem.copyForwards(u8, buffer[write_pos..][0..chunk_size], buffer[read_pos..][0..chunk_size]);
        write_pos += chunk_size;
        read_pos += chunk_size + 2; // skip data and trailing CRLF
    }

    return write_pos;
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

    // Read until we have the complete HTTP headers.
    var total_read: usize = 0;
    var header_end: usize = 0;
    while (header_end == 0) {
        if (total_read >= buffer.len) return error.RequestTooLarge;
        const n = try connection.stream.read(buffer[total_read..]);
        if (n == 0) return;
        total_read += n;
        if (std.mem.indexOf(u8, buffer[0..total_read], "\r\n\r\n")) |pos| {
            header_end = pos + 4;
        }
    }

    // Read the request body according to the transfer encoding.
    const te_header = http.findHeader(buffer[0..header_end], "Transfer-Encoding");
    const is_chunked = if (te_header) |te| std.ascii.eqlIgnoreCase(std.mem.trim(u8, te, " "), "chunked") else false;

    if (http.findHeader(buffer[0..header_end], "Content-Length")) |cl_str| {
        const content_length = std.fmt.parseInt(usize, std.mem.trim(u8, cl_str, " "), 10) catch 0;
        const needed = header_end + content_length;
        if (needed > buffer.len) return error.RequestTooLarge;
        while (total_read < needed) {
            const n = try connection.stream.read(buffer[total_read..needed]);
            if (n == 0) return error.UnexpectedEof;
            total_read += n;
        }
    } else if (is_chunked) {
        total_read = try readChunkedBody(connection, buffer, header_end, total_read);
    }

    const raw = buffer[0..total_read];
    const request = try http.parseRequest(raw);
    const path = http.requestPath(request.target);
    const head_only = std.mem.eql(u8, request.method, "HEAD");

    // Request dump: always logged so unexpected client behaviour is visible in container logs.
    std.log.info(
        "request method={s} path={s} te={s} cl={s} body_bytes={d}",
        .{
            request.method,
            path,
            te_header orelse "-",
            http.findHeader(raw, "Content-Length") orelse "-",
            total_read - header_end,
        },
    );

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

    if (http.isSmartHttpRequest(path)) {
        try handleSmartHttp(allocator, connection, root, request, raw, head_only);
        return;
    }

    if (!std.mem.eql(u8, request.method, "GET") and !head_only) {
        try http.sendSimpleResponse(connection, "405 Method Not Allowed", "text/plain", "method not allowed\n");
        return;
    }

    if (std.mem.eql(u8, path, "/api/list")) {
        try handleList(allocator, connection, root, head_only);
        return;
    }
    if (std.mem.startsWith(u8, path, "/api/info/")) {
        try handlePackageInfo(allocator, connection, root, path["/api/info/".len..], head_only);
        return;
    }
    if (std.mem.startsWith(u8, path, "/api/check/")) {
        try handleCheckPackage(allocator, connection, root, path["/api/check/".len..], head_only);
        return;
    }
    if (std.mem.eql(u8, path, "/api/status")) {
        try handleStatus(allocator, connection, root, head_only);
        return;
    }
    if (std.mem.eql(u8, path, "/api/info")) {
        try http.sendSimpleResponse(connection, "404 Not Found", "text/plain", "use /api/status for server status or /api/info/<package> for package info\n");
        return;
    }
    if (std.mem.eql(u8, path, "/")) {
        try http.sendLandingPage(connection, head_only);
        return;
    }

    const routed_path = try http.routePath(allocator, path);
    defer allocator.free(routed_path);
    const resolved = try http.resolvePath(allocator, root, routed_path);
    defer allocator.free(resolved);

    var file = std.fs.cwd().openFile(resolved, .{}) catch |err| switch (err) {
        error.FileNotFound => retry: {
            if (try maybeMaterializeRequestedTarball(allocator, root, routed_path)) {
                break :retry try std.fs.cwd().openFile(resolved, .{});
            }
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
    const worker_allocator = std.heap.page_allocator;
    const args = try worker_allocator.create(UpdateWorkerArgs);
    errdefer worker_allocator.destroy(args);
    args.* = .{
        .root = try worker_allocator.dupe(u8, root),
        .source_url = try worker_allocator.dupe(u8, source_url),
    };
    errdefer worker_allocator.free(args.root);
    errdefer worker_allocator.free(args.source_url);

    var thread = std.Thread.spawn(.{}, updateWorker, .{args}) catch |err| {
        worker_allocator.free(args.root);
        worker_allocator.free(args.source_url);
        worker_allocator.destroy(args);
        try sync.finishUpdateWindow(allocator, root, &stats);
        return err;
    };
    thread.detach();

    std.log.info("update started in background source={s}", .{source_url});
    const body =
        \\{"status":"started"}
        \\
    ;
    try http.writeHeaders(connection, "200 OK", "application/json", body.len);
    try connection.stream.writeAll(body);
}

fn maybeMaterializeRequestedTarball(
    allocator: std.mem.Allocator,
    root: []const u8,
    request_path: []const u8,
) !bool {
    if (!std.mem.startsWith(u8, request_path, "/p/")) return false;
    if (!std.mem.endsWith(u8, request_path, ".tar.gz")) return false;

    var parts = std.mem.splitScalar(u8, request_path[1..], '/');
    const prefix = parts.next() orelse return false;
    const package_name = parts.next() orelse return false;
    const kind = parts.next() orelse return false;
    const tarball_name = parts.next() orelse return false;
    if (parts.next() != null) return false;
    if (!std.mem.eql(u8, prefix, "p")) return false;
    if (!std.mem.eql(u8, kind, "tag")) return false;
    if (!std.mem.endsWith(u8, tarball_name, ".tar.gz")) return false;

    const tag = tarball_name[0 .. tarball_name.len - ".tar.gz".len];
    var source_record = (try sync.lookupSourceRecordByPackage(allocator, root, package_name)) orelse return false;
    defer sync.freeSourceRecord(allocator, &source_record);
    if (source_record.repo_url.len == 0) return false;

    try materializeTarballOnDemand(allocator, root, package_name, tag, source_record.repo_url);
    return true;
}

fn materializeTarballOnDemand(
    allocator: std.mem.Allocator,
    root: []const u8,
    package_name: []const u8,
    tag: []const u8,
    repo_url: []const u8,
) !void {
    const pkg_dir = try std.fs.path.join(allocator, &.{ root, "p", package_name, "tag" });
    defer allocator.free(pkg_dir);
    try shell.runCommand(allocator, &.{ "mkdir", "-p", pkg_dir });

    const tarball_name = try std.fmt.allocPrint(allocator, "{s}.tar.gz", .{tag});
    defer allocator.free(tarball_name);
    const tarball_path = try std.fs.path.join(allocator, &.{ pkg_dir, tarball_name });
    defer allocator.free(tarball_path);

    if (std.fs.cwd().access(tarball_path, .{})) |_| {
        return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const tmp_path = try std.fmt.allocPrint(allocator, "/tmp/packbase-ondemand-{d}", .{std.time.nanoTimestamp()});
    defer allocator.free(tmp_path);
    defer std.fs.deleteTreeAbsolute(tmp_path) catch {};

    try shell.runCommand(allocator, &.{ "git", "init", "--quiet", tmp_path });
    try shell.runCommand(allocator, &.{ "git", "-C", tmp_path, "remote", "add", "origin", repo_url });

    const tag_ref = try std.fmt.allocPrint(allocator, "refs/tags/{s}:refs/tags/{s}", .{ tag, tag });
    defer allocator.free(tag_ref);
    try shell.runCommand(allocator, &.{
        "git", "-c", "protocol.file.allow=always", "-c", "safe.directory=*",
        "-C", tmp_path, "fetch", "--depth", "1", "--quiet", "origin", tag_ref,
    });

    const checkout_target = try std.fmt.allocPrint(allocator, "tags/{s}", .{tag});
    defer allocator.free(checkout_target);
    try shell.runCommand(allocator, &.{ "git", "-C", tmp_path, "checkout", "--quiet", checkout_target });

    const stage_path = try std.fmt.allocPrint(allocator, "{s}_stage", .{tmp_path});
    defer allocator.free(stage_path);
    defer std.fs.deleteTreeAbsolute(stage_path) catch {};

    try shell.runCommand(allocator, &.{ "cp", "-r", tmp_path, stage_path });
    const stage_git = try std.fs.path.join(allocator, &.{ stage_path, ".git" });
    defer allocator.free(stage_git);
    std.fs.deleteTreeAbsolute(stage_git) catch {};

    const stage_parent = std.fs.path.dirname(stage_path) orelse "/tmp";
    const stage_base = std.fs.path.basename(stage_path);
    try shell.runCommand(allocator, &.{ "tar", "czf", tarball_path, "-C", stage_parent, stage_base });

    std.log.info("tarball materialized on demand package={s} tag={s}", .{ package_name, tag });
}

fn updateWorker(args: *UpdateWorkerArgs) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const root = args.root;
    const source_url = args.source_url;
    defer {
        const worker_allocator = std.heap.page_allocator;
        worker_allocator.free(root);
        worker_allocator.free(source_url);
        worker_allocator.destroy(args);
    }

    std.log.info("update begin source={s}", .{source_url});

    var stats = types.SyncStats{};
    defer sync.finishUpdateWindow(allocator, root, &stats) catch |err| {
        std.log.warn("finish update window failed: {s}", .{@errorName(err)});
    };

    var source_records = sync.syncSourceCatalog(allocator, root, source_url, &stats) catch |err| {
        std.log.warn("source sync failed: {s}", .{@errorName(err)});
        return;
    };
    defer sync.freeSourceRecordList(allocator, &source_records);

    sync.syncSourceRepos(
        allocator,
        root,
        source_records.items,
        stats.source_changed or stats.source_added != 0 or stats.source_changed_count != 0,
        &stats,
    ) catch |err| {
        std.log.warn("source repo materialization failed: {s}", .{@errorName(err)});
        return;
    };

    const local_stats = sync.syncPackages(allocator, root) catch |err| {
        std.log.warn("sync failed: {s}", .{@errorName(err)});
        return;
    };
    stats.repos_scanned = local_stats.repos_scanned;
    stats.packages_synced = local_stats.packages_synced;
    stats.tarballs_created = local_stats.tarballs_created;
    stats.tarballs_present = local_stats.tarballs_present;
    stats.default_seeded = local_stats.default_seeded;

    var package_infos = sync.collectPackageInfos(allocator, root) catch |err| {
        std.log.warn("package info collection failed: {s}", .{@errorName(err)});
        return;
    };
    defer sync.freePackageInfoList(allocator, &package_infos);

    stats.packages_total = package_infos.items.len;
    stats.packages_probed = 0;
    sync.writeUpdateProgress(allocator, root, &stats) catch |err| {
        std.log.warn("progress write failed: {s}", .{@errorName(err)});
    };

    const updated_at = std.time.timestamp();
    for (package_infos.items) |*info| {
        info.updated_at = updated_at;
        info.smart_http_ready = info.tarball_count != 0;

        var probe = probePseudoGitFetchability(allocator, root, info.package, info.local) catch |err| {
            std.log.warn("fetch probe failed package={s} error={s}", .{ info.package, @errorName(err) });
            stats.packages_probed += 1;
            sync.writeUpdateProgress(allocator, root, &stats) catch {};
            continue;
        };
        defer probe.deinit(allocator);

        info.pseudo_git_fetchable = probe.pseudo_git_fetchable;
        if (probe.commit) |commit| {
            info.fetch_probe_commit = allocator.dupe(u8, commit) catch |err| {
                std.log.warn("commit copy failed package={s} error={s}", .{ info.package, @errorName(err) });
                stats.packages_probed += 1;
                sync.writeUpdateProgress(allocator, root, &stats) catch {};
                continue;
            };
        }
        if (probe.probe_error) |probe_error| {
            info.fetch_probe_error = allocator.dupe(u8, probe_error) catch |err| {
                std.log.warn("probe error copy failed package={s} error={s}", .{ info.package, @errorName(err) });
                stats.packages_probed += 1;
                sync.writeUpdateProgress(allocator, root, &stats) catch {};
                continue;
            };
        }
        info.healthy = info.local and info.tarball_count != 0 and info.pseudo_git_fetchable;
        stats.packages_probed += 1;
        sync.writeUpdateProgress(allocator, root, &stats) catch {};
    }

    sync.writePackageInfoSnapshot(allocator, root, package_infos.items) catch |err| {
        std.log.warn("package info snapshot write failed: {s}", .{@errorName(err)});
        return;
    };

    std.log.info(
        "update completed repos={d} synced={d} created={d} source_changed={any} source_packages={d} cloned={d} updated={d} failed={d} package_infos={d}",
        .{
            stats.repos_scanned,
            stats.packages_synced,
            stats.tarballs_created,
            stats.source_changed,
            stats.source_packages,
            stats.source_repo_cloned,
            stats.source_repo_updated,
            stats.source_repo_failed,
            package_infos.items.len,
        },
    );
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

fn handleStatus(
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

fn handleCheckPackage(
    allocator: std.mem.Allocator,
    connection: *std.net.Server.Connection,
    root: []const u8,
    package_name: []const u8,
    head_only: bool,
) !void {
    if (package_name.len == 0 or std.mem.indexOfScalar(u8, package_name, '/') != null) {
        try http.sendSimpleResponse(connection, "400 Bad Request", "text/plain", "invalid package name\n");
        return;
    }

    const body = sync.readPackageInfoJson(allocator, root, package_name) catch |err| switch (err) {
        error.FileNotFound => {
            try http.sendSimpleResponse(
                connection,
                "503 Service Unavailable",
                "text/plain",
                "package info unavailable; run /api/update first\n",
            );
            return;
        },
        else => return err,
    } orelse {
        const not_found = try std.fmt.allocPrint(
            allocator,
            "{{\"status\":\"not_found\",\"package\":\"{s}\"}}\n",
            .{package_name},
        );
        defer allocator.free(not_found);
        try http.writeHeaders(connection, "404 Not Found", "application/json", not_found.len);
        if (!head_only) try connection.stream.writeAll(not_found);
        return;
    };
    defer allocator.free(body);

    try http.writeHeaders(connection, "200 OK", "application/json", body.len);
    if (!head_only) try connection.stream.writeAll(body);
}

fn handlePackageInfo(
    allocator: std.mem.Allocator,
    connection: *std.net.Server.Connection,
    root: []const u8,
    package_name: []const u8,
    head_only: bool,
) !void {
    try handleCheckPackage(allocator, connection, root, package_name, head_only);
}

fn probePseudoGitFetchability(
    allocator: std.mem.Allocator,
    root: []const u8,
    package_name: []const u8,
    local: bool,
) !FetchProbeResult {
    if (!local) return .{ .pseudo_git_fetchable = false, .probe_error = try allocator.dupe(u8, "package_not_local") };

    var commit: ?[]u8 = null;
    if (try resolveRepoDir(allocator, root, package_name)) |repo_dir| {
        defer allocator.free(repo_dir);
        const commit_raw = shell.runCommandOutput(allocator, &.{ "git", "-C", repo_dir, "rev-parse", "HEAD" }) catch null;
        if (commit_raw) |raw| {
            defer allocator.free(raw);
            commit = try allocator.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
        }
    }

    validatePseudoGitFetchability(allocator, root, package_name) catch |err| {
        return .{
            .pseudo_git_fetchable = false,
            .commit = commit,
            .probe_error = try allocator.dupe(u8, @errorName(err)),
        };
    };

    return .{
        .pseudo_git_fetchable = true,
        .commit = commit,
    };
}

fn validatePseudoGitFetchability(
    allocator: std.mem.Allocator,
    root: []const u8,
    package_name: []const u8,
) !void {
    const helper_port: u16 = 19082;
    const helper_port_text = try std.fmt.allocPrint(allocator, "{d}", .{helper_port});
    defer allocator.free(helper_port_text);

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("PACKBASE_ROOT", root);
    try env_map.put("PACKBASE_PORT", helper_port_text);
    env_map.remove("PACKBASE_TOKEN");

    var helper = std.process.Child.init(&.{ "/usr/local/bin/packbase" }, allocator);
    helper.stdin_behavior = .Close;
    helper.stdout_behavior = .Ignore;
    helper.stderr_behavior = .Ignore;
    helper.env_map = &env_map;
    try helper.spawn();
    defer {
        _ = helper.kill() catch {};
        _ = helper.wait() catch {};
    }

    const info_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/api/status", .{helper_port});
    defer allocator.free(info_url);
    var ready = false;
    var attempts: usize = 0;
    while (attempts < 50) : (attempts += 1) {
        const info = shell.runCommandOutput(allocator, &.{ "curl", "-fsS", info_url }) catch {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            continue;
        };
        allocator.free(info);
        ready = true;
        break;
    }
    if (!ready) return error.HelperServerUnavailable;

    const probe_dir = try std.fmt.allocPrint(allocator, "/tmp/packbase-fetch-probe-{d}", .{std.time.nanoTimestamp()});
    defer allocator.free(probe_dir);
    defer std.fs.deleteTreeAbsolute(probe_dir) catch {};
    try std.fs.makeDirAbsolute(probe_dir);

    const build_zig = try std.fs.path.join(allocator, &.{ probe_dir, "build.zig" });
    defer allocator.free(build_zig);
    const build_zon = try std.fs.path.join(allocator, &.{ probe_dir, "build.zig.zon" });
    defer allocator.free(build_zon);

    try writeTextFileAbsolute(build_zig,
        \\const std = @import("std");
        \\
        \\pub fn build(_: *std.Build) void {}
        \\
    );
    try writeTextFileAbsolute(build_zon,
        \\ .{
        \\     .name = .packbase_probe,
        \\     .version = "0.0.0",
        \\     .dependencies = .{},
        \\     .paths = .{""},
        \\ }
        \\
    );

    const fetch_url = try std.fmt.allocPrint(allocator, "git+http://127.0.0.1:{d}/{s}", .{ helper_port, package_name });
    defer allocator.free(fetch_url);

    var fetch = std.process.Child.init(&.{ "zig", "fetch", "--save", fetch_url, "--global-cache-dir", ".zig-cache" }, allocator);
    fetch.stdin_behavior = .Close;
    fetch.stdout_behavior = .Ignore;
    fetch.stderr_behavior = .Ignore;
    fetch.cwd = probe_dir;
    const term = try fetch.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.ZigFetchFailed,
        else => return error.ZigFetchFailed,
    }
}

fn writeTextFileAbsolute(path: []const u8, content: []const u8) !void {
    var file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(content);
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
    const target = request.target;
    const path = http.requestPath(target);

    var repo_rel: []const u8 = undefined;
    var git_prefixed: bool = undefined;

    if (std.mem.startsWith(u8, path, "/git/")) {
        git_prefixed = true;
        const after_git = path[5..];
        const question = std.mem.indexOfScalar(u8, after_git, '?') orelse after_git.len;
        repo_rel = after_git[0..question];
    } else if (http.isSmartHttpRequest(path)) {
        git_prefixed = false;
        if (std.mem.indexOfScalar(u8, path[1..], '/')) |slash| {
            repo_rel = path[1 .. slash + 1];
        } else {
            repo_rel = path[1..];
        }
    } else {
        try http.sendSimpleResponse(connection, "400 Bad Request", "text/plain", "invalid request\n");
        return;
    }

    if (std.mem.endsWith(u8, repo_rel, "/info/refs")) {
        repo_rel = repo_rel[0 .. repo_rel.len - 10];
    } else if (std.mem.endsWith(u8, repo_rel, "/git-upload-pack")) {
        repo_rel = repo_rel[0 .. repo_rel.len - 15];
    } else if (std.mem.endsWith(u8, repo_rel, "/git-receive-pack")) {
        repo_rel = repo_rel[0 .. repo_rel.len - 17];
    }

    const repo_dir = (try resolveRepoDir(allocator, root, repo_rel)) orelse {
        try http.sendSimpleResponse(connection, "404 Not Found", "text/plain", "not found\n");
        return;
    };
    defer allocator.free(repo_dir);

    const git_protocol = http.findHeader(raw, "Git-Protocol") orelse "";
    const use_v2 = std.mem.eql(u8, git_protocol, "version=2");

    if (std.mem.eql(u8, request.method, "GET")) {
        try handleUploadPackAdvertise(allocator, connection, repo_dir, use_v2, head_only);
        return;
    } else if (std.mem.eql(u8, request.method, "POST")) {
        const content_type = http.findHeader(raw, "Content-Type") orelse "";
        if (std.mem.eql(u8, content_type, "application/x-git-upload-pack-request")) {
            try handleUploadPackRequest(allocator, connection, repo_dir, raw, use_v2, head_only);
            return;
        }
    }

    try http.sendSimpleResponse(connection, "404 Not Found", "text/plain", "not found\n");
}

/// Resolves the git bare-repo directory for a given repo_rel name.
/// First checks for an existing bare repo in {root}/git/{repo_rel}.
/// If not found, builds an ephemeral bare repo from tarballs in {root}/p/{pkg}/tag/.
/// Returns an allocated path (caller must free), or null if the package doesn't exist.
fn resolveRepoDir(allocator: std.mem.Allocator, root: []const u8, repo_rel: []const u8) !?[]const u8 {
    const git_dir = try std.fs.path.join(allocator, &.{ root, "git", repo_rel });
    errdefer allocator.free(git_dir);
    if (std.fs.cwd().access(git_dir, .{})) |_| {
        return git_dir;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    allocator.free(git_dir);

    const pkg_name = if (std.mem.endsWith(u8, repo_rel, ".git"))
        repo_rel[0 .. repo_rel.len - 4]
    else
        repo_rel;

    return ensureGitCacheFromTarballs(allocator, root, pkg_name) catch |err| {
        std.log.warn("git cache unavailable package={s} err={s}", .{ pkg_name, @errorName(err) });
        return null;
    };
}

/// Ensures a cached bare git repo exists for pkg_name, built from its tarballs.
/// Cache lives at {root}/.packbase/git-cache/{pkg_name} and is rebuilt
/// whenever the number of tarballs changes.
fn ensureGitCacheFromTarballs(allocator: std.mem.Allocator, root: []const u8, pkg_name: []const u8) ![]const u8 {
    const tag_dir = try std.fs.path.join(allocator, &.{ root, "p", pkg_name, "tag" });
    defer allocator.free(tag_dir);

    var tags = std.ArrayList([]u8).empty;
    defer {
        for (tags.items) |t| allocator.free(t);
        tags.deinit(allocator);
    }

    {
        var td = std.fs.openDirAbsolute(tag_dir, .{ .iterate = true }) catch return error.FileNotFound;
        defer td.close();
        var iter = td.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".tar.gz")) continue;
            const tag = entry.name[0 .. entry.name.len - 7];
            try tags.append(allocator, try allocator.dupe(u8, tag));
        }
    }

    if (tags.items.len == 0) return error.FileNotFound;

    std.mem.sort([]u8, tags.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    const cache_dir = try std.fs.path.join(allocator, &.{ root, ".packbase", "git-cache", pkg_name });
    errdefer allocator.free(cache_dir);

    const needs_rebuild = blk: {
        const head_path = try std.fs.path.join(allocator, &.{ cache_dir, "HEAD" });
        defer allocator.free(head_path);
        if (std.fs.cwd().access(head_path, .{})) |_| {} else |err| switch (err) {
            error.FileNotFound => break :blk true,
            else => return err,
        }

        const output = shell.runCommandOutput(allocator, &.{ "git", "-C", cache_dir, "tag" }) catch break :blk true;
        defer allocator.free(output);
        var count: usize = 0;
        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |line| {
            if (line.len > 0) count += 1;
        }
        break :blk count != tags.items.len;
    };

    if (needs_rebuild) {
        std.log.info("building git cache package={s} tags={d}", .{ pkg_name, tags.items.len });
        std.fs.deleteTreeAbsolute(cache_dir) catch {};
        try buildGitRepoFromTarballs(allocator, tag_dir, tags.items, cache_dir);
        std.log.info("git cache ready package={s}", .{pkg_name});
    }

    return cache_dir;
}

/// Builds a bare git repo at cache_dir with one commit+tag per tarball.
/// Commits are deterministic: fixed author/committer identity and timestamp.
fn buildGitRepoFromTarballs(
    allocator: std.mem.Allocator,
    tag_dir: []const u8,
    tags: []const []u8,
    cache_dir: []const u8,
) !void {
    const fixed_env = [_][2][]const u8{
        .{ "GIT_AUTHOR_NAME", "packbase" },
        .{ "GIT_AUTHOR_EMAIL", "packbase@localhost" },
        .{ "GIT_AUTHOR_DATE", "2000-01-01T00:00:00+0000" },
        .{ "GIT_COMMITTER_NAME", "packbase" },
        .{ "GIT_COMMITTER_EMAIL", "packbase@localhost" },
        .{ "GIT_COMMITTER_DATE", "2000-01-01T00:00:00+0000" },
    };

    const tmp_work = try std.fmt.allocPrint(allocator, "/tmp/pb-gitbuild-{d}", .{std.time.nanoTimestamp()});
    defer allocator.free(tmp_work);
    defer std.fs.deleteTreeAbsolute(tmp_work) catch {};

    try shell.runCommandWithEnv(allocator, &.{ "git", "init", "--quiet", tmp_work }, &fixed_env);

    for (tags, 0..) |tag, i| {
        if (i > 0) {
            try shell.runCommandWithEnv(allocator, &.{ "git", "-C", tmp_work, "rm", "-rf", "--cached", "--quiet", "." }, &fixed_env);
            try cleanWorkDir(allocator, tmp_work);
        }

        const tarball = try std.fmt.allocPrint(allocator, "{s}/{s}.tar.gz", .{ tag_dir, tag });
        defer allocator.free(tarball);
        try extractTarballNormalized(allocator, tarball, tmp_work);

        const msg = try std.fmt.allocPrint(allocator, "release {s}", .{tag});
        defer allocator.free(msg);

        try shell.runCommandWithEnv(allocator, &.{ "git", "-C", tmp_work, "add", "-A" }, &fixed_env);
        try shell.runCommandWithEnv(allocator, &.{ "git", "-C", tmp_work, "commit", "--allow-empty", "--quiet", "-m", msg }, &fixed_env);
        try shell.runCommandWithEnv(allocator, &.{ "git", "-C", tmp_work, "tag", tag }, &fixed_env);
    }

    const parent = std.fs.path.dirname(cache_dir) orelse return error.InvalidPath;
    try shell.runCommand(allocator, &.{ "mkdir", "-p", parent });
    try shell.runCommand(allocator, &.{ "git", "clone", "--bare", "--quiet", tmp_work, cache_dir });
}

/// Extracts tarball to dest_dir, stripping a single top-level prefix directory
/// when all entries share the same one (e.g. tarballs created with tar czf dir/).
fn extractTarballNormalized(allocator: std.mem.Allocator, tarball_path: []const u8, dest_dir: []const u8) !void {
    const listing = try shell.runCommandOutput(allocator, &.{ "tar", "tzf", tarball_path });
    defer allocator.free(listing);

    var first: ?[]const u8 = null;
    var single_prefix = true;

    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (trimmed.len == 0) continue;
        const slash = std.mem.indexOfScalar(u8, trimmed, '/') orelse trimmed.len;
        const top = trimmed[0..slash];
        if (top.len == 0) continue;
        if (first) |f| {
            if (!std.mem.eql(u8, f, top)) {
                single_prefix = false;
                break;
            }
        } else {
            first = top;
        }
    }

    if (first != null and single_prefix) {
        try shell.runCommand(allocator, &.{ "tar", "xzf", tarball_path, "-C", dest_dir, "--strip-components=1" });
    } else {
        try shell.runCommand(allocator, &.{ "tar", "xzf", tarball_path, "-C", dest_dir });
    }
}

/// Removes all files and directories from dir_path except the .git directory.
fn cleanWorkDir(allocator: std.mem.Allocator, dir_path: []const u8) !void {
    var dir = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
    defer dir.close();

    var names = std.ArrayList([]u8).empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.eql(u8, entry.name, ".git")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    for (names.items) |name| {
        const full = try std.fs.path.join(allocator, &.{ dir_path, name });
        defer allocator.free(full);
        std.fs.deleteTreeAbsolute(full) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

fn handleUploadPackAdvertise(
    allocator: std.mem.Allocator,
    connection: *std.net.Server.Connection,
    repo_dir: []const u8,
    use_v2: bool,
    head_only: bool,
) !void {
    std.log.info(
        "upload-pack advertise start repo={s} v2={any} head_only={any}",
        .{ repo_dir, use_v2, head_only },
    );
    const argv = [_][]const u8{ "git", "upload-pack", "--stateless-rpc", "--advertise-refs", repo_dir };
    const v2_env = [_][2][]const u8{.{ "GIT_PROTOCOL", "version=2" }};
    const output = if (use_v2)
        shell.runCommandOutputWithEnv(allocator, &argv, &v2_env)
    else
        shell.runCommandOutput(allocator, &argv);
    const out = output catch {
        try http.sendSimpleResponse(connection, "500 Internal Server Error", "text/plain", "upload-pack failed\n");
        return;
    };
    defer allocator.free(out);

    const body_len = out.len + 34; // 30 bytes "001e# service=git-upload-pack\n" + 4 bytes "0000"
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
        try connection.stream.writeAll(out);
    }
    std.log.info("upload-pack advertise done repo={s} bytes={d}", .{ repo_dir, out.len });
}

fn handleUploadPackRequest(
    allocator: std.mem.Allocator,
    connection: *std.net.Server.Connection,
    repo_dir: []const u8,
    raw: []const u8,
    use_v2: bool,
    head_only: bool,
) !void {
    const body = http.findBody(raw);
    const tmp_name = try std.fmt.allocPrint(allocator, "gitreq-{d}", .{std.time.nanoTimestamp()});
    defer allocator.free(tmp_name);
    const tmp_input = try std.fmt.allocPrint(allocator, "/tmp/{s}", .{tmp_name});
    defer {
        std.fs.deleteFileAbsolute(tmp_input) catch {};
        allocator.free(tmp_input);
    }

    std.log.info(
        "upload-pack request start repo={s} v2={any} head_only={any} body_bytes={d} tmp={s}",
        .{ repo_dir, use_v2, head_only, body.len, tmp_input },
    );

    {
        var file = try std.fs.createFileAbsolute(tmp_input, .{});
        defer file.close();
        try file.writeAll(body);
    }

    const argv = [_][]const u8{ "git", "upload-pack", "--stateless-rpc", repo_dir };
    const v2_env = [_][2][]const u8{.{ "GIT_PROTOCOL", "version=2" }};
    const output = if (use_v2)
        shell.runCommandOutputAllocWithEnv(allocator, &argv, tmp_input, &v2_env)
    else
        shell.runCommandOutputAlloc(allocator, &argv, tmp_input);
    const out = output catch {
        try http.sendSimpleResponse(connection, "500 Internal Server Error", "text/plain", "upload-pack failed\n");
        return;
    };
    defer allocator.free(out);

    std.log.info("upload-pack request git complete repo={s} bytes={d}", .{ repo_dir, out.len });

    var headers: [128]u8 = undefined;
    const resp = try std.fmt.bufPrint(
        &headers,
        "HTTP/1.1 200 OK\r\nContent-Type: " ++
            "application/x-git-upload-pack-result\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{out.len},
    );
    try connection.stream.writeAll(resp);
    if (!head_only) {
        try connection.stream.writeAll(out);
    }
    std.log.info("upload-pack request done repo={s} bytes={d}", .{ repo_dir, out.len });
}
