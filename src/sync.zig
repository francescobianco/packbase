const std = @import("std");
const types = @import("types.zig");
const shell = @import("shell.zig");
const git_proto = @import("git.zig");

pub fn beginUpdateWindow(allocator: std.mem.Allocator, root: []const u8) !types.SyncStats {
    var stats = types.SyncStats{};
    const now = std.time.timestamp();
    const state_dir = try ensureStateDir(allocator, root);
    defer allocator.free(state_dir);

    const lock_path = try std.fs.path.join(allocator, &.{ state_dir, "update.lock" });
    defer allocator.free(lock_path);
    const pending_path = try std.fs.path.join(allocator, &.{ state_dir, "update.pending" });
    defer allocator.free(pending_path);
    const last_path = try std.fs.path.join(allocator, &.{ state_dir, "update.last" });
    defer allocator.free(last_path);

    if (readIntFile(allocator, lock_path)) |started_at| {
        if (now - started_at < 300) {
            try writeIntFile(pending_path, now);
            try writeUpdateStatus(allocator, root, "queued", started_at, now, &stats);
            stats.queued = true;
            return stats;
        }
        std.fs.cwd().deleteFile(lock_path) catch {};
    } else |_| {}

    if (readIntFile(allocator, last_path)) |last_request| {
        const delta = now - last_request;
        if (delta < 15) {
            stats.rate_limited = true;
            stats.retry_after = 15 - delta;
            try writeUpdateStatus(allocator, root, "cooldown", last_request, now, &stats);
            return stats;
        }
    } else |_| {}

    try writeIntFile(last_path, now);
    try writeIntFile(lock_path, now);
    try writeUpdateStatus(allocator, root, "running", now, now, &stats);
    return stats;
}

pub fn finishUpdateWindow(allocator: std.mem.Allocator, root: []const u8, stats: ?*const types.SyncStats) !void {
    const state_dir = try ensureStateDir(allocator, root);
    defer allocator.free(state_dir);

    const lock_path = try std.fs.path.join(allocator, &.{ state_dir, "update.lock" });
    defer allocator.free(lock_path);
    const pending_path = try std.fs.path.join(allocator, &.{ state_dir, "update.pending" });
    defer allocator.free(pending_path);

    std.fs.cwd().deleteFile(lock_path) catch {};
    std.fs.cwd().deleteFile(pending_path) catch {};
    if (stats) |s| {
        try writeUpdateStatus(allocator, root, "idle", std.time.timestamp(), std.time.timestamp(), s);
    }
}

pub fn writeUpdateProgress(allocator: std.mem.Allocator, root: []const u8, stats: *const types.SyncStats) !void {
    const now = std.time.timestamp();
    try writeUpdateStatus(allocator, root, "running", now, now, stats);
}

pub fn readUpdateStatusJson(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    const state_dir = try ensureStateDir(allocator, root);
    defer allocator.free(state_dir);
    const status_path = try std.fs.path.join(allocator, &.{ state_dir, "update.status.json" });
    defer allocator.free(status_path);

    const raw = try readOptionalFileAlloc(allocator, status_path, 16 * 1024) orelse
        return allocator.dupe(u8, "{\"state\":\"idle\"}");
    return raw;
}

pub fn listPackagesJson(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    var local_names = try collectLocalPackageNames(allocator, root);
    defer {
        for (local_names.items) |name| allocator.free(name);
        local_names.deinit(allocator);
    }

    var registered_names = try collectRegisteredPackageNames(allocator, root);
    defer {
        for (registered_names.items) |name| allocator.free(name);
        registered_names.deinit(allocator);
    }

    std.mem.sort([]u8, local_names.items, {}, sortStringAsc);
    std.mem.sort([]u8, registered_names.items, {}, sortStringAsc);

    var merged = std.ArrayList([]u8).empty;
    defer merged.deinit(allocator);
    try appendMergedNames(allocator, &merged, local_names.items, registered_names.items);

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);

    try body.appendSlice(allocator, "{\"packages\":[");
    for (merged.items, 0..) |name, index| {
        if (index != 0) try body.append(allocator, ',');
        try appendJsonString(allocator, &body, name);
    }
    try body.appendSlice(allocator, "],\"local_packages\":[");
    for (local_names.items, 0..) |name, index| {
        if (index != 0) try body.append(allocator, ',');
        try appendJsonString(allocator, &body, name);
    }
    try body.appendSlice(allocator, "],\"registered_packages\":[");
    for (registered_names.items, 0..) |name, index| {
        if (index != 0) try body.append(allocator, ',');
        try appendJsonString(allocator, &body, name);
    }
    try body.appendSlice(allocator, "]}\n");

    return try body.toOwnedSlice(allocator);
}

pub fn searchPackagesJson(allocator: std.mem.Allocator, root: []const u8, query: []const u8) ![]u8 {
    var local_names = try collectLocalPackageNames(allocator, root);
    defer {
        for (local_names.items) |name| allocator.free(name);
        local_names.deinit(allocator);
    }

    var registered_names = try collectRegisteredPackageNames(allocator, root);
    defer {
        for (registered_names.items) |name| allocator.free(name);
        registered_names.deinit(allocator);
    }

    std.mem.sort([]u8, local_names.items, {}, sortStringAsc);
    std.mem.sort([]u8, registered_names.items, {}, sortStringAsc);

    var merged = std.ArrayList([]u8).empty;
    defer merged.deinit(allocator);
    try appendMergedNames(allocator, &merged, local_names.items, registered_names.items);

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);

    try body.appendSlice(allocator, "{\"query\":");
    try appendJsonString(allocator, &body, query);
    try body.appendSlice(allocator, ",\"packages\":[");
    var first = true;
    for (merged.items) |name| {
        if (!containsCaseInsensitive(name, query)) continue;
        if (!first) try body.append(allocator, ',');
        first = false;
        try appendJsonString(allocator, &body, name);
    }
    try body.appendSlice(allocator, "]}\n");

    return try body.toOwnedSlice(allocator);
}

fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub const SnapshotProbeData = struct {
    pseudo_git_fetchable: bool,
    fetch_probe_commit: ?[]u8,
    fetch_probe_error: ?[]u8,
    healthy: bool,
};

pub const PackageHealthSummary = struct {
    total: usize = 0,
    healthy: usize = 0,
    unhealthy: usize = 0,
};

pub const SourcePackageSyncResult = struct {
    package_name: []u8,
    latest_tag: []u8,
    tarballs_created: usize = 0,
    tarballs_present: usize = 0,

    pub fn deinit(self: *SourcePackageSyncResult, allocator: std.mem.Allocator) void {
        allocator.free(self.package_name);
        allocator.free(self.latest_tag);
        self.* = undefined;
    }
};

const RemoteTag = struct {
    name: []u8,
    target: git_proto.Oid,
};

