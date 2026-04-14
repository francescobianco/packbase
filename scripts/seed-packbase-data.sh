#!/usr/bin/env sh
set -eu

data_root="${1:-/data}"
fixtures_dir="${2:-/fixtures}"
git_root="${data_root}/git"
hello_tarball="${data_root}/p/hello/tag/v0.1.0.tar.gz"

mkdir -p "$git_root"

if [ -f "$hello_tarball" ]; then
    exit 0
fi

has_fixture_dirs() {
    [ -d "$fixtures_dir" ] || return 1
    for entry in "$fixtures_dir"/*; do
        [ -d "$entry" ] && return 0
    done
    return 1
}

if has_fixture_dirs; then
    sh /seed/create-fixture-repos.sh "$git_root" "$fixtures_dir"
    exit 0
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT INT TERM

mkdir -p "$tmp_dir/hello/src"

cat > "$tmp_dir/hello/build.zig" <<'ZIG'
const std = @import("std");
pub fn build(_: *std.Build) void {}
ZIG

cat > "$tmp_dir/hello/build.zig.zon" <<'ZON'
.{
    .name = .hello_fixture,
    .version = "0.1.0",
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "README.md",
        "src",
    },
}
ZON

cat > "$tmp_dir/hello/README.md" <<'MD'
# hello fixture

Built-in seed package for packbase deployments.
MD

cat > "$tmp_dir/hello/src/root.zig" <<'ZIG'
pub fn message() []const u8 {
    return "hello";
}
ZIG

sh /seed/create-fixture-repos.sh "$git_root" "$tmp_dir"
