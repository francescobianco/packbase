# Packbase Design

## Overview

Packbase is a self-hosted mirror for versioned package tarballs distributed via
a pseudo-Git layer, providing compatibility for package managers like `zig fetch`
that consume packages through the Git smart HTTP protocol.

**Core idea**: tarballs are the single source of truth. Packbase synthesises a
Git-compatible interface on top of them so that consumers can use `git+https://`
URLs without any live Git repository needing to exist on the server.

```
Upstream Git repo → tarball archive → Packbase CDN
                                           ↓
                          zig fetch git+https://host/git/pkg
                                           ↓
                     synthetic bare repo built on demand from tarball
                                           ↓
                          git smart HTTP (upload-pack)
```

## Problem

Using public Git for package delivery has recurring operational drawbacks:

- upstream availability is on the critical path;
- rate limits and transient outages affect builds;
- branch references are mutable and weaken reproducibility;
- Git clone is heavier than downloading a prepared archive;
- metadata and caching are inconsistent across providers.

Packbase addresses these issues by converting selected Git refs into stable,
cacheable tarballs and then re-exposing them through a lightweight Git
compatibility layer that does not depend on the original repository.

## Goals

- Mirror selected Git refs as deterministic tarballs (`tar.gz`).
- Serve those tarballs via a pseudo-Git smart HTTP layer.
- Support `zig fetch git+https://` URLs without requiring a live upstream.
- Keep the server stateless with respect to Git: no bare repos need to exist
  on disk; they are built on demand from tarballs and cached.
- Keep the first implementation simple enough to ship as a single Zig binary.

## Non-Goals

- Full Git hosting (push, branch management, web UI).
- Mirroring complete repository history (only tag snapshots are needed).
- Acting as a general-purpose package registry with search and social features.

## Core Concepts

### Upstream

The external Git repository used as source material.

### Ref

A named upstream selector such as a tag or branch. Packbase may also expose
direct commit snapshots.

### Snapshot

The normalized directory tree corresponding to a resolved commit.

### Artifact

The packaged representation of a snapshot, such as `tar.gz`.

### Manifest

The metadata document linking package identity, upstream provenance, resolved
commit, artifact digest, and ecosystem-specific hashes.

## Product Model

Packbase behaves as a **pseudo-Git distribution layer**:

- it understands Git tags to map versions to tarballs;
- it uses the Git CLI only during ingest (clone/archive) and cache building;
- it distributes static tarballs as the primary artifact;
- it emulates the Git smart HTTP protocol so that `zig fetch git+https://`
  works without any upstream dependency at fetch time.

For consumers, the important contracts are:
1. `GET /p/{pkg}/tag/{tag}.tar.gz` — direct tarball download;
2. `git+https://{host}/git/{pkg}` — pseudo-Git endpoint built from tarballs.

## Pseudo-Git Layer (implemented)

This is the core differentiator. When a client issues a Git smart HTTP request
for a package (`zig fetch git+https://host/git/httpz.zig`), packbase:

1. **Resolves the repo directory** (`resolveRepoDir` in `src/main.zig`):
   - First checks for a physical bare repo at `{root}/git/{pkg}` (legacy path,
     kept for compatibility).
   - If absent, falls through to `ensureGitCacheFromTarballs`.

2. **Builds a synthetic bare repo** (`ensureGitCacheFromTarballs` +
   `buildGitRepoFromTarballs`):
   - Scans `{root}/p/{pkg}/tag/*.tar.gz` for available versions.
   - Sorts tags lexicographically.
   - For each tag: extracts the tarball into a temp working directory
     (handling both prefixed and non-prefixed tarballs via
     `extractTarballNormalized`), then commits with a fixed author identity
     and timestamp so the resulting git tree is deterministic.
   - Clones the working repo as a bare repo into
     `{root}/.packbase/git-cache/{pkg}`.
   - Cache is reused until the number of tarballs changes (new version
     published → cache rebuild on next request).