pub fn loadSnapshotProbeData(
    allocator: std.mem.Allocator,
    root: []const u8,
) !std.StringHashMap(SnapshotProbeData) {
    var map = std.StringHashMap(SnapshotProbeData).init(allocator);
    errdefer freeSnapshotProbeData(allocator, &map);

    const state_dir = try ensureStateDir(allocator, root);
    defer allocator.free(state_dir);
    const snapshot_path = try std.fs.path.join(allocator, &.{ state_dir, "package-info.json" });
    defer allocator.free(snapshot_path);

    const raw = (try readOptionalFileAlloc(allocator, snapshot_path, 32 * 1024 * 1024)) orelse return map;
    defer allocator.free(raw);

    const parsed = try std.json.parseFromSlice(types.PackageInfoSnapshot, allocator, raw, .{});
    defer parsed.deinit();

    for (parsed.value.packages) |info| {
        const key = try allocator.dupe(u8, info.package);
        errdefer allocator.free(key);
        const commit = if (info.fetch_probe_commit) |c| try allocator.dupe(u8, c) else null;
        errdefer if (commit) |c| allocator.free(c);
        const probe_err = if (info.fetch_probe_error) |e| try allocator.dupe(u8, e) else null;
        errdefer if (probe_err) |e| allocator.free(e);
        try map.put(key, .{
            .pseudo_git_fetchable = info.pseudo_git_fetchable,
            .fetch_probe_commit = commit,
            .fetch_probe_error = probe_err,
            .healthy = info.healthy,
        });
    }
    return map;
}

pub fn freeSnapshotProbeData(allocator: std.mem.Allocator, map: *std.StringHashMap(SnapshotProbeData)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        if (entry.value_ptr.fetch_probe_commit) |c| allocator.free(c);
        if (entry.value_ptr.fetch_probe_error) |e| allocator.free(e);
    }
    map.deinit();
}

pub fn readPackageHealthSummary(allocator: std.mem.Allocator, root: []const u8) !PackageHealthSummary {
    const state_dir = try ensureStateDir(allocator, root);
    defer allocator.free(state_dir);
    const snapshot_path = try std.fs.path.join(allocator, &.{ state_dir, "package-info.json" });
    defer allocator.free(snapshot_path);

    const raw = (try readOptionalFileAlloc(allocator, snapshot_path, 32 * 1024 * 1024)) orelse return .{};
    defer allocator.free(raw);

    const parsed = try std.json.parseFromSlice(types.PackageInfoSnapshot, allocator, raw, .{});
    defer parsed.deinit();

    var summary = PackageHealthSummary{};
    for (parsed.value.packages) |info| {
        summary.total += 1;
        if (info.healthy) {
            summary.healthy += 1;
        } else {
            summary.unhealthy += 1;
        }
    }
    return summary;
}

pub fn collectPackageInfos(allocator: std.mem.Allocator, root: []const u8) !std.ArrayList(types.PackageInfo) {
    var local_names = try collectLocalPackageNames(allocator, root);
    defer {
        for (local_names.items) |name| allocator.free(name);
        local_names.deinit(allocator);
    }

    var registered_names = try collectRegisteredPackageNames(allocator, root);
    defer {
        for (registered_names.items) |name| allocator.free(name);
        registered_names.deinit(allocator);
    }

    std.mem.sort([]u8, local_names.items, {}, sortStringAsc);
    std.mem.sort([]u8, registered_names.items, {}, sortStringAsc);

    var merged = std.ArrayList([]u8).empty;
    defer merged.deinit(allocator);
    try appendMergedNames(allocator, &merged, local_names.items, registered_names.items);

    var infos = std.ArrayList(types.PackageInfo).empty;
    errdefer freePackageInfoList(allocator, &infos);

    for (merged.items) |package_name| {
        const local = containsName(local_names.items, package_name);
        const registered = containsName(registered_names.items, package_name);
        const tarball_dir = try std.fs.path.join(allocator, &.{ root, "p", package_name, "tag" });
        defer allocator.free(tarball_dir);
        const tarball_dir_present = accessExists(tarball_dir);

        var tarballs = try collectTarballInfos(allocator, tarball_dir);
        defer {
            for (tarballs.items) |tag_info| allocator.free(tag_info.tag);
            tarballs.deinit(allocator);
        }
        std.mem.sort(types.PackageTagInfo, tarballs.items, {}, sortPackageTagInfoAsc);

        var tarballs_copy = try allocator.alloc(types.PackageTagInfo, tarballs.items.len);
        errdefer {
            for (tarballs_copy[0..tarballs.items.len]) |tag_info| allocator.free(tag_info.tag);
            allocator.free(tarballs_copy);
        }

        var total_size: u64 = 0;
        for (tarballs.items, 0..) |tag_info, index| {
            tarballs_copy[index] = .{
                .tag = try allocator.dupe(u8, tag_info.tag),
                .size_bytes = tag_info.size_bytes,
            };
            total_size += tag_info.size_bytes;
        }

        const latest = if (tarballs_copy.len == 0) null else tarballs_copy[tarballs_copy.len - 1];
        try infos.append(allocator, .{
            .package = try allocator.dupe(u8, package_name),
            .available = true,
            .registered = registered,
            .local = local,
            .tarball_dir_present = tarball_dir_present,
            .tarball_count = tarballs_copy.len,
            .latest_tag = if (latest) |tag_info| tag_info.tag else null,
            .latest_size_bytes = if (latest) |tag_info| tag_info.size_bytes else 0,
            .size_bytes = total_size,
            .tarballs = tarballs_copy,
            .smart_http_ready = tarballs_copy.len != 0,
        });
    }

    std.mem.sort(types.PackageInfo, infos.items, {}, sortPackageInfoAsc);
    return infos;
}

pub fn freePackageInfoList(allocator: std.mem.Allocator, infos: *std.ArrayList(types.PackageInfo)) void {
    for (infos.items) |info| {
        allocator.free(info.package);
        for (info.tarballs) |tag_info| allocator.free(tag_info.tag);
        allocator.free(info.tarballs);
        if (info.fetch_probe_commit) |commit| allocator.free(commit);
        if (info.fetch_probe_error) |probe_error| allocator.free(probe_error);
    }
    infos.deinit(allocator);
}

pub fn writePackageInfoSnapshot(allocator: std.mem.Allocator, root: []const u8, infos: []const types.PackageInfo) !void {
    const state_dir = try ensureStateDir(allocator, root);
    defer allocator.free(state_dir);
    const snapshot_path = try std.fs.path.join(allocator, &.{ state_dir, "package-info.json" });
    defer allocator.free(snapshot_path);

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);

    try body.appendSlice(allocator, "{\"packages\":[");
    for (infos, 0..) |info, index| {
        if (index != 0) try body.append(allocator, ',');
        try appendPackageInfoJson(allocator, &body, info);
    }
    try body.appendSlice(allocator, "]}\n");
    try writeTextFile(snapshot_path, body.items);
}

pub fn readPackageInfoJson(allocator: std.mem.Allocator, root: []const u8, package_name: []const u8) !?[]u8 {
    const state_dir = try ensureStateDir(allocator, root);
    defer allocator.free(state_dir);
    const snapshot_path = try std.fs.path.join(allocator, &.{ state_dir, "package-info.json" });
    defer allocator.free(snapshot_path);

    const raw = try readOptionalFileAlloc(allocator, snapshot_path, 32 * 1024 * 1024) orelse return error.FileNotFound;
    defer allocator.free(raw);

    const parsed = try std.json.parseFromSlice(types.PackageInfoSnapshot, allocator, raw, .{});
    defer parsed.deinit();

    for (parsed.value.packages) |info| {
        if (!std.mem.eql(u8, info.package, package_name)) continue;
        var body = std.ArrayList(u8).empty;
        defer body.deinit(allocator);
        try appendPackageInfoJson(allocator, &body, info);
        try body.append(allocator, '\n');
        return try body.toOwnedSlice(allocator);
    }
    return null;
}

