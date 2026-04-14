#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$ROOT_DIR/test/tmp"
DOMAIN="${1:-${PACKBASE_REMOTE_DOMAIN:-pb.yafb.net}}"
REPO_NAME="${2:-${PACKBASE_REMOTE_REPO:-hello}}"
SCHEME="${PACKBASE_REMOTE_SCHEME:-https}"
REMOTE_URL="${SCHEME}://${DOMAIN}/${REPO_NAME}"
TARGET_DIR="$TMP_DIR/remote-clone"

if [ -z "$DOMAIN" ]; then
    printf 'usage: %s <domain> [repo]\n' "${BASH_SOURCE[0]}" >&2
    printf 'or set PACKBASE_REMOTE_DOMAIN and optionally PACKBASE_REMOTE_REPO\n' >&2
    exit 64
fi

rm -rf "$TARGET_DIR"
mkdir -p "$TMP_DIR"

if ! curl -fsS "${REMOTE_URL}/info/refs" >/dev/null; then
    printf 'remote repository endpoint not available: %s/info/refs\n' "$REMOTE_URL" >&2
    printf 'expected a deployed packbase instance exposing root-level clone paths\n' >&2
    exit 1
fi

git clone "$REMOTE_URL" "$TARGET_DIR" >/dev/null 2>&1

test -f "$TARGET_DIR/build.zig.zon"
grep -q 'hello_fixture' "$TARGET_DIR/build.zig.zon"

printf 'remote git clone without /git prefix: OK\n'
printf 'tested clone url: %s\n' "$REMOTE_URL"
printf 'example VCS URL shape: git+https://%s/%s\n' "$DOMAIN" "$REPO_NAME"
