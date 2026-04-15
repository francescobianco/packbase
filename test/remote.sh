#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$ROOT_DIR/test/tmp"
DOMAIN="${1:-${PACKBASE_REMOTE_DOMAIN:-pb.yafb.net}}"
REPO_NAME="${2:-${PACKBASE_REMOTE_REPO:-hello}}"
EXPECTED_RELEASE="${3:-${PACKBASE_EXPECTED_RELEASE:-}}"
SCHEME="${PACKBASE_REMOTE_SCHEME:-https}"
REMOTE_URL="${SCHEME}://${DOMAIN}/${REPO_NAME}"
TARGET_DIR="$TMP_DIR/remote-clone"
FETCH_DIR="$TMP_DIR/remote-fetch"
FETCH_REPEAT_DIR="$TMP_DIR/remote-fetch-repeat"
INFO_URL="${SCHEME}://${DOMAIN}/api/info"
LIST_URL="${SCHEME}://${DOMAIN}/api/list"
UPDATE_URL="${SCHEME}://${DOMAIN}/api/update"

if [ -z "$DOMAIN" ]; then
    printf 'usage: %s <domain> [repo] [expected-release]\n' "${BASH_SOURCE[0]}" >&2
    printf 'or set PACKBASE_REMOTE_DOMAIN, PACKBASE_REMOTE_REPO, PACKBASE_EXPECTED_RELEASE\n' >&2
    exit 64
fi

rm -rf "$TARGET_DIR" "$FETCH_DIR" "$FETCH_REPEAT_DIR"
mkdir -p "$TMP_DIR"

if ! RELEASE_RESP="$(curl -fsS "$INFO_URL")"; then
    printf 'remote info endpoint not available: %s\n' "$INFO_URL" >&2
    printf 'expected a deployed packbase instance exposing /api/info\n' >&2
    exit 1
fi

REMOTE_RELEASE="$(printf '%s' "$RELEASE_RESP" | sed 's/.*"release":"\([^"]*\)".*/\1/')"

if [ -z "$REMOTE_RELEASE" ]; then
    printf 'could not parse release identifier from %s\n' "$INFO_URL" >&2
    printf 'raw response: %s\n' "$RELEASE_RESP" >&2
    exit 1
fi

printf 'remote release: %s\n' "$REMOTE_RELEASE"

if [ -n "$EXPECTED_RELEASE" ] && [ "$REMOTE_RELEASE" != "$EXPECTED_RELEASE" ]; then
    printf 'release mismatch: expected %s but remote serves %s\n' "$EXPECTED_RELEASE" "$REMOTE_RELEASE" >&2
    exit 1
fi

if ! LIST_RESP="$(curl -fsS "$LIST_URL")"; then
    printf 'remote list endpoint not available: %s\n' "$LIST_URL" >&2
    printf 'expected a deployed packbase instance exposing /api/list\n' >&2
    exit 1
fi

if ! printf '%s' "$LIST_RESP" | grep -q "\"${REPO_NAME}\""; then
    printf 'package %s missing from list, trying soft sync via /api/update\n' "$REPO_NAME"
    UPDATE_RESP="$(curl -fsS -X POST "$UPDATE_URL")"
    printf 'api/update response: %s\n' "$UPDATE_RESP"

    RETRY_AFTER="$(printf '%s' "$UPDATE_RESP" | sed -n 's/.*"retry_after":\([0-9][0-9]*\).*/\1/p')"
    if [ -n "$RETRY_AFTER" ] && [ "$RETRY_AFTER" -gt 0 ]; then
        sleep "$RETRY_AFTER"
    fi

    LIST_RESP="$(curl -fsS "$LIST_URL")"
fi

if ! printf '%s' "$LIST_RESP" | grep -q "\"${REPO_NAME}\""; then
    printf 'package %s not listed by %s\n' "$REPO_NAME" "$LIST_URL" >&2
    printf 'raw response: %s\n' "$LIST_RESP" >&2
    exit 1
fi

printf 'remote package list contains %s\n' "$REPO_NAME"

if ! curl -fsS "${REMOTE_URL}/info/refs" >/dev/null; then
    printf 'remote repository endpoint not available: %s/info/refs\n' "$REMOTE_URL" >&2
    printf 'expected a deployed packbase instance exposing root-level clone paths\n' >&2
    exit 1
fi

git clone "$REMOTE_URL" "$TARGET_DIR" >/dev/null 2>&1

test -f "$TARGET_DIR/build.zig.zon"
grep -q 'hello_fixture' "$TARGET_DIR/build.zig.zon"

printf 'remote git clone without /git prefix: OK\n'

mkdir -p "$FETCH_DIR/src" "$FETCH_REPEAT_DIR"

cat > "$FETCH_DIR/build.zig.zon" <<'ZON'
.{
    .name = .remote_smoke,
    .version = "0.0.0",
    .dependencies = .{},
    .paths = .{""},
}
ZON

(cd "$FETCH_DIR" && zig fetch --save "git+${REMOTE_URL}" --global-cache-dir .zig-cache)

grep -q '\.hash' "$FETCH_DIR/build.zig.zon"

DEP_NAME="$(sed -n '
    /[.]dependencies = [.]\\{/,/^[[:space:]]*[}],[[:space:]]*$/{
        s/^[[:space:]]*[.]@"\([^"]*\)".*/\1/p
        s/^[[:space:]]*[.]\([A-Za-z0-9_][A-Za-z0-9_]*\)[[:space:]]*=.*/\1/p
    }
