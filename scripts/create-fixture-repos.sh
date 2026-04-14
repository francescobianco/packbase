#!/usr/bin/env sh
set -eu

output_dir="${1:-public/git}"
fixtures_dir="${2:-fixtures}"

mkdir -p "$output_dir"

for fixture_dir in "$fixtures_dir"/*; do
    [ -d "$fixture_dir" ] || continue

    fixture_name="$(basename "$fixture_dir")"
    repo_dir="$output_dir/$fixture_name.git"
    work_dir="$(mktemp -d)"
    source_dir="$work_dir/source"

    git init --bare "$repo_dir" >/dev/null
    git init "$source_dir" >/dev/null
    cp -R "$fixture_dir"/. "$source_dir"/

    git -C "$source_dir" config user.name "Packbase Fixture"
    git -C "$source_dir" config user.email "fixtures@packbase.local"
    git -C "$source_dir" add .
    git -C "$source_dir" commit -m "Initial fixture" >/dev/null
    git -C "$source_dir" branch -M main
    git -C "$source_dir" tag v0.1.0
    git -C "$source_dir" remote add origin "$repo_dir"
    git -C "$source_dir" push origin main >/dev/null
    git -C "$source_dir" push origin v0.1.0 >/dev/null

    git -C "$repo_dir" symbolic-ref HEAD refs/heads/main
    git -C "$repo_dir" update-server-info

    # Create a tarball consumable by `zig fetch --save http://…`.
    # Path mirrors the future /p/<name>/tag/<tag>.tar.gz layout from DESIGN.md.
    pkg_dir="$(dirname "$output_dir")/p/${fixture_name}/tag"
    mkdir -p "$pkg_dir"
    git -C "$repo_dir" archive --format=tar.gz v0.1.0 > "${pkg_dir}/v0.1.0.tar.gz"

    rm -rf "$work_dir"
done
