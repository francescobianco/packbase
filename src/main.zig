const std = @import("std");

const Request = struct {
    method: []const u8,
    target: []const u8,
};

const FetchPayload = struct {
    url: []const u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const root = std.posix.getenv("PACKBASE_ROOT") orelse "public";
    const port_text = std.posix.getenv("PACKBASE_PORT") orelse "8080";
    const token = std.posix.getenv("PACKBASE_TOKEN"); // null = auth disabled
    const port = try std.fmt.parseInt(u16, port_text, 10);

    const address = try std.net.Address.parseIp("0.0.0.0", port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.log.info("serving {s} on 0.0.0.0:{d}", .{ root, port });

    while (true) {
        var connection = try server.accept();
        defer connection.stream.close();

        handleConnection(allocator, &connection, root, token) catch |err| {
            std.log.warn("request failed: {s}", .{@errorName(err)});
        };
    }
}

fn handleConnection(
    allocator: std.mem.Allocator,
    connection: *std.net.Server.Connection,
    root: []const u8,
    token: ?[]const u8,
) !void {
    const buffer = try allocator.alloc(u8, 65536);
    defer allocator.free(buffer);
    const bytes_read = try connection.stream.read(buffer);
    if (bytes_read == 0) return;

    const raw = buffer[0..bytes_read];
    const request = try parseRequest(raw);
    const path = requestPath(request.target);

    if (std.mem.eql(u8, request.method, "POST") and std.mem.eql(u8, path, "/api/fetch")) {
        try handleFetch(allocator, connection, root, token, raw);
        return;
    }

    const head_only = std.mem.eql(u8, request.method, "HEAD");
    if (!std.mem.eql(u8, request.method, "GET") and !head_only) {
        try sendSimpleResponse(connection, "405 Method Not Allowed", "text/plain", "method not allowed\n");
        return;
    }

    if (std.mem.eql(u8, path, "/")) {
        try sendLandingPage(connection, head_only);
        return;
    }

    const resolved = try resolvePath(allocator, root, path);
    defer allocator.free(resolved);

    var file = std.fs.cwd().openFile(resolved, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try sendSimpleResponse(connection, "404 Not Found", "text/plain", "not found\n");
            return;
        },
        error.IsDir => {
            try sendSimpleResponse(connection, "403 Forbidden", "text/plain", "directory listing disabled\n");
            return;
        },
        else => return err,
    };
    defer file.close();

    const stat = try file.stat();
    try writeHeaders(connection, "200 OK", contentType(resolved), stat.size);
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
    // Validate Bearer token when PACKBASE_TOKEN is set.
    if (token) |expected| {
        const auth = findHeader(raw, "Authorization") orelse {
            try sendSimpleResponse(connection, "401 Unauthorized", "text/plain", "unauthorized\n");
            return;
        };
        const prefix = "Bearer ";
        if (!std.mem.startsWith(u8, auth, prefix) or
            !std.mem.eql(u8, auth[prefix.len..], expected))
        {
            try sendSimpleResponse(connection, "403 Forbidden", "text/plain", "forbidden\n");
            return;
        }
    }

    // Parse JSON body: {"url": "git+https://..."}
    const body = findBody(raw);
    if (body.len == 0) {
        try sendSimpleResponse(connection, "400 Bad Request", "text/plain", "empty body\n");
        return;
    }
    const parsed = std.json.parseFromSlice(FetchPayload, allocator, body, .{}) catch {
        try sendSimpleResponse(connection, "400 Bad Request", "text/plain", "invalid json\n");
        return;
    };
    defer parsed.deinit();
    const url = parsed.value.url;

    // Derive package name: "git+https://github.com/User/serde.zig" -> "serde.zig"
    const http_url = if (std.mem.startsWith(u8, url, "git+")) url[4..] else url;
    const slash_pos = std.mem.lastIndexOfScalar(u8, http_url, '/') orelse 0;
    const raw_name = http_url[slash_pos + 1 ..];
    const pkg_name = if (std.mem.endsWith(u8, raw_name, ".git"))
        raw_name[0 .. raw_name.len - 4]
    else
        raw_name;

    // Unique temp directory for the clone.
    const tmp_path = try std.fmt.allocPrint(
        allocator,
        "/tmp/packbase-{d}",
        .{std.time.nanoTimestamp()},
    );
    defer allocator.free(tmp_path);
    defer std.fs.deleteTreeAbsolute(tmp_path) catch {};

    // Clone the upstream repository.
    runCommand(allocator, &[_][]const u8{ "git", "clone", "--quiet", http_url, tmp_path }) catch {
        try sendSimpleResponse(connection, "502 Bad Gateway", "text/plain", "git clone failed\n");
        return;
    };

    // Resolve the most recent tag.
    const tag_raw = runCommandOutput(allocator, &[_][]const u8{
        "git", "-C", tmp_path, "describe", "--tags", "--abbrev=0",
    }) catch {
        try sendSimpleResponse(connection, "422 Unprocessable Entity", "text/plain", "no tags found\n");
        return;
    };
    defer allocator.free(tag_raw);
    const tag = std.mem.trim(u8, tag_raw, " \t\r\n");

    // Materialise the tarball at $PACKBASE_ROOT/p/<name>/tag/<tag>.tar.gz
    const pkg_dir = try std.fmt.allocPrint(allocator, "{s}/p/{s}/tag", .{ root, pkg_name });
    defer allocator.free(pkg_dir);
    // mkdir -p is the most reliable way to create nested absolute dirs.
    try runCommand(allocator, &[_][]const u8{ "mkdir", "-p", pkg_dir });

    const tarball_path = try std.fmt.allocPrint(allocator, "{s}/{s}.tar.gz", .{ pkg_dir, tag });
    defer allocator.free(tarball_path);

    // Check out the resolved tag into the working tree.
    runCommand(allocator, &[_][]const u8{
        "git", "-C", tmp_path, "checkout", "--quiet", tag,
    }) catch {
        try sendSimpleResponse(connection, "500 Internal Server Error", "text/plain", "checkout failed\n");
        return;
    };

    // zig fetch expects an archive with a single top-level directory (GitHub
    // style: repo-tag/).  Creating the tar directly from "." produces a "./"
    // root entry that confuses Zig's tar parser.  Copy the working tree into a
    // named staging directory first so the archive contains a proper prefix.
    const stage_path = try std.fmt.allocPrint(allocator, "{s}_stage", .{tmp_path});
    defer allocator.free(stage_path);
    defer std.fs.deleteTreeAbsolute(stage_path) catch {};

    try runCommand(allocator, &[_][]const u8{ "cp", "-r", tmp_path, stage_path });
    // Drop the .git dir from the staging copy.
    const stage_git = try std.fs.path.join(allocator, &.{ stage_path, ".git" });
    defer allocator.free(stage_git);
    std.fs.deleteTreeAbsolute(stage_git) catch {};

    const stage_parent = std.fs.path.dirname(stage_path) orelse "/tmp";
    const stage_base = std.fs.path.basename(stage_path);

    runCommand(allocator, &[_][]const u8{
        "tar", "czf", tarball_path, "-C", stage_parent, stage_base,
    }) catch {
        try sendSimpleResponse(connection, "500 Internal Server Error", "text/plain", "archive failed\n");
        return;
    };

    // Respond with the local URL where the package is now reachable.
    const pkg_url = try std.fmt.allocPrint(
        allocator,
        "/p/{s}/tag/{s}.tar.gz",
        .{ pkg_name, tag },
    );
    defer allocator.free(pkg_url);

    const resp_body = try std.fmt.allocPrint(
        allocator,
        "{{\"status\":\"ok\",\"package\":\"{s}\",\"tag\":\"{s}\",\"url\":\"{s}\"}}\n",
        .{ pkg_name, tag, pkg_url },
    );
    defer allocator.free(resp_body);

    try writeHeaders(connection, "200 OK", "application/json", resp_body.len);
    try connection.stream.writeAll(resp_body);
}