pub fn syncPackages(allocator: std.mem.Allocator, root: []const u8) !types.SyncStats {
    var stats = types.SyncStats{};
    try scanAndSyncRepos(allocator, root, &stats);
    if (stats.repos_scanned != 0) return stats;

    if (try ensureBuiltInHelloSeed(allocator, root)) {
        stats.default_seeded = true;
        stats = .{ .default_seeded = true };
        try scanAndSyncRepos(allocator, root, &stats);
    }
    return stats;
}

pub fn syncSourceCatalog(
    allocator: std.mem.Allocator,
    root: []const u8,
    source_url: []const u8,
    stats: *types.SyncStats,
) !std.ArrayList(types.SourceRecord) {
    const empty = std.ArrayList(types.SourceRecord).empty;
    if (source_url.len == 0) return empty;

    const state_dir = try ensureStateDir(allocator, root);
    defer allocator.free(state_dir);
    const current_path = try std.fs.path.join(allocator, &.{ state_dir, "source.json" });
    defer allocator.free(current_path);
    const previous_path = try std.fs.path.join(allocator, &.{ state_dir, "source.previous.json" });
    defer allocator.free(previous_path);
    const registered_path = try std.fs.path.join(allocator, &.{ state_dir, "registered.json" });
    defer allocator.free(registered_path);
    const diff_path = try std.fs.path.join(allocator, &.{ state_dir, "source.diff.json" });
    defer allocator.free(diff_path);

    const new_raw = shell.runCommandOutput(allocator, &[_][]const u8{ "curl", "-fsS", source_url }) catch return empty;
    defer allocator.free(new_raw);

    const old_raw = try readOptionalFileAlloc(allocator, current_path, 16 * 1024 * 1024);
    defer if (old_raw) |buf| allocator.free(buf);

    const changed = if (old_raw) |old| !std.mem.eql(u8, old, new_raw) else true;
    stats.source_changed = changed;

    const new_records = try extractSourceRecords(allocator, new_raw);
    stats.source_packages = new_records.items.len;
    std.log.info(
        "source catalog loaded packages={d} changed={any}",
        .{ stats.source_packages, changed },
    );

    // Per-package updated_at cache: mark records as fresh when unchanged.
    const ts_dir = try std.fs.path.join(allocator, &.{ state_dir, "pkg-ts" });
    defer allocator.free(ts_dir);
    try shell.runCommand(allocator, &[_][]const u8{ "mkdir", "-p", ts_dir });
    for (new_records.items) |*record| {
        const ts_path = try std.fs.path.join(allocator, &.{ ts_dir, record.id });
        defer allocator.free(ts_path);
        const current_ts = std.mem.trim(u8, record.updated_at, " \t\r\n");
        if (current_ts.len > 0) {
            const stored_ts: ?[]u8 = readOptionalFileAlloc(allocator, ts_path, 128) catch null;
            defer if (stored_ts) |ts| allocator.free(ts);
            if (stored_ts) |ts| {
                if (std.mem.eql(u8, std.mem.trim(u8, ts, " \t\r\n"), current_ts)) {
                    record.fresh = true;
                    stats.source_skipped += 1;
                }
            }
        }
        writeTextFile(ts_path, record.updated_at) catch {};
    }
    std.log.info("source catalog skipped packages={d}", .{stats.source_skipped});

    if (old_raw) |old| {
        if (changed) {
            var old_records = try extractSourceRecords(allocator, old);
            defer freeSourceRecords(allocator, &old_records);
            computeSourceDiff(old_records.items, new_records.items, stats);
            try writeTextFile(previous_path, old);
        }
    } else {
        stats.source_added = new_records.items.len;
    }

    if (changed or old_raw == null) try writeTextFile(current_path, new_raw);
    try writeRegisteredSnapshot(allocator, registered_path, new_records.items);
    try writeSourceDiffSnapshot(allocator, diff_path, stats);
    return new_records;
}

pub fn syncSourceRepos(
    allocator: std.mem.Allocator,
    root: []const u8,
    records: []const types.SourceRecord,
    refresh_existing: bool,
    stats: *types.SyncStats,
) !void {
    _ = refresh_existing;
    for (records) |record| {
        if (record.fresh) continue;
        var result = syncSingleSourceRecord(allocator, root, record, stats) catch |err| {
            stats.source_repo_failed += 1;
            std.log.warn("source package sync failed package={s} error={s}", .{ record.package_name, @errorName(err) });
            continue;
        };
        result.deinit(allocator);
    }
}

pub fn syncSingleSourceRecord(
    allocator: std.mem.Allocator,
    root: []const u8,
    record: types.SourceRecord,
    stats: *types.SyncStats,
) !SourcePackageSyncResult {
    if (!isHttpGitUrl(record.repo_url)) {
        return syncSingleSourceRecordShell(allocator, root, record, stats);
    }

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const response_buffer = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(response_buffer);

    const uri = try std.Uri.parse(record.repo_url);
    const session = try git_proto.Session.init(arena, &client, uri, response_buffer);

    var tags = try listRemoteTagsProto(allocator, session, response_buffer);
    defer freeRemoteTagList(allocator, &tags);
    if (tags.items.len == 0) return error.NoTagsFound;

    const before_created = stats.tarballs_created;
    const before_present = stats.tarballs_present;
    for (tags.items) |tag| {
        try ensureFetchedRemoteTagTarballProto(allocator, root, record.package_name, tag, session, stats);
    }

    return .{
        .package_name = try allocator.dupe(u8, record.package_name),
        .latest_tag = try allocator.dupe(u8, tags.items[tags.items.len - 1].name),
        .tarballs_created = stats.tarballs_created - before_created,
        .tarballs_present = stats.tarballs_present - before_present,
    };
}

fn syncSingleSourceRecordShell(
    allocator: std.mem.Allocator,
    root: []const u8,
    record: types.SourceRecord,
    stats: *types.SyncStats,
) !SourcePackageSyncResult {
    var tags = try listRemoteTagsShell(allocator, record.repo_url);
    defer freeRemoteTagList(allocator, &tags);
    if (tags.items.len == 0) return error.NoTagsFound;

    const tmp_path = try std.fmt.allocPrint(allocator, "/tmp/packbase-source-{d}", .{std.time.nanoTimestamp()});
    defer allocator.free(tmp_path);
    defer std.fs.deleteTreeAbsolute(tmp_path) catch {};

    try shell.runCommand(allocator, &.{
        "git", "-c", "protocol.file.allow=always", "-c", "safe.directory=*",
        "init", "--quiet", tmp_path,
    });
    try shell.runCommand(allocator, &.{ "git", "-C", tmp_path, "remote", "add", "origin", record.repo_url });

    const before_created = stats.tarballs_created;
    const before_present = stats.tarballs_present;
    for (tags.items) |tag| {
        try ensureFetchedRemoteTagTarballShell(allocator, root, tmp_path, record.package_name, tag.name, stats);
    }

    return .{
        .package_name = try allocator.dupe(u8, record.package_name),
        .latest_tag = try allocator.dupe(u8, tags.items[tags.items.len - 1].name),
        .tarballs_created = stats.tarballs_created - before_created,
        .tarballs_present = stats.tarballs_present - before_present,
    };
}

