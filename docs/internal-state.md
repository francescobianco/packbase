# Internal state of Packbase

This document describes how Packbase represents and manages its internal state:
tarballs on disk, package metadata, update progress, and the asynchronous update system.

---

## Root layout

All persistent data lives under `PACKBASE_ROOT` (default: `/data` in the Docker image).

```
{PACKBASE_ROOT}/
├── p/                          # tarballs — the primary truth
│   └── {package}/
│       └── tag/
│           ├── v1.0.0.tar.gz
│           └── v1.2.3.tar.gz
├── git/                        # bare repos (populated by /api/fetch, deleted after update)
│   └── {package}.git/
├── public/                     # static files served as-is (e.g. git/ for fixture repos)
│   └── git/
│       └── {repo}.git/
└── .packbase/                  # all internal state (never served directly)
    ├── update.lock
    ├── update.pending
    ├── update.last
    ├── update.status.json
    ├── source.json
    ├── source.previous.json
    ├── source.diff.json
    ├── registered.json
    ├── package-info.json
    └── pkg-ts/
        └── {source-record-id}
```

---

## Tarballs (`p/`)

**Path:** `{root}/p/{package_name}/tag/{tag}.tar.gz`

Tarballs are the primary truth of the registry. They are:
- Created via `git archive --format=tar.gz {tag}` from a cloned bare repo.
- Deterministic: the same tag always produces the same bytes.
- Immutable once written: never overwritten.

There are two creation paths:
1. **`POST /api/fetch`** — clones the upstream repo, runs the archive for each tag, writes tarballs immediately.
2. **On-demand** — when a `GET /p/{package}/tag/{tag}.tar.gz` request arrives and the tarball is not present on disk, Packbase tries to materialize it if the package is in the source catalog (uses a temporary clone in `/tmp`).

Packbase never stores the cloned repo as a persistent artifact — only the tarball survives.

---

## Bare repos (`git/`)

**Path:** `{root}/git/{package_name}.git/`

Bare repos are transient. They are:
- Created during `POST /api/fetch` (or on-demand materialization).
- Used only to run `git archive` and extract tags.
- Removed after each `POST /api/update` cycle (`docker compose exec packbase rm -rf /data/git`).

They do not serve as a source of truth. If they are absent, tarballs are generated on demand from temporary clones.

---

## State directory (`.packbase/`)

### Update lock and cooldown files

| File | Content | Purpose |
|---|---|---|
| `update.lock` | Unix timestamp (i64) | Written at the start of a background update. Deleted on completion. If present and younger than 5 minutes, new requests are queued instead of starting a new run. |
| `update.pending` | Unix timestamp (i64) | Written when a second update request arrives while one is already running. Signals that another run should start after the current one finishes. |
| `update.last` | Unix timestamp (i64) | Written on every `POST /api/update`. Enforces a 15-second cooldown between requests. |

### `update.status.json`

Written at every state transition of the background worker. Reflects the current state of the update pipeline. Served verbatim inside `GET /api/status`.

```json
{
  "state": "running",
  "started_at": 1776000000,
  "updated_at": 1776000005,
  "repos_scanned": 1,
  "packages_synced": 1,
  "tarballs_created": 0,
  "tarballs_present": 3,
  "default_seeded": false,
  "source_changed": true,
  "source_packages": 142,
  "source_added": 2,
  "source_updated": 0,
  "source_removed": 0,
  "source_skipped": 138,
  "retry_after": 0,
  "queued": false,
  "source_repo_cloned": 0,
  "source_repo_updated": 0,
  "source_repo_failed": 0,
  "packages_total": 143,
  "packages_probed": 12
}
```

Possible values of `state`: `idle`, `running`, `queued`, `cooldown`.

`source_skipped` counts packages whose `updated_at` from the source catalog was unchanged since the last sync — see the per-package timestamp cache section below.

### `source.json`

Raw body of the last successful download of `PACKBASE_SOURCE`. Used to detect whether the catalog changed on the next update (byte-level comparison). If the file is absent, the catalog is treated as new.

### `source.previous.json`

Copy of the previous `source.json`, kept only when the catalog changes. Used alongside `source.json` to compute the diff.

### `source.diff.json`

Summary of the last diff between `source.previous.json` and `source.json`:

```json
{
  "source_changed": true,
  "source_packages": 142,
  "source_added": 2,
  "source_updated": 0,
  "source_removed": 0,
  "source_skipped": 138
}
```

### `registered.json`

Flat list of all package names extracted from the current `source.json`. Rebuilt on every update. Used by `/api/list` to return the set of registered (source-catalog) packages without re-parsing the full source JSON.

```json
{"packages": ["foo", "bar", "serde.zig"]}
```

### `package-info.json`

