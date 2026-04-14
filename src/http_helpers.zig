const std = @import("std");
const types = @import("types.zig");

pub fn findHeader(raw: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, raw, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const hname = std.mem.trim(u8, line[0..colon], " ");
        const hvalue = std.mem.trim(u8, line[colon + 1 ..], " ");
        if (std.ascii.eqlIgnoreCase(hname, name)) return hvalue;
    }
    return null;
}

pub fn findBody(raw: []const u8) []const u8 {
    const sep = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return "";
    return raw[sep + 4 ..];
}

pub fn parseRequest(raw: []const u8) !types.Request {
    const line_end = std.mem.indexOf(u8, raw, "\r\n") orelse return error.BadRequest;
    const line = raw[0..line_end];
    var parts = std.mem.splitScalar(u8, line, ' ');
    const method = parts.next() orelse return error.BadRequest;
    const target = parts.next() orelse return error.BadRequest;
    _ = parts.next() orelse return error.BadRequest;
    return .{ .method = method, .target = target };
}

pub fn requestPath(target: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return target[0..q];
}

pub fn queryParam(target: []const u8, name: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    const query = target[q + 1 ..];
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (std.mem.eql(u8, pair, name)) return "";
        if (std.mem.startsWith(u8, pair, name)) {
            if (pair[name.len] == '=') return pair[name.len + 1 ..];
        }
    }
    return null;
}

pub fn routePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len < 2 or path[0] != '/') return allocator.dupe(u8, path);

    const first_end = std.mem.indexOfScalarPos(u8, path, 1, '/') orelse path.len;
    const repo_name = path[1..first_end];
    if (repo_name.len == 0) return allocator.dupe(u8, path);

    if (std.mem.eql(u8, repo_name, "api") or
        std.mem.eql(u8, repo_name, "git") or
        std.mem.eql(u8, repo_name, "p"))
    {
        return allocator.dupe(u8, path);
    }

    if (std.mem.endsWith(u8, repo_name, ".git")) return allocator.dupe(u8, path);

    const remainder = path[first_end..];
    return std.fmt.allocPrint(allocator, "/git/{s}.git{s}", .{ repo_name, remainder });
}

pub fn resolvePath(allocator: std.mem.Allocator, root: []const u8, raw_path: []const u8) ![]u8 {
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

pub fn writeHeaders(
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

pub fn sendSimpleResponse(
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

pub fn contentType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".txt")) return "text/plain; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".md")) return "text/markdown; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json";
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".tar.gz")) return "application/gzip";
    return "application/octet-stream";
}

pub fn isSmartHttpRequest(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, "/git/")) return true;
    if (std.mem.containsAtLeast(u8, path, 1, "/") and !std.mem.containsAtLeast(u8, path, 2, "/")) return false;
    const end = std.mem.indexOfScalar(u8, path[1..], '/') orelse return false;
    const repo_part = path[1..][0..end];
    if (std.mem.endsWith(u8, repo_part, ".git")) return true;
    if (std.mem.containsAtLeast(u8, path, 2, "/")) {
        const remainder = path[1..][end..];
        return std.mem.eql(u8, remainder, "/info/refs") or std.mem.eql(u8, remainder, "/git-upload-pack") or std.mem.eql(u8, remainder, "/git-receive-pack");
    }
    return false;
}

pub fn sendLandingPage(connection: *std.net.Server.Connection, head_only: bool) !void {
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
        \\          <td>Mirror an upstream Git repository.</td>
        \\        </tr>
        \\        <tr>
        \\          <td><span class="method post">POST</span></td>
        \\          <td><code>/api/update</code></td>
        \\          <td>Soft-sync local state and the configured package source.</td>
        \\        </tr>
        \\        <tr>
        \\          <td><span class="method get">GET</span></td>
        \\          <td><code>/api/list</code></td>
        \\          <td>Return local and registered packages visible to this instance.</td>
        \\        </tr>
        \\        <tr>
        \\          <td><span class="method get">GET</span></td>
        \\          <td><code>/api/info</code></td>
        \\          <td>Return service metadata including the current release id.</td>
        \\        </tr>
        \\        <tr>
        \\          <td><span class="method get">GET</span></td>
        \\          <td><code>/&lt;repo&gt;/&#8230;</code></td>
        \\          <td>Alias for cloning hosted repositories without the <code>/git</code> prefix.</td>
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