pub fn freeSourceRecordList(allocator: std.mem.Allocator, records: *std.ArrayList(types.SourceRecord)) void {
    freeSourceRecords(allocator, records);
}

pub fn lookupSourceRecordByPackage(
    allocator: std.mem.Allocator,
    root: []const u8,
    package_name: []const u8,
) !?types.SourceRecord {
    const state_dir = try ensureStateDir(allocator, root);
    defer allocator.free(state_dir);
    const current_path = try std.fs.path.join(allocator, &.{ state_dir, "source.json" });
    defer allocator.free(current_path);

    const raw = try readOptionalFileAlloc(allocator, current_path, 16 * 1024 * 1024) orelse return null;
    defer allocator.free(raw);

    var records = try extractSourceRecords(allocator, raw);
    defer freeSourceRecords(allocator, &records);

    for (records.items) |record| {
        if (!std.mem.eql(u8, record.package_name, package_name)) continue;
        return .{
            .id = try allocator.dupe(u8, record.id),
            .repo_url = try allocator.dupe(u8, record.repo_url),
            .package_name = try allocator.dupe(u8, record.package_name),
            .default_ref = try allocator.dupe(u8, record.default_ref),
            .updated_at = try allocator.dupe(u8, record.updated_at),
        };
    }
    return null;
}

pub fn freeSourceRecord(allocator: std.mem.Allocator, record: *types.SourceRecord) void {
    allocator.free(record.id);
    allocator.free(record.repo_url);
    allocator.free(record.package_name);
    allocator.free(record.default_ref);
    allocator.free(record.updated_at);
    record.* = undefined;
}

fn ensureStateDir(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    const state_dir = try std.fs.path.join(allocator, &.{ root, ".packbase" });
    try shell.runCommand(allocator, &[_][]const u8{ "mkdir", "-p", state_dir });
    return state_dir;
}

fn writeUpdateStatus(
    allocator: std.mem.Allocator,
    root: []const u8,
    state: []const u8,
    started_at: i64,
    updated_at: i64,
    stats: *const types.SyncStats,
) !void {
    const state_dir = try ensureStateDir(allocator, root);
    defer allocator.free(state_dir);
    const status_path = try std.fs.path.join(allocator, &.{ state_dir, "update.status.json" });
    defer allocator.free(status_path);

    const base_body = try std.fmt.allocPrint(
        allocator,
        "{{\"state\":\"{s}\",\"started_at\":{d},\"updated_at\":{d},\"repos_scanned\":{d},\"packages_synced\":{d},\"tarballs_created\":{d},\"tarballs_present\":{d},\"default_seeded\":{s},\"source_changed\":{s},\"source_packages\":{d},\"source_added\":{d},\"source_updated\":{d},\"source_removed\":{d},\"retry_after\":{d},\"queued\":{s}}}\n",
        .{
            state,
            started_at,
            updated_at,
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
            stats.retry_after,
            if (stats.queued) "true" else "false",
        },
    );
    defer allocator.free(base_body);
    const body = try injectRepoSyncStats(allocator, base_body, stats);
    defer allocator.free(body);
    try writeTextFile(status_path, body);
}

fn writeIntFile(path: []const u8, value: i64) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}\n", .{value});
    try file.writeAll(text);
}

fn readIntFile(allocator: std.mem.Allocator, path: []const u8) !i64 {
    const raw = try readOptionalFileAlloc(allocator, path, 1024) orelse return error.FileNotFound;
    defer allocator.free(raw);
    return std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t\r\n"), 10);
}

fn readOptionalFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_size: usize) !?[]u8 {
    var file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();
    return try file.readToEndAlloc(allocator, max_size);
}

fn scanAndSyncRepos(allocator: std.mem.Allocator, root: []const u8, stats: *types.SyncStats) !void {
    const git_root = try std.fs.path.join(allocator, &.{ root, "git" });
    defer allocator.free(git_root);

    var dir = std.fs.cwd().openDir(git_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    var total_repos: usize = 0;
    {
        var count_dir = try std.fs.cwd().openDir(git_root, .{ .iterate = true });
        defer count_dir.close();
        var count_it = count_dir.iterate();
        while (try count_it.next()) |entry| {
            if (entry.kind != .directory) continue;
            if (!std.mem.endsWith(u8, entry.name, ".git")) continue;
            total_repos += 1;
        }
    }
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.endsWith(u8, entry.name, ".git")) continue;
        stats.repos_scanned += 1;
        std.log.info(
            "local repo [{d}/{d}] package={s}",
            .{ stats.repos_scanned, total_repos, entry.name[0 .. entry.name.len - 4] },
        );
        try syncRepoPackage(allocator, root, entry.name, entry.name[0 .. entry.name.len - 4], stats);
    }
}

fn syncRepoPackage(
    allocator: std.mem.Allocator,
    root: []const u8,
    repo_dir_name: []const u8,
    package_name: []const u8,
    stats: *types.SyncStats,
) !void {
    const repo_path = try std.fs.path.join(allocator, &.{ root, "git", repo_dir_name });
    defer allocator.free(repo_path);
    try shell.runCommand(allocator, &[_][]const u8{ "git", "-C", repo_path, "update-server-info" });

    const tags_raw = shell.runCommandOutput(allocator, &[_][]const u8{ "git", "-C", repo_path, "tag", "--list" }) catch return;
    defer allocator.free(tags_raw);

    var saw_tag = false;
    var tags = std.mem.splitScalar(u8, tags_raw, '\n');
    while (tags.next()) |raw_tag| {
        const tag = std.mem.trim(u8, raw_tag, " \t\r");
        if (tag.len == 0) continue;
        saw_tag = true;
        std.log.info("tarball sync package={s} tag={s}", .{ package_name, tag });
        try ensureRepoTarball(allocator, root, repo_path, package_name, tag, stats);
    }
    if (saw_tag) stats.packages_synced += 1;
}

