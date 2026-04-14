#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_TAG="packbase-smoke:local"
CONTAINER_NAME="packbase-smoke-$$"
HOST_PORT="${PACKBASE_TEST_PORT:-18080}"
TMP_DIR="$(mktemp -d)"

cleanup() {
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

docker build -t "$IMAGE_TAG" "$ROOT_DIR"
docker run -d --name "$CONTAINER_NAME" -p "${HOST_PORT}:8080" "$IMAGE_TAG" >/dev/null

for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${HOST_PORT}/git/hello.git/info/refs" >/dev/null; then
        break
    fi
    sleep 1
done

git clone "http://127.0.0.1:${HOST_PORT}/git/hello.git" "$TMP_DIR/hello" >/dev/null 2>&1

test -f "$TMP_DIR/hello/build.zig.zon"
grep -q 'hello-fixture' "$TMP_DIR/hello/build.zig.zon"

printf 'smoke test passed\n'
