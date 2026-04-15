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
BATCH_FETCH_DIR="$TMP_DIR/remote-batch-fetch"
INFO_URL="${SCHEME}://${DOMAIN}/api/status"
LIST_URL="${SCHEME}://${DOMAIN}/api/list"
UPDATE_URL="${SCHEME}://${DOMAIN}/api/update"
PACKAGE_INFO_URL_BASE="${SCHEME}://${DOMAIN}/api/info"

if [ -z "$DOMAIN" ]; then
    printf 'usage: %s <domain> [repo] [expected-release]\n' "${BASH_SOURCE[0]}" >&2
    printf 'or set PACKBASE_REMOTE_DOMAIN, PACKBASE_REMOTE_REPO, PACKBASE_EXPECTED_RELEASE\n' >&2
    exit 64
fi

cleanup() {
    rm -rf "$TARGET_DIR"
}

trap cleanup EXIT

rm -rf "$TARGET_DIR"
mkdir -p "$TMP_DIR"

if ! RELEASE_RESP="$(curl -fsS "$INFO_URL")"; then
    printf 'remote status endpoint not available: %s\n' "$INFO_URL" >&2
    printf 'expected a deployed packbase instance exposing /api/status\n' >&2
    exit 1
fi

REMOTE_RELEASE="$(printf '%s' "$RELEASE_RESP" | tr -d '\n' | sed -n 's/.*"release":"\([^"]*\)".*/\1/p')"

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

UPDATE_RESP="$(curl -fsS -X POST "$UPDATE_URL")"
printf 'api/update response: %s\n' "$UPDATE_RESP"

for _ in $(seq 1 90); do
    UPDATE_STATE="$(curl -fsS "$INFO_URL" | sed -n 's/.*"state":"\([^"]*\)".*/\1/p')"
    if [ "$UPDATE_STATE" = "idle" ]; then
        break
    fi
    sleep 1
done

if [ "${UPDATE_STATE:-}" != "idle" ]; then
    printf 'api/update did not reach idle state\n' >&2
    exit 1
fi

PKG_INFO_RESP="$(curl -fsS "${PACKAGE_INFO_URL_BASE}/${REPO_NAME}")"
printf '%s' "$PKG_INFO_RESP" | grep -q '"healthy":true'
printf '%s' "$PKG_INFO_RESP" | grep -Eq '"tarball_count":[1-9][0-9]*'
printf '%s' "$PKG_INFO_RESP" | grep -Eq '"size_bytes":[1-9][0-9]*'

printf 'remote package info for %s: OK\n' "$REPO_NAME"

if ! curl -fsS "${REMOTE_URL}/info/refs" >/dev/null; then
    printf 'remote repository endpoint not available: %s/info/refs\n' "$REMOTE_URL" >&2
    printf 'expected a deployed packbase instance exposing root-level clone paths\n' >&2
    exit 1
fi

git clone "$REMOTE_URL" "$TARGET_DIR" >/dev/null 2>&1

test -f "$TARGET_DIR/build.zig.zon"
grep -q 'hello_fixture' "$TARGET_DIR/build.zig.zon"

printf 'remote git clone without /git prefix: OK\n'

rm -rf "$FETCH_DIR" "$FETCH_REPEAT_DIR"
mkdir -p "$FETCH_DIR" "$FETCH_REPEAT_DIR"

(cd "$FETCH_DIR" && zig init >/dev/null)

(cd "$FETCH_DIR" && zig fetch --save "git+${REMOTE_URL}" --global-cache-dir .zig-cache)

grep -q '\.hash' "$FETCH_DIR/build.zig.zon"

DEP_NAME="$(sed -n '
    /\.dependencies = \.{/,/^[[:space:]]*},[[:space:]]*$/{
        s/^[[:space:]]*[.]@"\([^"]*\)".*/\1/p
        s/^[[:space:]]*[.]\([A-Za-z0-9_][A-Za-z0-9_]*\)[[:space:]]*=.*/\1/p
    }
' "$FETCH_DIR/build.zig.zon" | grep -v '^dependencies$' | head -n1)"

if [ -z "$DEP_NAME" ]; then
    printf 'could not parse dependency name from %s\n' "$FETCH_DIR/build.zig.zon" >&2
    cat "$FETCH_DIR/build.zig.zon" >&2
    exit 1
fi

cat > "$FETCH_DIR/build.zig" <<ZIG
const std = @import("std");

pub fn build(b: *std.Build) void {
    const dep = b.dependency("${DEP_NAME}", .{});
    _ = dep;
    const exe = b.addExecutable(.{
        .name = "remote-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
        }),
    });
    b.installArtifact(exe);
}
ZIG