' "$FETCH_DIR/build.zig.zon" | head -n1)"

if [ -z "$DEP_NAME" ]; then
    printf 'could not parse dependency name from %s\n' "$FETCH_DIR/build.zig.zon" >&2
    cat "$FETCH_DIR/build.zig.zon" >&2
    exit 1
fi

cat > "$FETCH_DIR/build.zig" <<ZIG
const std = @import("std");

pub fn build(b: *std.Build) void {
    const dep = b.dependency("${DEP_NAME}", .{});
    const module = dep.module("${DEP_NAME}");
    const exe = b.addExecutable(.{
        .name = "remote-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
        }),
    });
    exe.root_module.addImport("depmod", module);
    b.installArtifact(exe);
}
ZIG

cat > "$FETCH_DIR/src/main.zig" <<'ZIG'
const depmod = @import("depmod");

comptime {
    _ = depmod;
}

pub fn main() void {}
ZIG

(cd "$FETCH_DIR" && zig build --global-cache-dir .zig-cache --prefix zig-out)

printf 'remote zig fetch via short git URL: OK\n'
printf 'remote zig build dependency resolution: OK\n'

cat > "$FETCH_REPEAT_DIR/build.zig.zon" <<'ZON'
.{
    .name = .remote_smoke_repeat,
    .version = "0.0.0",
    .dependencies = .{},
    .paths = .{""},
}
ZON

(cd "$FETCH_REPEAT_DIR" && zig fetch --save "git+${REMOTE_URL}" --global-cache-dir .zig-cache)

POST_FETCH_INFO="$(curl -fsS "$INFO_URL")"
POST_FETCH_RELEASE="$(printf '%s' "$POST_FETCH_INFO" | sed 's/.*"release":"\([^"]*\)".*/\1/')"

if [ "$POST_FETCH_RELEASE" != "$REMOTE_RELEASE" ]; then
    printf 'release changed or server unhealthy after repeated zig fetch: before=%s after=%s\n' "$REMOTE_RELEASE" "$POST_FETCH_RELEASE" >&2
    exit 1
fi

printf 'remote repeated zig fetch and post-fetch liveness: OK\n'
printf 'tested clone url: %s\n' "$REMOTE_URL"
printf 'example VCS URL shape: git+https://%s/%s\n' "$DOMAIN" "$REPO_NAME"