fn ensureFetchedRemoteTagTarballShell(
    allocator: std.mem.Allocator,
    root: []const u8,
    repo_path: []const u8,
    package_name: []const u8,
    tag: []const u8,
    stats: *types.SyncStats,
) !void {
    const pkg_dir = try std.fs.path.join(allocator, &.{ root, "p", package_name, "tag" });
    defer allocator.free(pkg_dir);
    try shell.runCommand(allocator, &[_][]const u8{ "mkdir", "-p", pkg_dir });

    const tarball_name = try std.fmt.allocPrint(allocator, "{s}.tar.gz", .{tag});
    defer allocator.free(tarball_name);
    const tarball_path = try std.fs.path.join(allocator, &.{ pkg_dir, tarball_name });
    defer allocator.free(tarball_path);

    if (std.fs.cwd().access(tarball_path, .{})) |_| {
        stats.tarballs_present += 1;
        std.log.info("tarball present package={s} tag={s}", .{ package_name, tag });
        return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const tag_ref = try std.fmt.allocPrint(allocator, "refs/tags/{s}:refs/tags/{s}", .{ tag, tag });
    defer allocator.free(tag_ref);
    try shell.runCommand(allocator, &.{
        "git", "-c", "protocol.file.allow=always", "-c", "safe.directory=*",
        "-C", repo_path, "fetch", "--depth", "1", "--quiet", "origin", tag_ref,
    });

    try archiveGitTag(allocator, repo_path, tag, tarball_path);
    stats.tarballs_created += 1;
    std.log.info("tarball created package={s} tag={s}", .{ package_name, tag });
}

fn ensureRepoTarball(
    allocator: std.mem.Allocator,
    root: []const u8,
    repo_path: []const u8,
    package_name: []const u8,
    tag: []const u8,
    stats: *types.SyncStats,
) !void {
    const pkg_dir = try std.fs.path.join(allocator, &.{ root, "p", package_name, "tag" });
    defer allocator.free(pkg_dir);
    try shell.runCommand(allocator, &[_][]const u8{ "mkdir", "-p", pkg_dir });

    const tarball_name = try std.fmt.allocPrint(allocator, "{s}.tar.gz", .{tag});
    defer allocator.free(tarball_name);
    const tarball_path = try std.fs.path.join(allocator, &.{ pkg_dir, tarball_name });
    defer allocator.free(tarball_path);

    if (std.fs.path.dirname(tarball_path)) |tarball_parent| {
        try shell.runCommand(allocator, &[_][]const u8{ "mkdir", "-p", tarball_parent });
    }

    if (std.fs.cwd().access(tarball_path, .{})) |_| {
        stats.tarballs_present += 1;
        std.log.info("tarball present package={s} tag={s}", .{ package_name, tag });
        return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    try archiveGitTag(allocator, repo_path, tag, tarball_path);
    stats.tarballs_created += 1;
    std.log.info("tarball created package={s} tag={s}", .{ package_name, tag });
}

fn listRemoteTagsShell(allocator: std.mem.Allocator, repo_url: []const u8) !std.ArrayList(RemoteTag) {
    const tags_raw = try shell.runCommandOutput(allocator, &.{
        "git", "-c", "protocol.file.allow=always", "-c", "safe.directory=*",
        "ls-remote", "--tags", "--refs", repo_url,
    });
    defer allocator.free(tags_raw);

    var tags = std.ArrayList(RemoteTag).empty;
    errdefer {
        freeRemoteTagList(allocator, &tags);
        tags.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, tags_raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, trimmed, '\t') orelse continue;
        const ref_name = trimmed[tab + 1 ..];
        if (!std.mem.startsWith(u8, ref_name, "refs/tags/")) continue;
        try tags.append(allocator, .{
            .name = try allocator.dupe(u8, ref_name["refs/tags/".len..]),
            .target = git_proto.Oid.parseAny(trimmed[0..tab]) catch continue,
        });
    }

    std.mem.sort(RemoteTag, tags.items, {}, sortRemoteTagAsc);
    return tags;
}

fn listRemoteTagsProto(
    allocator: std.mem.Allocator,
    session: git_proto.Session,
    response_buffer: []u8,
) !std.ArrayList(RemoteTag) {
    var it: git_proto.Session.RefIterator = undefined;
    try session.listRefs(&it, .{
        .ref_prefixes = &.{"refs/tags/"},
        .include_peeled = true,
        .buffer = response_buffer,
    });
    defer it.deinit();

    var tags = std.ArrayList(RemoteTag).empty;
    errdefer {
        freeRemoteTagList(allocator, &tags);
        tags.deinit(allocator);
    }

    while (try it.next()) |ref| {
        if (!std.mem.startsWith(u8, ref.name, "refs/tags/")) continue;
        try tags.append(allocator, .{
            .name = try allocator.dupe(u8, ref.name["refs/tags/".len..]),
            .target = ref.peeled orelse ref.oid,
        });
    }

    std.mem.sort(RemoteTag, tags.items, {}, sortRemoteTagAsc);
    return tags;
}

fn ensureFetchedRemoteTagTarballProto(
    allocator: std.mem.Allocator,
    root: []const u8,
    package_name: []const u8,
    tag: RemoteTag,
    session: git_proto.Session,
    stats: *types.SyncStats,
) !void {
    const pkg_dir = try std.fs.path.join(allocator, &.{ root, "p", package_name, "tag" });
    defer allocator.free(pkg_dir);
    try shell.runCommand(allocator, &[_][]const u8{ "mkdir", "-p", pkg_dir });

    const tarball_path = try tarballPathFor(allocator, root, package_name, tag.name);
    defer allocator.free(tarball_path);
    if (pathExists(tarball_path)) {
        stats.tarballs_present += 1;
        std.log.info("tarball present package={s} tag={s}", .{ package_name, tag.name });
        return;
    }

    const tmp_root = try std.fmt.allocPrint(allocator, "/tmp/packbase-fetch-{d}", .{std.time.nanoTimestamp()});
    defer allocator.free(tmp_root);
    defer std.fs.deleteTreeAbsolute(tmp_root) catch {};

    const repo_path = try std.fs.path.join(allocator, &.{ tmp_root, "repo" });
    defer allocator.free(repo_path);
    try shell.runCommand(allocator, &.{ "git", "init", "--quiet", repo_path });

    const response_buffer = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(response_buffer);
    const want = try std.fmt.allocPrint(allocator, "{x}", .{tag.target.slice()});
    defer allocator.free(want);

    var fetch_stream: git_proto.Session.FetchStream = undefined;
    try session.fetch(&fetch_stream, &.{want}, response_buffer);
    defer fetch_stream.deinit();

    const pack_bytes = try fetch_stream.reader.allocRemaining(allocator, .limited(512 * 1024 * 1024));
    defer allocator.free(pack_bytes);

    const pack_dir = try std.fs.path.join(allocator, &.{ repo_path, ".git", "objects", "pack" });
    defer allocator.free(pack_dir);
    try shell.runCommand(allocator, &.{ "mkdir", "-p", pack_dir });
    const pack_path = try std.fs.path.join(allocator, &.{ pack_dir, "packbase.pack" });
    defer allocator.free(pack_path);
    {
        var pack_file = try std.fs.cwd().createFile(pack_path, .{ .truncate = true });
        defer pack_file.close();
        try pack_file.writeAll(pack_bytes);
    }

    const commit = try std.fmt.allocPrint(allocator, "{x}", .{tag.target.slice()});
    defer allocator.free(commit);
    try shell.runCommand(allocator, &.{ "git", "-C", repo_path, "index-pack", ".git/objects/pack/packbase.pack" });
    try shell.runCommand(allocator, &.{ "git", "-C", repo_path, "checkout", "--quiet", "--detach", commit });
    std.fs.deleteTreeAbsolute(try std.fs.path.join(allocator, &.{ repo_path, ".git" })) catch {};

    try shell.runCommand(allocator, &.{
        "tar",
        "--sort=name",
        "--mtime=@0",
        "--owner=0",
        "--group=0",
        "--numeric-owner",
        "-czf",
        tarball_path,
        "-C",
        repo_path,
        ".",
    });

    stats.tarballs_created += 1;
    std.log.info("tarball created package={s} tag={s}", .{ package_name, tag.name });
}

fn freeRemoteTagList(allocator: std.mem.Allocator, tags: *std.ArrayList(RemoteTag)) void {
    for (tags.items) |tag| allocator.free(tag.name);
    tags.deinit(allocator);
}

fn sortRemoteTagAsc(_: void, a: RemoteTag, b: RemoteTag) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn tarballPathFor(allocator: std.mem.Allocator, root: []const u8, package_name: []const u8, tag: []const u8) ![]u8 {
    const tarball_name = try std.fmt.allocPrint(allocator, "{s}.tar.gz", .{tag});
    defer allocator.free(tarball_name);
    return std.fs.path.join(allocator, &.{ root, "p", package_name, "tag", tarball_name });
}

fn isHttpGitUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://");
}