Snapshot of the full package state, computed at the end of every `POST /api/update` cycle. Used by `/api/info/<package>` and by subsequent update cycles (to reuse probe results for fresh packages).

Each entry describes one package:

```json
{
  "package": "serde.zig",
  "available": true,
  "registered": true,
  "local": true,
  "tarball_dir_present": true,
  "tarball_count": 2,
  "latest_tag": "v0.3.0",
  "latest_size_bytes": 12345,
  "size_bytes": 23456,
  "tarballs": [
    {"tag": "v0.2.0", "size_bytes": 11111},
    {"tag": "v0.3.0", "size_bytes": 12345}
  ],
  "smart_http_ready": true,
  "pseudo_git_fetchable": true,
  "fetch_probe_commit": "a1b2c3d4",
  "fetch_probe_error": null,
  "healthy": true,
  "updated_at": 1776000042
}
```

Fields:
- `available`: the package is visible (local or registered).
- `registered`: appears in the source catalog (`registered.json`).
- `local`: has a tarball directory on disk (`p/{package}/tag/`).
- `tarball_dir_present`: the `tag/` directory exists.
- `smart_http_ready`: at least one tarball is present; pseudo-Git HTTP can serve it.
- `pseudo_git_fetchable`: a `zig fetch` probe ran successfully against this package.
- `fetch_probe_commit`: the Git commit SHA returned by the probe.
- `fetch_probe_error`: error message if the probe failed, otherwise null.
- `healthy`: `pseudo_git_fetchable` is true and no probe error.
- `updated_at`: Unix timestamp of when this entry was written (the update run timestamp).

### `pkg-ts/{source-record-id}`

One file per source-catalog package, named after the package's `id` field in the catalog JSON (e.g. `agagniere-unitz`). Contains the `updated_at` ISO string from the catalog at the time of the last sync.

**Purpose:** Skip the expensive pseudo-Git probe for packages whose upstream `updated_at` has not changed since the previous update. On every update cycle:
1. The current `updated_at` from the source JSON is compared with the file's content.
2. If they match (and the value is non-empty), the package is marked **fresh**: the probe is skipped and the previous `package-info.json` result is reused as-is.
3. If they differ (or the file is absent — first-ever sync), the probe runs normally.
4. The file is rewritten with the current `updated_at` regardless.

This makes repeated `POST /api/update` calls significantly cheaper when the upstream catalog hasn't changed.

---

## Asynchronous update system

`POST /api/update` is non-blocking. It returns immediately with a status JSON and runs the actual work in a background OS thread.

### Request lifecycle

```
POST /api/update
      │
      ▼
 cooldown check (15s since last request?)
      │ yes → 429-style response with retry_after
      │ no
      ▼
 lock check (another update running < 5 min?)
      │ yes → write update.pending, return state=queued
      │ no
      ▼
 write update.lock + update.last
 write update.status.json (state=running)
 spawn background thread (updateWorker)
      │
      ▼
 return 200 {"status":"ok",...} immediately
```

### Background worker (`updateWorker`) sequence

```
1. syncSourceCatalog
   ├── curl PACKBASE_SOURCE → source.json
   ├── byte-compare with previous source.json
   ├── compute per-ID diff → source.diff.json
   ├── per-package updated_at check → pkg-ts/{id}
   │     marks fresh packages, counts source_skipped
   └── write registered.json

2. syncSourceRepos   (no-op — tarballs created on demand)

3. syncPackages
   ├── scan git/ for bare repos
   ├── for each repo: git tag --list
   └── for each tag: ensure tarball exists under p/{pkg}/tag/

4. collectPackageInfos
   ├── merge local (p/) and registered package names
   └── for each package: scan tarballs, compute sizes

5. load previous package-info.json snapshot (for fresh-package probe reuse)

6. probe loop — for each package:
   ├── if fresh (updated_at unchanged): copy probe fields from snapshot, skip probe
   └── else: probePseudoGitFetchability
             ├── run /usr/local/bin/packbase as a child process
             └── attempt zig fetch against the pseudo-Git endpoint

7. writePackageInfoSnapshot → .packbase/package-info.json

8. finishUpdateWindow
   ├── delete update.lock + update.pending
   └── write update.status.json (state=idle)
```

### Concurrency model

- One background thread at a time. The lock file (`update.lock`) prevents double runs.
- If a second request arrives during a run, `update.pending` is written. The worker does **not** re-trigger automatically after finishing — the pending flag is only informational for the status response. The client must call `POST /api/update` again after the current run completes.
- Lock expires after 5 minutes (prevents a crashed worker from permanently blocking updates).
- Cooldown of 15 seconds prevents rapid hammering.

### Progress visibility

`GET /api/status` can be polled during a running update. The worker calls `writeUpdateProgress` after each package probe, so `packages_probed` advances in real time while `packages_total` shows the expected total.