3. **Serves via standard git upload-pack**:
   - `GET /git/{pkg}/info/refs?service=git-upload-pack` → advertise refs
   - `POST /git/{pkg}/git-upload-pack` → pack negotiation

Key properties:
- **Deterministic**: same tarball content always produces the same git tree
  hash (fixed `GIT_AUTHOR_*` / `GIT_COMMITTER_*` env vars).
- **No upstream dependency at serve time**: once tarballs are stored, the
  server needs no network access.
- **Tarball formats handled**: both `git archive` output (no prefix directory)
  and `tar czf dir/` output (single top-level prefix) are normalised
  transparently.

```
{root}/
  p/
    httpz.zig/
      tag/
        v0.6.0.tar.gz       ← source of truth
        v0.7.0.tar.gz
  .packbase/
    git-cache/
      httpz.zig/            ← synthetic bare repo (auto-built, rebuilt on new tags)
        HEAD
        packed-refs
        objects/
```

## System Architecture

### 1. Catalog

The catalog defines which upstream repositories are observed and how they should
be synchronized.

A catalog entry contains:

- package name;
- upstream repository URL;
- allowed tag patterns;
- allowed branch patterns;
- preferred artifact format;
- refresh policy;
- retention policy.

Example:

```zig
.{
    .packages = .{
        .httpx = .{
            .upstream = "https://github.com/acme/httpx",
            .tags = "v*",
            .branches = &.{"stable"},
            .archive_format = .tar_gz,
        },
    },
}
```

### 2. Sync

The sync subsystem periodically inspects each configured upstream and resolves:

- new tags;
- branch updates;
- explicit ref-to-commit mappings.

Each discovered ref becomes a materialization candidate. Tags are expected to be
immutable. Branches are treated as moving aliases that always resolve to a
specific commit before distribution.

### 3. Snapshot Materialization

For each resolved commit, Packbase produces a canonical snapshot tree. This
stage is responsible for determinism.

Normalization rules should include:

- stable file ordering;
- normalized permissions;
- normalized timestamps;
- consistent path layout;
- optional exclusion of unwanted files when policy requires it.

This stage is the foundation for reproducibility. Repeating the same upstream
resolution must produce the same logical tree.

### 4. Packaging

The normalized snapshot is converted into one or more archive formats. The
initial implementation should support `tar.gz` only.

Future formats may include:

- `tar.xz`;
- `zip`;
- raw file serving;
- Git bundles for specialized workflows.

### 5. Storage

Artifacts are stored by content digest. Ref manifests are stored separately and
map logical names to immutable blobs.

Suggested layout:

```text
/data/packbase/
  blobs/
    sha256/
      ab/
        cd/
          abcd...tar.gz
  refs/
    httpx/
      tags/
        v1.4.2.json
      branches/
        stable.json
  manifests/
    commits/
      7f/
        7f83b1....json
```

This separation makes cache invalidation straightforward:

- blobs are immutable;
- tag manifests should never move after creation;
- branch manifests may be updated to point to newer commits.

### 6. HTTP Delivery

Packbase exposes artifacts and manifests through stable, cache-friendly
endpoints.

Example routes:

```text
GET /p/httpx/tag/v1.4.2.tar.gz
GET /p/httpx/tag/v1.4.2.json
GET /p/httpx/branch/stable.tar.gz
GET /p/httpx/branch/stable.json
GET /p/httpx/commit/7f83b1.tar.gz
GET /p/httpx/commit/7f83b1.json
```

Expected serving behavior:

- immutable responses for tag and commit URLs;
- mutable alias semantics for branch URLs;
- strong cache headers for immutable artifacts;
- ETag and conditional requests where practical;
- range request support for large artifacts.

## Data Model

### Package Configuration

```zig
const PackageConfig = struct {
    name: []const u8,
    upstream: []const u8,
    tags: ?[]const u8,
    branches: []const []const u8,
    archive_format: ArchiveFormat,
    refresh_interval_seconds: u32,
};
```

### Resolved Ref

```zig
const RefKind = enum { tag, branch, commit };

const ResolvedRef = struct {
    package: []const u8,
    kind: RefKind,
    ref_name: []const u8,
    source_commit: []const u8,
};
```

