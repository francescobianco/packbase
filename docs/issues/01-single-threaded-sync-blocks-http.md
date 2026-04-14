# Issue 01 — Sync operation blocks all HTTP responses

## Summary

When `/api/update` is called, the server becomes completely unresponsive to all other HTTP
requests for the entire duration of the sync. In production, syncing 79 packages from GitHub
can take several minutes, during which `zig fetch`, `/api/list`, `/api/info`, and every other
endpoint time out.

## Root cause

`main.zig` runs a single-threaded accept loop:

```zig
while (true) {
    var connection = try server.accept();
    defer connection.stream.close();
    handleConnection(...) catch |err| { ... };
}
```

`handleConnection` calls `handleUpdate`, which in turn calls `sync.syncSourceRepos` and
`sync.syncPackages` synchronously and only returns after all tarballs have been created.
No other connection can be accepted until these functions return.

## Impact

- `zig fetch --save git+https://...` fails with a connection timeout while sync is running.
- Health checks and monitoring (`/api/info`) cannot reach the server.
- The effective concurrency of the server is 1 request at a time.

## Proposed fix

Run the sync work in a background thread so that `/api/update` responds immediately and the
server keeps accepting new connections while the sync proceeds.

**Sketch:**

```zig
// handleUpdate — respond immediately, spawn worker thread
fn handleUpdate(...) !void {
    var stats = try sync.beginUpdateWindow(allocator, root);
    if (stats.queued or stats.rate_limited) {
        // ... write cooldown response as today ...
        return;
    }
    // Respond before doing the work
    try http.writeHeaders(connection, "200 OK", "application/json", ...);
    try connection.stream.writeAll("{\"status\":\"started\"}\n");

    // Hand ownership to the thread; thread frees args and calls finishUpdateWindow
    const args = try allocator.create(SyncArgs);
    args.* = .{ .root = try allocator.dupe(u8, root), .source_url = ... };
    const t = try std.Thread.spawn(.{}, syncWorker, .{args});
    t.detach();
}
```

The file-based lock (`update.lock`) already prevents concurrent syncs, so thread safety for
the lock state is handled. Per-thread GPA allocators avoid contention on the shared allocator.

## Status

- [ ] Design thread ownership / allocator model
- [ ] Implement `syncWorker` + `SyncArgs`
- [ ] Verify lock semantics under concurrent `/api/update` calls
- [ ] Update smoke test to poll `/api/info` for `state == "idle"` instead of waiting inline
