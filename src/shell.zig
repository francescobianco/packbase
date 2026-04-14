const std = @import("std");

pub fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
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

pub fn runCommandOutput(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
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