// ── HTTP helpers ──────────────────────────────────────────────────────────────

fn findHeader(raw: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, raw, "\r\n");
    _ = lines.next(); // skip request line
    while (lines.next()) |line| {
        if (line.len == 0) break; // empty line ends headers
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const hname = std.mem.trim(u8, line[0..colon], " ");
        const hvalue = std.mem.trim(u8, line[colon + 1 ..], " ");
        if (std.ascii.eqlIgnoreCase(hname, name)) return hvalue;
    }
    return null;
}

fn findBody(raw: []const u8) []const u8 {
    const sep = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return "";
    return raw[sep + 4 ..];
}

fn parseRequest(raw: []const u8) !Request {
    const line_end = std.mem.indexOf(u8, raw, "\r\n") orelse return error.BadRequest;
    const line = raw[0..line_end];
    var parts = std.mem.splitScalar(u8, line, ' ');
    const method = parts.next() orelse return error.BadRequest;
    const target = parts.next() orelse return error.BadRequest;
    _ = parts.next() orelse return error.BadRequest;
    return .{ .method = method, .target = target };
}

fn requestPath(target: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return target[0..q];
}

fn resolvePath(allocator: std.mem.Allocator, root: []const u8, raw_path: []const u8) ![]u8 {
    if (raw_path.len == 0 or raw_path[0] != '/') return error.BadRequest;

    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);

    try parts.append(allocator, root);

    var it = std.mem.splitScalar(u8, raw_path[1..], '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) return error.BadPath;
        try parts.append(allocator, part);
    }

    return std.fs.path.join(allocator, parts.items);
}