fn archiveGitTag(allocator: std.mem.Allocator, repo_path: []const u8, tag: []const u8, tarball_path: []const u8) !void {
    var file = try std.fs.cwd().createFile(tarball_path, .{ .truncate = true });
    defer file.close();

    var child = std.process.Child.init(&[_][]const u8{
        "git", "-C", repo_path, "archive", "--format=tar.gz", tag,
    }, allocator);
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try child.stdout.?.read(&buf);
        if (n == 0) break;
        try file.writeAll(buf[0..n]);
    }

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn ensureBuiltInHelloSeed(allocator: std.mem.Allocator, root: []const u8) !bool {
    const hello_repo = try std.fs.path.join(allocator, &.{ root, "git", "hello.git", "HEAD" });
    defer allocator.free(hello_repo);
    if (std.fs.cwd().access(hello_repo, .{})) |_| return false else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const tmp_root = try std.fmt.allocPrint(allocator, "/tmp/packbase-seed-{d}", .{std.time.nanoTimestamp()});
    defer allocator.free(tmp_root);
    defer std.fs.deleteTreeAbsolute(tmp_root) catch {};

    const source_root = try std.fs.path.join(allocator, &.{ tmp_root, "hello" });
    defer allocator.free(source_root);
    const source_src = try std.fs.path.join(allocator, &.{ source_root, "src" });
    defer allocator.free(source_src);
    try shell.runCommand(allocator, &[_][]const u8{ "mkdir", "-p", source_src });

    try writeSeedFiles(allocator, source_root, source_src);

    const bare_repo = try std.fs.path.join(allocator, &.{ root, "git", "hello.git" });
    defer allocator.free(bare_repo);
    const git_root = try std.fs.path.join(allocator, &.{ root, "git" });
    defer allocator.free(git_root);
    try shell.runCommand(allocator, &[_][]const u8{ "mkdir", "-p", git_root });
    try shell.runCommand(allocator, &[_][]const u8{ "git", "init", "--bare", bare_repo });
    try shell.runCommand(allocator, &[_][]const u8{ "git", "init", source_root });
    try shell.runCommand(allocator, &[_][]const u8{ "git", "-C", source_root, "config", "user.name", "Packbase Seed" });
    try shell.runCommand(allocator, &[_][]const u8{ "git", "-C", source_root, "config", "user.email", "seed@packbase.local" });
    try shell.runCommand(allocator, &[_][]const u8{ "git", "-C", source_root, "add", "." });
    try shell.runCommand(allocator, &[_][]const u8{ "git", "-C", source_root, "commit", "-m", "Initial seed" });
    try shell.runCommand(allocator, &[_][]const u8{ "git", "-C", source_root, "branch", "-M", "main" });
    try shell.runCommand(allocator, &[_][]const u8{ "git", "-C", source_root, "tag", "v0.1.0" });
    try shell.runCommand(allocator, &[_][]const u8{ "git", "-C", source_root, "remote", "add", "origin", bare_repo });
    try shell.runCommand(allocator, &[_][]const u8{ "git", "-C", source_root, "push", "origin", "main" });
    try shell.runCommand(allocator, &[_][]const u8{ "git", "-C", source_root, "push", "origin", "v0.1.0" });
    try shell.runCommand(allocator, &[_][]const u8{ "git", "-C", bare_repo, "symbolic-ref", "HEAD", "refs/heads/main" });
    try shell.runCommand(allocator, &[_][]const u8{ "git", "-C", bare_repo, "update-server-info" });
    return true;
}

fn writeSeedFiles(allocator: std.mem.Allocator, source_root: []const u8, source_src: []const u8) !void {
    const build_zig = try std.fs.path.join(allocator, &.{ source_root, "build.zig" });
    defer allocator.free(build_zig);
    try writeTextFile(build_zig,
        \\const std = @import("std");
        \\pub fn build(_: *std.Build) void {}
        \\
    );

    const build_zon = try std.fs.path.join(allocator, &.{ source_root, "build.zig.zon" });
    defer allocator.free(build_zon);
    try writeTextFile(build_zon,
        \\.{
        \\    .name = .hello_fixture,
        \\    .version = "0.1.0",
        \\    .paths = .{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "README.md",
        \\        "src",
        \\    },
        \\}
        \\
    );

    const readme = try std.fs.path.join(allocator, &.{ source_root, "README.md" });
    defer allocator.free(readme);
    try writeTextFile(readme,
        \\# hello fixture
        \\
        \\Built-in seed package for packbase deployments.
        \\
    );

    const root_zig = try std.fs.path.join(allocator, &.{ source_src, "root.zig" });
    defer allocator.free(root_zig);
    try writeTextFile(root_zig,
        \\pub fn message() []const u8 {
        \\    return "hello";
        \\}
        \\
    );
}