cat > "$FETCH_DIR/src/main.zig" <<'ZIG'
pub fn main() void {}
ZIG

(cd "$FETCH_DIR" && zig build --global-cache-dir .zig-cache --prefix zig-out)

printf 'remote zig fetch via short git URL: OK\n'
printf 'remote zig build dependency resolution: OK\n'

(cd "$FETCH_REPEAT_DIR" && zig init >/dev/null)

(cd "$FETCH_REPEAT_DIR" && zig fetch --save "git+${REMOTE_URL}" --global-cache-dir .zig-cache)

POST_FETCH_INFO="$(curl -fsS "$INFO_URL")"
POST_FETCH_RELEASE="$(printf '%s' "$POST_FETCH_INFO" | tr -d '\n' | sed -n 's/.*"release":"\([^"]*\)".*/\1/p')"

if [ "$POST_FETCH_RELEASE" != "$REMOTE_RELEASE" ]; then
    printf 'release changed or server unhealthy after repeated zig fetch: before=%s after=%s\n' "$REMOTE_RELEASE" "$POST_FETCH_RELEASE" >&2
    exit 1
fi

printf 'remote repeated zig fetch and post-fetch liveness: OK\n'

LIST_CANDIDATES="$(
LIST_JSON="$LIST_RESP" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["LIST_JSON"])
names = data.get("local_packages") or data.get("packages") or []
for name in names:
    print(name)
PY
)"

rm -rf "$BATCH_FETCH_DIR"
mkdir -p "$BATCH_FETCH_DIR"
(cd "$BATCH_FETCH_DIR" && zig init >/dev/null)

INSTALLED_COUNT=0
SELECTED_PACKAGES=""
PACKAGE_RANKING="$(
LIST_CANDIDATES="$LIST_CANDIDATES" PACKAGE_INFO_URL_BASE="$PACKAGE_INFO_URL_BASE" python3 - <<'PY'
import json
import os
import sys
import urllib.request

base = os.environ["PACKAGE_INFO_URL_BASE"]
candidates = [line.strip() for line in os.environ["LIST_CANDIDATES"].splitlines() if line.strip()]
ranked = []
for name in candidates:
    try:
        with urllib.request.urlopen(f"{base}/{name}") as response:
            info = json.load(response)
    except Exception:
        continue
    if not info.get("healthy"):
        continue
    if info.get("tarball_count", 0) <= 0:
        continue
    size = int(info.get("size_bytes") or 0)
    if size <= 0:
        continue
    ranked.append((size, name))

ranked.sort()
for size, name in ranked[:10]:
    print(f"{size}\t{name}")
PY
)"

while IFS=$'\t' read -r size_bytes pkg; do
    [ -n "${pkg:-}" ] || continue
    (cd "$BATCH_FETCH_DIR" && zig fetch --save "git+${SCHEME}://${DOMAIN}/${pkg}" --global-cache-dir .zig-cache)
    INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
    if [ -z "$SELECTED_PACKAGES" ]; then
        SELECTED_PACKAGES="${pkg} (${size_bytes} B)"
    else
        SELECTED_PACKAGES="$SELECTED_PACKAGES, ${pkg} (${size_bytes} B)"
    fi
    if [ "$INSTALLED_COUNT" -eq 10 ]; then
        break
    fi
done <<EOF
$PACKAGE_RANKING
EOF

if [ "$INSTALLED_COUNT" -ne 10 ]; then
    printf 'expected to install 10 packages, installed %s\n' "$INSTALLED_COUNT" >&2
    exit 1
fi

grep -q '\.dependencies = \.{' "$BATCH_FETCH_DIR/build.zig.zon"

printf 'remote batch install of 10 packages: OK\n'
printf 'selected packages: %s\n' "$SELECTED_PACKAGES"
printf 'tested clone url: %s\n' "$REMOTE_URL"
printf 'example VCS URL shape: git+https://%s/%s\n' "$DOMAIN" "$REPO_NAME"
