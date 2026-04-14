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
INFO_URL="${SCHEME}://${DOMAIN}/api/info"
LIST_URL="${SCHEME}://${DOMAIN}/api/list"
UPDATE_URL="${SCHEME}://${DOMAIN}/api/update"

if [ -z "$DOMAIN" ]; then
    printf 'usage: %s <domain> [repo] [expected-release]\n' "${BASH_SOURCE[0]}" >&2
    printf 'or set PACKBASE_REMOTE_DOMAIN, PACKBASE_REMOTE_REPO, PACKBASE_EXPECTED_RELEASE\n' >&2
    exit 64
fi

rm -rf "$TARGET_DIR"
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
printf 'tested clone url: %s\n' "$REMOTE_URL"
printf 'example VCS URL shape: git+https://%s/%s\n' "$DOMAIN" "$REPO_NAME"