fn writeTextFile(path: []const u8, content: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

fn extractSourceRecords(allocator: std.mem.Allocator, raw: []const u8) !std.ArrayList(types.SourceRecord) {
    const parsed = try std.json.parseFromSlice(types.SourceSnapshot, allocator, raw, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var records = std.ArrayList(types.SourceRecord).empty;
    errdefer freeSourceRecords(allocator, &records);

    for (parsed.value.packages) |pkg| {
        const repo_url = if (pkg.repository) |repo|
            try allocator.dupe(u8, repo.url)
        else
            try allocator.dupe(u8, "");

        const package_name = if (pkg.title) |title|
            try allocator.dupe(u8, title)
        else if (pkg.github) |github|
            try allocator.dupe(u8, github.name)
        else
            try derivePackageName(allocator, repo_url, pkg.id);

        try records.append(allocator, .{
            .id = try allocator.dupe(u8, pkg.id),
            .repo_url = repo_url,
            .package_name = package_name,
            .default_ref = if (pkg.repository) |repo|
                try allocator.dupe(u8, repo.default_ref orelse "")
            else
                try allocator.dupe(u8, ""),
            .updated_at = try allocator.dupe(u8, pkg.updated_at orelse ""),
        });
    }

    std.mem.sort(types.SourceRecord, records.items, {}, sortSourceRecordById);
    return records;
}

fn freeSourceRecords(allocator: std.mem.Allocator, records: *std.ArrayList(types.SourceRecord)) void {
    for (records.items) |record| {
        allocator.free(record.id);
        allocator.free(record.repo_url);
        allocator.free(record.package_name);
        allocator.free(record.default_ref);
        allocator.free(record.updated_at);
    }
    records.deinit(allocator);
}

fn sortSourceRecordById(_: void, a: types.SourceRecord, b: types.SourceRecord) bool {
    return std.mem.lessThan(u8, a.id, b.id);
}

fn derivePackageName(allocator: std.mem.Allocator, repo_url: []const u8, fallback: []const u8) ![]u8 {
    if (repo_url.len == 0) return allocator.dupe(u8, fallback);
    const slash_pos = std.mem.lastIndexOfScalar(u8, repo_url, '/') orelse return allocator.dupe(u8, fallback);
    const raw_name = repo_url[slash_pos + 1 ..];
    const name = if (std.mem.endsWith(u8, raw_name, ".git")) raw_name[0 .. raw_name.len - 4] else raw_name;
    if (name.len == 0) return allocator.dupe(u8, fallback);
    return allocator.dupe(u8, name);
}

fn computeSourceDiff(old_items: []const types.SourceRecord, new_items: []const types.SourceRecord, stats: *types.SyncStats) void {
    var i: usize = 0;
    var j: usize = 0;
    while (i < old_items.len and j < new_items.len) {
        switch (std.mem.order(u8, old_items[i].id, new_items[j].id)) {
            .lt => {
                stats.source_removed += 1;
                i += 1;
            },
            .gt => {
                stats.source_added += 1;
                j += 1;
            },
            .eq => {
                if (!std.mem.eql(u8, old_items[i].repo_url, new_items[j].repo_url) or
                    !std.mem.eql(u8, old_items[i].package_name, new_items[j].package_name) or
                    !std.mem.eql(u8, old_items[i].default_ref, new_items[j].default_ref))
                {
                    stats.source_changed_count += 1;
                }
                i += 1;
                j += 1;
            },
        }
    }
    stats.source_removed += old_items.len - i;
    stats.source_added += new_items.len - j;
}

fn writeRegisteredSnapshot(allocator: std.mem.Allocator, path: []const u8, records: []const types.SourceRecord) !void {
    var names = std.ArrayList([]u8).empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    for (records) |record| try names.append(allocator, try allocator.dupe(u8, record.package_name));
    std.mem.sort([]u8, names.items, {}, sortStringAsc);

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, "{\"packages\":[");
    var first = true;
    var prev: ?[]u8 = null;
    for (names.items) |name| {
        if (prev) |last| if (std.mem.eql(u8, last, name)) continue;
        if (!first) try body.append(allocator, ',');
        first = false;
        try appendJsonString(allocator, &body, name);
        prev = name;
    }
    try body.appendSlice(allocator, "]}\n");
    try writeTextFile(path, body.items);
}

fn writeSourceDiffSnapshot(allocator: std.mem.Allocator, path: []const u8, stats: *const types.SyncStats) !void {
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"source_changed\":{s},\"source_packages\":{d},\"source_added\":{d},\"source_updated\":{d},\"source_removed\":{d},\"source_skipped\":{d},\"source_repo_cloned\":{d},\"source_repo_updated\":{d},\"source_repo_failed\":{d}}}\n",
        .{
            if (stats.source_changed) "true" else "false",
            stats.source_packages,
            stats.source_added,
            stats.source_changed_count,
            stats.source_removed,
            stats.source_skipped,
            stats.source_repo_cloned,
            stats.source_repo_updated,
            stats.source_repo_failed,
        },
    );
    defer allocator.free(body);
    try writeTextFile(path, body);
}

fn collectLocalPackageNames(allocator: std.mem.Allocator, root: []const u8) !std.ArrayList([]u8) {
    const packages_root = try std.fs.path.join(allocator, &.{ root, "p" });
    defer allocator.free(packages_root);

    var entries = std.ArrayList([]u8).empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry);
        entries.deinit(allocator);
    }

    var dir = std.fs.cwd().openDir(packages_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return entries,
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        try entries.append(allocator, try allocator.dupe(u8, entry.name));
    }
    return entries;
}

fn collectTarballTags(allocator: std.mem.Allocator, tarball_dir: []const u8) !std.ArrayList([]u8) {
    var tags = std.ArrayList([]u8).empty;
    errdefer {
        for (tags.items) |tag| allocator.free(tag);
        tags.deinit(allocator);
    }

    var dir = std.fs.cwd().openDir(tarball_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return tags,
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".tar.gz")) continue;
        try tags.append(allocator, try allocator.dupe(u8, entry.name[0 .. entry.name.len - 7]));
    }
    return tags;
}

fn collectTarballInfos(allocator: std.mem.Allocator, tarball_dir: []const u8) !std.ArrayList(types.PackageTagInfo) {
    var tags = std.ArrayList(types.PackageTagInfo).empty;
    errdefer {
        for (tags.items) |tag_info| allocator.free(tag_info.tag);
        tags.deinit(allocator);
    }

    var dir = std.fs.cwd().openDir(tarball_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return tags,
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".tar.gz")) continue;
        const stat = try dir.statFile(entry.name);
        try tags.append(allocator, .{
            .tag = try allocator.dupe(u8, entry.name[0 .. entry.name.len - ".tar.gz".len]),
            .size_bytes = @intCast(stat.size),
        });
    }
    return tags;
}

fn containsName(names: []const []u8, needle: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, needle)) return true;
    }
    return false;
}

fn accessExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn collectRegisteredPackageNames(allocator: std.mem.Allocator, root: []const u8) !std.ArrayList([]u8) {
    var names = std.ArrayList([]u8).empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    const state_dir = try ensureStateDir(allocator, root);
    defer allocator.free(state_dir);
    const registered_path = try std.fs.path.join(allocator, &.{ state_dir, "registered.json" });
    defer allocator.free(registered_path);

    const raw = try readOptionalFileAlloc(allocator, registered_path, 4 * 1024 * 1024) orelse return names;
    defer allocator.free(raw);

    const parsed = try std.json.parseFromSlice(struct { packages: []const []const u8 }, allocator, raw, .{});
    defer parsed.deinit();
    for (parsed.value.packages) |name| try names.append(allocator, try allocator.dupe(u8, name));
    return names;
}

fn appendMergedNames(
    allocator: std.mem.Allocator,
    merged: *std.ArrayList([]u8),
    left: []const []u8,
    right: []const []u8,
) !void {
    var i: usize = 0;
    var j: usize = 0;
    while (i < left.len or j < right.len) {
        if (i >= left.len) {
            try merged.append(allocator, right[j]);
            j += 1;
            continue;
        }
        if (j >= right.len) {
            try merged.append(allocator, left[i]);
            i += 1;
            continue;
        }
        switch (std.mem.order(u8, left[i], right[j])) {
            .lt => {
                try merged.append(allocator, left[i]);
                i += 1;
            },
            .gt => {
                try merged.append(allocator, right[j]);
                j += 1;
            },
            .eq => {
                try merged.append(allocator, left[i]);
                i += 1;
                j += 1;
            },
        }
    }
}

