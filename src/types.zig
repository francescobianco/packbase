const std = @import("std");

pub const Request = struct {
    method: []const u8,
    target: []const u8,
};

pub const FetchPayload = struct {
    url: []const u8,
};

pub const SourceSnapshot = struct {
    protocol: ?[]const u8 = null,
    packages: []SourcePackage = &.{},
};

pub const SourcePackage = struct {
    id: []const u8,
    title: ?[]const u8 = null,
    repository: ?SourceRepository = null,
    github: ?SourceGithub = null,
};

pub const SourceRepository = struct {
    url: []const u8,
    default_ref: ?[]const u8 = null,
};

pub const SourceGithub = struct {
    name: []const u8,
};

pub const SourceRecord = struct {
    id: []u8,
    repo_url: []u8,
    package_name: []u8,
    default_ref: []u8,
};

pub const SyncStats = struct {
    repos_scanned: usize = 0,
    packages_synced: usize = 0,
    tarballs_created: usize = 0,
    tarballs_present: usize = 0,
    default_seeded: bool = false,
    source_changed: bool = false,
    source_packages: usize = 0,
    source_added: usize = 0,
    source_changed_count: usize = 0,
    source_removed: usize = 0,
    source_repo_cloned: usize = 0,
    source_repo_updated: usize = 0,
    source_repo_failed: usize = 0,
    rate_limited: bool = false,
    retry_after: i64 = 0,
    queued: bool = false,
};