### Manifest

```json
{
  "package": "httpx",
  "upstream": "https://github.com/acme/httpx",
  "ref_kind": "tag",
  "ref_name": "v1.4.2",
  "source_commit": "7f83b1...",
  "artifact_format": "tar.gz",
  "artifact_digest": "sha256:abcd...",
  "content_digest": "sha256:efgh...",
  "created_at": "2026-04-14T10:15:00Z"
}
```

## Digest Strategy

Packbase should track at least two identities:

- `artifact_digest`: digest of the stored archive file;
- `content_digest`: digest of the normalized extracted tree.

This distinction matters because transport integrity and logical content identity
solve different problems. A single snapshot may later be emitted in multiple
archive formats while preserving the same content identity.

For Zig specifically, Packbase should also expose a field compatible with the
hash expected by `build.zig.zon`.

## Zig Integration

The first concrete consumer is Zig. Instead of pointing a dependency to a GitHub
release archive, a package can point to Packbase.

Before:

```zig
.{
    .dependencies = .{
        .httpx = .{
            .url = "https://github.com/acme/httpx/archive/refs/tags/v1.4.2.tar.gz",
            .hash = "1220....",
        },
    },
}
```

After:

```zig
.{
    .dependencies = .{
        .httpx = .{
            .url = "https://packbase.example.com/p/httpx/tag/v1.4.2.tar.gz",
            .hash = "1220....",
        },
    },
}
```

This keeps the consumer model unchanged: URL plus content hash.

## Internal Modules

### `core`

Shared types, config, manifest schema, and domain rules.

### `catalog`

Loads configured packages and validates patterns and policies.

### `upstream`

Abstracts external providers.

Minimal interface:

- `listRefs`
- `resolveRef`
- `fetchSnapshot`
- `fetchArchive`

### `sync`

Coordinates polling, change detection, and job creation.

### `artifact_builder`

Builds canonical snapshots, packages them, and computes digests.

### `storage`

Persists blobs and manifests on filesystem or object storage.

### `server`

Serves HTTP endpoints and handles cache semantics.

### `admin`

Exposes operational commands or endpoints for registration, refresh, inspection,
and garbage collection.

## Operational Model

Packbase should run as a single binary with separate execution modes:

```text
packbase serve
packbase sync
packbase admin
```

Initial deployment:

- `serve` process for HTTP;
- scheduled `sync` execution;
- local filesystem storage;
- reverse proxy for TLS.

Later deployment:

- object storage for blobs;
- SQLite or Postgres for metadata;
- dedicated workers for materialization;
- external CDN in front of `/p/...`.

## Failure Model

If an upstream provider becomes unavailable:

- already materialized artifacts remain downloadable;
- tag and commit URLs remain valid;
- branch refresh stalls, but existing branch aliases can still serve the last
  known artifact unless policy disables stale serving.

This is a primary value proposition of Packbase: upstream Git providers are no
longer in the runtime delivery path.

## Security Considerations

- record the exact upstream URL and resolved commit for every artifact;
- validate that fetched content matches the resolved commit when possible;
- isolate staging directories during materialization;
- reject path traversal and invalid archive entries;
- make admin operations authenticated from the start.

Later enhancements may include signed manifests and artifact attestation.

## Milestone v0.1

The first milestone should stay narrow:

- single upstream provider implementation;
- tag-based synchronization only;
- `tar.gz` as the only artifact format;
- local filesystem storage;
- JSON manifests;
- `GET /p/<pkg>/tag/<tag>.tar.gz`;
- `GET /p/<pkg>/tag/<tag>.json`;
- manual or scheduled `packbase sync`.

This is enough to validate the essential promise: replace public Git-hosted
download URLs with locally served immutable artifacts.

## Future Work

- branch alias support;
- direct commit snapshot URLs;
- multiple upstream providers;
- object storage backend;
- manifest search and browse API;
- retention and garbage collection policies;
- web admin UI;
- package namespace federation;
- signed manifests and provenance verification.
