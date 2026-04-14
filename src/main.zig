const std = @import("std");

const Request = struct {
    method: []const u8,
    target: []const u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const root_env = std.posix.getenv("PACKBASE_ROOT");
    const port_env = std.posix.getenv("PACKBASE_PORT");
    const root = if (root_env) |value| value else "public";
    const port_text = if (port_env) |value| value else "8080";
    const port = try std.fmt.parseInt(u16, port_text, 10);

    const address = try std.net.Address.parseIp("0.0.0.0", port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.log.info("serving {s} on 0.0.0.0:{d}", .{ root, port });

    while (true) {
        var connection = try server.accept();
        defer connection.stream.close();

        handleConnection(allocator, &connection, root) catch |err| {
            std.log.warn("request failed: {s}", .{@errorName(err)});
        };
    }
}

fn handleConnection(allocator: std.mem.Allocator, connection: *std.net.Server.Connection, root: []const u8) !void {
    var buffer: [8192]u8 = undefined;
    const bytes_read = try connection.stream.read(&buffer);
    if (bytes_read == 0) return;

    const request = try parseRequest(buffer[0..bytes_read]);
    const head_only = std.mem.eql(u8, request.method, "HEAD");

    if (!std.mem.eql(u8, request.method, "GET") and !head_only) {
        try sendSimpleResponse(connection, "405 Method Not Allowed", "text/plain", "method not allowed\n");
        return;
    }

    const path = requestPath(request.target);
    const resolved_path = try resolvePath(allocator, root, path);
    defer allocator.free(resolved_path);

    var file = std.fs.cwd().openFile(resolved_path, .{}) catch |err| switch (err) {
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
    const size = stat.size;

    try writeHeaders(connection, "200 OK", contentType(resolved_path), size);
    if (head_only) return;

    var file_buffer: [4096]u8 = undefined;
    while (true) {
        const chunk_len = try file.read(&file_buffer);
        if (chunk_len == 0) break;
        try connection.stream.writeAll(file_buffer[0..chunk_len]);
    }
}

fn parseRequest(raw: []const u8) !Request {
    const line_end = std.mem.indexOf(u8, raw, "\r\n") orelse return error.BadRequest;
    const line = raw[0..line_end];

    var parts = std.mem.splitScalar(u8, line, ' ');
    const method = parts.next() orelse return error.BadRequest;
    const target = parts.next() orelse return error.BadRequest;
    _ = parts.next() orelse return error.BadRequest;

    return .{
        .method = method,
        .target = target,
    };
}

fn requestPath(target: []const u8) []const u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return target[0..query_start];
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

fn writeHeaders(connection: *std.net.Server.Connection, status: []const u8, mime: []const u8, size: u64) !void {
    var header_buffer: [512]u8 = undefined;
    const response = try std.fmt.bufPrint(
        &header_buffer,
        "HTTP/1.1 {s}\r\nContent-Length: {d}\r\nContent-Type: {s}\r\nConnection: close\r\n\r\n",
        .{ status, size, mime },
    );
    try connection.stream.writeAll(response);
}

fn sendSimpleResponse(connection: *std.net.Server.Connection, status: []const u8, mime: []const u8, body: []const u8) !void {
    var header_buffer: [512]u8 = undefined;
    const response = try std.fmt.bufPrint(
        &header_buffer,
        "HTTP/1.1 {s}\r\nContent-Length: {d}\r\nContent-Type: {s}\r\nConnection: close\r\n\r\n{s}",
        .{ status, body.len, mime, body },
    );
    try connection.stream.writeAll(response);
}

fn contentType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".txt")) return "text/plain; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".md")) return "text/markdown; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json";
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    return "application/octet-stream";
}