fn sortStringAsc(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn sortPackageTagInfoAsc(_: void, a: types.PackageTagInfo, b: types.PackageTagInfo) bool {
    return std.mem.lessThan(u8, a.tag, b.tag);
}

fn sortPackageInfoAsc(_: void, a: types.PackageInfo, b: types.PackageInfo) bool {
    return std.mem.lessThan(u8, a.package, b.package);
}

fn appendJsonString(allocator: std.mem.Allocator, body: *std.ArrayList(u8), value: []const u8) !void {
    try body.append(allocator, '"');
    for (value) |ch| switch (ch) {
        '"' => try body.appendSlice(allocator, "\\\""),
        '\\' => try body.appendSlice(allocator, "\\\\"),
        '\n' => try body.appendSlice(allocator, "\\n"),
        '\r' => try body.appendSlice(allocator, "\\r"),
        '\t' => try body.appendSlice(allocator, "\\t"),
        else => try body.append(allocator, ch),
    };
    try body.append(allocator, '"');
}

fn appendPackageInfoJson(allocator: std.mem.Allocator, body: *std.ArrayList(u8), info: types.PackageInfo) !void {
    try body.appendSlice(allocator, "{\"package\":");
    try appendJsonString(allocator, body, info.package);
    try body.appendSlice(allocator, ",\"available\":");
    try body.appendSlice(allocator, if (info.available) "true" else "false");
    try body.appendSlice(allocator, ",\"registered\":");
    try body.appendSlice(allocator, if (info.registered) "true" else "false");
    try body.appendSlice(allocator, ",\"local\":");
    try body.appendSlice(allocator, if (info.local) "true" else "false");
    try body.appendSlice(allocator, ",\"tarball_dir_present\":");
    try body.appendSlice(allocator, if (info.tarball_dir_present) "true" else "false");
    try body.writer(allocator).print(",\"tarball_count\":{d}", .{info.tarball_count});
    try body.appendSlice(allocator, ",\"latest_tag\":");
    if (info.latest_tag) |tag| {
        try appendJsonString(allocator, body, tag);
    } else {
        try body.appendSlice(allocator, "null");
    }
    try body.writer(allocator).print(",\"latest_size_bytes\":{d}", .{info.latest_size_bytes});
    try body.writer(allocator).print(",\"size_bytes\":{d}", .{info.size_bytes});
    try body.appendSlice(allocator, ",\"tarballs\":[");
    for (info.tarballs, 0..) |tag_info, index| {
        if (index != 0) try body.append(allocator, ',');
        try body.appendSlice(allocator, "{\"tag\":");
        try appendJsonString(allocator, body, tag_info.tag);
        try body.writer(allocator).print(",\"size_bytes\":{d}}}", .{tag_info.size_bytes});
    }
    try body.appendSlice(allocator, "],\"smart_http_ready\":");
    try body.appendSlice(allocator, if (info.smart_http_ready) "true" else "false");
    try body.appendSlice(allocator, ",\"pseudo_git_fetchable\":");
    try body.appendSlice(allocator, if (info.pseudo_git_fetchable) "true" else "false");
    try body.appendSlice(allocator, ",\"fetch_probe_commit\":");
    if (info.fetch_probe_commit) |commit| {
        try appendJsonString(allocator, body, commit);
    } else {
        try body.appendSlice(allocator, "null");
    }
    try body.appendSlice(allocator, ",\"fetch_probe_error\":");
    if (info.fetch_probe_error) |probe_error| {
        try appendJsonString(allocator, body, probe_error);
    } else {
        try body.appendSlice(allocator, "null");
    }
    try body.appendSlice(allocator, ",\"healthy\":");
    try body.appendSlice(allocator, if (info.healthy) "true" else "false");
    try body.writer(allocator).print(",\"updated_at\":{d}}}", .{info.updated_at});
}

const SourceRepoAction = enum {
    cloned,
    updated,
    skipped,
};

fn ensureSourceRepo(
    allocator: std.mem.Allocator,
    root: []const u8,
    record: types.SourceRecord,
    refresh_existing: bool,
    stats: *types.SyncStats,
) !SourceRepoAction {
    const git_root = try std.fs.path.join(allocator, &.{ root, "git" });
    defer allocator.free(git_root);
    try shell.runCommand(allocator, &[_][]const u8{ "mkdir", "-p", git_root });

    const repo_dir_name = try std.fmt.allocPrint(allocator, "{s}.git", .{record.package_name});
    defer allocator.free(repo_dir_name);
    const bare_repo = try std.fs.path.join(allocator, &.{ git_root, repo_dir_name });
    defer allocator.free(bare_repo);

    const head_path = try std.fs.path.join(allocator, &.{ bare_repo, "HEAD" });
    defer allocator.free(head_path);

    if (!pathExists(head_path)) {
        try shell.runCommand(allocator, &[_][]const u8{
            "git", "-c", "protocol.file.allow=always", "-c", "safe.directory=*",
            "clone", "--mirror", "--quiet", record.repo_url, bare_repo,
        });
        stats.source_repo_cloned += 1;
        if (record.default_ref.len != 0) {
            const head_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{record.default_ref});
            defer allocator.free(head_ref);
            shell.runCommand(allocator, &[_][]const u8{ "git", "-C", bare_repo, "symbolic-ref", "HEAD", head_ref }) catch {};
        }
        shell.runCommand(allocator, &[_][]const u8{ "git", "-C", bare_repo, "update-server-info" }) catch {};
        return .cloned;
    } else if (refresh_existing) {
        shell.runCommand(allocator, &[_][]const u8{ "git", "-C", bare_repo, "remote", "set-url", "origin", record.repo_url }) catch {};
        try shell.runCommand(allocator, &[_][]const u8{
            "git", "-c", "protocol.file.allow=always", "-c", "safe.directory=*",
            "-C", bare_repo, "fetch", "--prune", "--tags", "origin",
            "+refs/heads/*:refs/heads/*",
            "+refs/tags/*:refs/tags/*",
        });
        stats.source_repo_updated += 1;
        if (record.default_ref.len != 0) {
            const head_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{record.default_ref});
            defer allocator.free(head_ref);
            shell.runCommand(allocator, &[_][]const u8{ "git", "-C", bare_repo, "symbolic-ref", "HEAD", head_ref }) catch {};
        }
        shell.runCommand(allocator, &[_][]const u8{ "git", "-C", bare_repo, "update-server-info" }) catch {};
        return .updated;
    } else {
        return .skipped;
    }
}

fn injectRepoSyncStats(allocator: std.mem.Allocator, base_body: []const u8, stats: *const types.SyncStats) ![]u8 {
    const trimmed = std.mem.trimRight(u8, base_body, "\r\n");
    if (trimmed.len == 0 or trimmed[trimmed.len - 1] != '}') return allocator.dupe(u8, base_body);

    const suffix = try std.fmt.allocPrint(
        allocator,
        ",\"source_repo_cloned\":{d},\"source_repo_updated\":{d},\"source_repo_failed\":{d},\"source_skipped\":{d},\"packages_total\":{d},\"packages_probed\":{d}}}\n",
        .{ stats.source_repo_cloned, stats.source_repo_updated, stats.source_repo_failed, stats.source_skipped, stats.packages_total, stats.packages_probed },
    );
    defer allocator.free(suffix);

    return std.mem.concat(allocator, u8, &.{ trimmed[0 .. trimmed.len - 1], suffix });
}

fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}
