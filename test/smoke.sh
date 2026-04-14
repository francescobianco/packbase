#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_TAG="packbase-smoke:local"
ZIG_IMAGE="packbase-smoke-zig:local"
CONTAINER_NAME="packbase-smoke-$$"
NETWORK_NAME="packbase-smoke-net-$$"
HOST_PORT="${PACKBASE_TEST_PORT:-18080}"
API_TOKEN="${PACKBASE_TEST_TOKEN:-smoke-test-token}"
TMP_DIR="$ROOT_DIR/test/tmp"
EXPECTED_RELEASE="$(tr -d '\r\n' < "$ROOT_DIR/src/RELEASE_ID")"

# Wipe and recreate so each run starts clean but the directory survives after
# the test for inspection.
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

# Keep Zig version in sync with the one used to build the service.
ZIG_VERSION="$(grep -m1 'ARG ZIG_VERSION=' "$ROOT_DIR/Dockerfile" | cut -d= -f2)"

cleanup() {
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
    # TMP_DIR is kept intentionally so artifacts can be inspected after the run.
}

trap cleanup EXIT

# ── Phase 1: build the service image ─────────────────────────────────────────
docker build -t "$IMAGE_TAG" "$ROOT_DIR"

# ── Phase 2: build the Zig runner image ──────────────────────────────────────
# Mirrors the Dockerfile download approach so the version stays consistent.
docker build -t "$ZIG_IMAGE" --build-arg "ZIG_VERSION=${ZIG_VERSION}" - <<'DOCKERFILE'
FROM alpine:3.20
ARG ZIG_VERSION
RUN apk add --no-cache bash curl xz git
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    -o /tmp/zig.tar.xz \
    && mkdir -p /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1
ENV PATH="/opt/zig:$PATH"
DOCKERFILE

# ── Phase 3: create the shared network and start the service ─────────────────
# The network lets the Zig runner reach packbase by container name.
# The port mapping lets curl on the host do the health check and API calls.
docker network create "$NETWORK_NAME" >/dev/null
docker run -d \
    --name "$CONTAINER_NAME" \
    --network "$NETWORK_NAME" \
    -p "${HOST_PORT}:8080" \
    -e "PACKBASE_TOKEN=${API_TOKEN}" \
    -v "$ROOT_DIR/scripts/create-fixture-repos.sh:/seed/create-fixture-repos.sh:ro" \
    -v "$ROOT_DIR/test/fixtures:/fixtures:ro" \
    --entrypoint /bin/sh \
    "$IMAGE_TAG" \
    -lc 'mkdir -p /var/lib/packbase/public/git && sh /seed/create-fixture-repos.sh /var/lib/packbase/public/git /fixtures && exec /usr/local/bin/packbase' \
    >/dev/null

for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${HOST_PORT}/git/hello.git/info/refs" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# ── Phase 4: verify git clone works ──────────────────────────────────────────
git clone "http://127.0.0.1:${HOST_PORT}/git/hello.git" "$TMP_DIR/hello" >/dev/null 2>&1

test -f "$TMP_DIR/hello/build.zig.zon"
grep -q 'hello_fixture' "$TMP_DIR/hello/build.zig.zon"

printf 'git clone: OK\n'

# ── Phase 5: mirror a remote package via POST /api/fetch ─────────────────────
# Packbase clones the upstream repo, resolves the latest tag, materialises a
# tarball, and stores it under /p/<name>/tag/<tag>.tar.gz.  The response body
# carries the local URL where the package is now available.
FETCH_RESP="$(curl -fsS \
    --max-time 120 \
    -X POST \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"url":"git+https://github.com/OrlovEvgeny/serde.zig"}' \
    "http://127.0.0.1:${HOST_PORT}/api/fetch")"

printf 'api/fetch response: %s\n' "$FETCH_RESP"

# Extract the package URL from the JSON response.
PKG_URL="$(printf '%s' "$FETCH_RESP" | sed 's/.*"url":"\([^"]*\)".*/\1/')"
test -n "$PKG_URL"

printf 'api/fetch: OK (%s)\n' "$PKG_URL"

# ── Phase 5b: list packages available on this instance ───────────────────────
LIST_RESP="$(curl -fsS "http://127.0.0.1:${HOST_PORT}/api/list")"

printf 'api/list response: %s\n' "$LIST_RESP"

printf '%s' "$LIST_RESP" | grep -q '"hello"'
printf '%s' "$LIST_RESP" | grep -q '"serde.zig"'

printf 'api/list: OK\n'

# ── Phase 5c: verify the release identifier exposed by this build ────────────
RELEASE_RESP="$(curl -fsS "http://127.0.0.1:${HOST_PORT}/api/info")"

printf 'api/info response: %s\n' "$RELEASE_RESP"

printf '%s' "$RELEASE_RESP" | grep -q "\"release\":\"${EXPECTED_RELEASE}\""
printf '%s' "$RELEASE_RESP" | grep -q '"service":"packbase"'

printf 'api/info: OK\n'

# ── Phase 6: install the mirrored package with zig fetch --save ───────────────
# The Zig runner resolves the package from packbase (not from GitHub), which is
# the core promise of the service.
FETCH_DIR="$TMP_DIR/fetch-project"
mkdir -p "$FETCH_DIR"

cat > "$FETCH_DIR/build.zig.zon" <<'ZON'
.{
    .name = .smoke_test,
    .version = "0.0.0",
    .dependencies = .{},
    .paths = .{""},
}
ZON

cat > "$FETCH_DIR/build.zig" <<'ZIG'
const std = @import("std");
pub fn build(_: *std.Build) void {}
ZIG

docker run --rm \
    --network "$NETWORK_NAME" \
    -v "$FETCH_DIR:/work" \
    -w /work \
    "$ZIG_IMAGE" \
    zig fetch --save "http://${CONTAINER_NAME}:8080${PKG_URL}"

test -f "$FETCH_DIR/build.zig.zon"
grep -q 'serde'  "$FETCH_DIR/build.zig.zon"
grep -q '\.hash' "$FETCH_DIR/build.zig.zon"

printf 'zig fetch --save: OK\n'

printf 'smoke test passed\n'
