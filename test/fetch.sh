#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$ROOT_DIR/test/tmp"
DOMAIN="${1:-${PACKBASE_REMOTE_DOMAIN:-pb.yafb.net}}"
REPO_URL="${2:-${PACKBASE_FETCH_REPO_URL:-git+https://github.com/OrlovEvgeny/serde.zig}}"
PACKAGE_NAME="${3:-${PACKBASE_FETCH_PACKAGE:-serde.zig}}"
SCHEME="${PACKBASE_REMOTE_SCHEME:-https}"
TOKEN="${PACKBASE_FETCH_TOKEN:-${PACKBASE_TOKEN:-}}"

STATUS_URL="${SCHEME}://${DOMAIN}/api/status"
FETCH_URL="${SCHEME}://${DOMAIN}/api/fetch"
CHECK_URL="${SCHEME}://${DOMAIN}/api/check/${PACKAGE_NAME}"
LIST_URL="${SCHEME}://${DOMAIN}/api/list"

mkdir -p "$TMP_DIR"

AUTH_ARGS=()
if [ -n "$TOKEN" ]; then
    AUTH_ARGS=(-H "Authorization: Bearer ${TOKEN}")
fi

printf 'target status: %s\n' "$STATUS_URL"
STATUS_RESP="$(curl -fsS "$STATUS_URL")"
printf 'status before fetch: %s\n' "$STATUS_RESP"

FETCH_RESP="$(
    curl -fsS \
        -X POST \
        -H 'Content-Type: application/json' \
        "${AUTH_ARGS[@]}" \
        -d "{\"url\":\"${REPO_URL}\"}" \
        "$FETCH_URL"
)"

printf 'fetch response: %s\n' "$FETCH_RESP"

FETCH_JSON="$FETCH_RESP" python3 - <<'PY'
import json
import os
import sys

data = json.loads(os.environ["FETCH_JSON"])
created = int(data.get("tarballs_created", 0))
present = int(data.get("tarballs_present", 0))
total = int(data.get("tarball_count", 0))
if data.get("status") != "ok":
    raise SystemExit("fetch did not return status=ok")
if total <= 0:
    raise SystemExit("tarball_count must be > 0")
if created + present != total:
    raise SystemExit(f"inconsistent counts: created={created} present={present} total={total}")
print(f"fetch counters OK: created={created} present={present} total={total}")
PY

CHECK_RESP="$(curl -fsS "$CHECK_URL")"
printf 'package check: %s\n' "$CHECK_RESP"

CHECK_JSON="$CHECK_RESP" PACKAGE_NAME="$PACKAGE_NAME" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["CHECK_JSON"])
pkg = os.environ["PACKAGE_NAME"]
if data.get("package") != pkg:
    raise SystemExit(f"unexpected package name: {data.get('package')!r}")
if int(data.get("tarball_count", 0)) <= 0:
    raise SystemExit("tarball_count must be > 0 after fetch")
if not data.get("latest_tag"):
    raise SystemExit("latest_tag missing after fetch")
print(
    "package snapshot OK:",
    f"healthy={data.get('healthy')}",
    f"tarball_count={data.get('tarball_count')}",
    f"latest_tag={data.get('latest_tag')}",
)
PY

LIST_RESP="$(curl -fsS "$LIST_URL")"
printf '%s' "$LIST_RESP" | grep -q "\"${PACKAGE_NAME}\""

STATUS_AFTER="$(curl -fsS "$STATUS_URL")"
printf 'status after fetch: %s\n' "$STATUS_AFTER"
printf 'remote fetch smoke: OK (%s)\n' "$PACKAGE_NAME"