fn writeHeaders(
    connection: *std.net.Server.Connection,
    status: []const u8,
    mime: []const u8,
    size: u64,
) !void {
    var buf: [512]u8 = undefined;
    const resp = try std.fmt.bufPrint(
        &buf,
        "HTTP/1.1 {s}\r\nContent-Length: {d}\r\nContent-Type: {s}\r\nConnection: close\r\n\r\n",
        .{ status, size, mime },
    );
    try connection.stream.writeAll(resp);
}

fn sendSimpleResponse(
    connection: *std.net.Server.Connection,
    status: []const u8,
    mime: []const u8,
    body: []const u8,
) !void {
    var buf: [512]u8 = undefined;
    const resp = try std.fmt.bufPrint(
        &buf,
        "HTTP/1.1 {s}\r\nContent-Length: {d}\r\nContent-Type: {s}\r\nConnection: close\r\n\r\n{s}",
        .{ status, body.len, mime, body },
    );
    try connection.stream.writeAll(resp);
}

fn sendLandingPage(connection: *std.net.Server.Connection, head_only: bool) !void {
    const body =
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="UTF-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\  <title>packbase</title>
        \\  <style>
        \\    * { box-sizing: border-box; margin: 0; padding: 0; }
        \\    body {
        \\      font-family: "DejaVu Sans Mono", "Courier New", monospace;
        \\      background: #f5f5f5;
        \\      color: #222;
        \\      min-height: 100vh;
        \\    }
        \\    header {
        \\      background: #a23;
        \\      color: #fff;
        \\      padding: 0.6rem 1.2rem;
        \\      font-size: 0.95rem;
        \\      letter-spacing: 0.02em;
        \\    }
        \\    header span { opacity: 0.75; margin-left: 1.5rem; }
        \\    main {
        \\      max-width: 860px;
        \\      margin: 2.5rem auto;
        \\      padding: 0 1rem;
        \\    }
        \\    h1 { font-size: 1.5rem; margin-bottom: 0.3rem; }
        \\    .subtitle { color: #555; font-size: 0.9rem; margin-bottom: 2rem; }
        \\    table {
        \\      width: 100%;
        \\      border-collapse: collapse;
        \\      background: #fff;
        \\      border: 1px solid #ddd;
        \\      font-size: 0.9rem;
        \\    }
        \\    th {
        \\      background: #e8e8e8;
        \\      text-align: left;
        \\      padding: 0.5rem 0.8rem;
        \\      border-bottom: 1px solid #ccc;
        \\      font-weight: bold;
        \\    }
        \\    td { padding: 0.5rem 0.8rem; border-bottom: 1px solid #eee; vertical-align: top; }
        \\    tr:last-child td { border-bottom: none; }
        \\    code {
        \\      background: #f0f0f0;
        \\      padding: 0.15rem 0.4rem;
        \\      border-radius: 3px;
        \\      font-size: 0.85rem;
        \\    }
        \\    .method {
        \\      display: inline-block;
        \\      padding: 0.1rem 0.45rem;
        \\      border-radius: 3px;
        \\      font-size: 0.78rem;
        \\      font-weight: bold;
        \\      letter-spacing: 0.04em;
        \\    }
        \\    .get  { background: #d4edda; color: #155724; }
        \\    .post { background: #cce5ff; color: #004085; }
        \\    footer {
        \\      text-align: center;
        \\      color: #999;
        \\      font-size: 0.8rem;
        \\      margin: 3rem 0 1.5rem;
        \\    }
        \\    footer a { color: #a23; text-decoration: none; }
        \\    footer a:hover { text-decoration: underline; }
        \\  </style>
        \\</head>
        \\<body>
        \\  <header>
        \\    packbase
        \\    <span>self-hosted Zig package registry</span>
        \\  </header>
        \\  <main>
        \\    <h1>packbase</h1>
        \\    <p class="subtitle">
        \\      This server mirrors upstream Git repositories and serves deterministic
        \\      tarballs so that <code>zig fetch</code> never has to reach GitHub at
        \\      install time.
        \\    </p>
        \\    <table>
        \\      <thead>
        \\        <tr><th>Method</th><th>Endpoint</th><th>Description</th></tr>
        \\      </thead>
        \\      <tbody>
        \\        <tr>
        \\          <td><span class="method post">POST</span></td>
        \\          <td><code>/api/fetch</code></td>
        \\          <td>
        \\            Mirror an upstream Git repository.<br>
        \\            Requires <code>Authorization: Bearer &lt;token&gt;</code> and JSON body
        \\            <code>{"url":"git+https://&#8230;"}</code>.
        \\          </td>
        \\        </tr>
        \\        <tr>
        \\          <td><span class="method get">GET</span></td>
        \\          <td><code>/p/&lt;pkg&gt;/tag/&lt;tag&gt;.tar.gz</code></td>
        \\          <td>Download a mirrored tarball for <code>zig fetch --save</code>.</td>
        \\        </tr>
        \\        <tr>
        \\          <td><span class="method get">GET</span></td>
        \\          <td><code>/git/&lt;repo&gt;.git/&#8230;</code></td>
        \\          <td>Dumb-HTTP Git endpoint for fixture repositories.</td>
        \\        </tr>
        \\      </tbody>
        \\    </table>
        \\  </main>
        \\  <footer>
        \\    <a href="https://github.com/francescobianco/packbase">github.com/francescobianco/packbase</a>
        \\  </footer>
        \\</body>
        \\</html>
    ;
    try writeHeaders(connection, "200 OK", "text/html; charset=utf-8", body.len);
    if (!head_only) try connection.stream.writeAll(body);
}

fn contentType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".txt")) return "text/plain; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".md")) return "text/markdown; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json";
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".tar.gz")) return "application/gzip";
    return "application/octet-stream";
}

// ── Child process helpers ─────────────────────────────────────────────────────

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn runCommandOutput(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = try child.stdout.?.read(&tmp);
        if (n == 0) break;
        try out.appendSlice(allocator, tmp[0..n]);
    }

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
    return try out.toOwnedSlice(allocator);
}