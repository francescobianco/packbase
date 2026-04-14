#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_TAG="packbase-remote:local"
CONTAINER_NAME="packbase-remote-$$"
HOST_PORT="${PACKBASE_TEST_PORT:-18081}"
TMP_DIR="$ROOT_DIR/test/tmp"

rm -rf "$TMP_DIR/remote-clone"
mkdir -p "$TMP_DIR"

cleanup() {
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}

trap cleanup EXIT

docker build -t "$IMAGE_TAG" "$ROOT_DIR" >/dev/null

docker run -d \
    --name "$CONTAINER_NAME" \
    -p "${HOST_PORT}:8080" \
    "$IMAGE_TAG" >/dev/null

for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${HOST_PORT}/hello/info/refs" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

git clone "http://127.0.0.1:${HOST_PORT}/hello" "$TMP_DIR/remote-clone" >/dev/null 2>&1

test -f "$TMP_DIR/remote-clone/build.zig.zon"
grep -q 'hello_fixture' "$TMP_DIR/remote-clone/build.zig.zon"

printf 'remote git clone without /git prefix: OK\n'
printf 'example VCS URL shape: git+https://pb.yafb.net/hello\n'
