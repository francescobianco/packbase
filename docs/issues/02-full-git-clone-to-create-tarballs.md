# Issue 02 — Full `git clone` is used to produce tarballs

Status: open, clarified on April 15, 2026

## Summary

To materialise a tarball for each release, packbase runs `git clone` (or `git clone --bare`)
for every package in the source catalog. This is expensive in bandwidth, disk space, and time:
cloning `engine.git` alone wrote 2.1 GB of tarballs and nearly filled the 9.7 GB server disk.
Packages with hundreds of tags generate a tarball per tag, most of which are never requested.

## Root cause

`sync.zig — syncSourceRepos` clones or fetches the full upstream repository into
`{root}/git/{pkg}.git`, then `syncPackages → syncRepoPackage → ensureRepoTarball` iterates
every tag and runs `git archive {tag}` to create a `.tar.gz` per version.
No demand-based or lazy strategy is used.

## Problems this causes

| Problem | Detail |
|---------|--------|
| Disk exhaustion | `engine` alone consumed 2.1 GB (100+ versions × large codebase). |
| Long sync time | Cloning 79 repos + archiving all tags blocks HTTP for minutes (see Issue 01). |
| Wasted I/O | Tarballs for old, never-requested versions are created upfront. |
| git dependency | The server requires `git` installed and shells out for every operation. |

## Correct architectural direction

The previous local attempt moved tarball creation to request time. That is the
wrong model for packbase.

Packbase is not supposed to be a lazy tarball fetcher. It is supposed to be a
tarball mirror with a pseudo-Git interface layered on top:

1. `update` must fetch upstream source repos and materialise tarballs while the
   upstream is still reachable.
2. Once `update` completes, packbase must be able to keep serving those
   tarballs even if the upstream Git source later disappears or goes offline.
3. The source of truth for serving packages must remain the tarballs and the
   backend's own persisted metadata, not a persistent mirrored Git checkout.
4. No backend path should depend on runtime Git inspection such as
   `git tag`, `git fetch`, or `git clone` to answer questions about what
   versions exist.

So the target is:

- no full mirror clone in `{root}/git/` for source-backed packages
- no on-demand tarball materialisation on `/p/<pkg>/tag/<tag>.tar.gz`
- yes to update-time materialisation of tarballs
- yes to serving previously materialised tarballs while upstream is offline

## Existing repo capability to reuse

The repository already contains `src/git.zig`, which is the key piece that
should replace shelling out to Git for source-backed package ingestion.

Relevant pieces already present in `src/git.zig`:

- `git.Session.init(...)` to negotiate smart HTTP v2 capabilities
- `git.Session.listRefs(...)` to enumerate refs, including `refs/tags/`
- `git.Session.fetch(...)` to fetch a selected ref shallowly over smart HTTP
- `git.indexPack(...)` to build an index for the returned pack
- `git.Repository.init(...)` and `git.Repository.checkout(...)` to check out the
  fetched commit into a worktree

This means the missing work is not "write a Git client from scratch". The
missing work is "wire the existing Zig Git client into `sync.zig` during
`update`".

## Implementation outline

For each `SourceRecord` loaded from `.packbase/source.json`:

1. Open a smart HTTP session to `record.repo_url` with `git.Session.init`.
2. Call `listRefs` filtered to `refs/tags/`.
3. For each tag ref:
   - determine the tag name from `refs/tags/<tag>`
   - use `peeled` when present, otherwise the ref object ID directly
   - check whether `{root}/p/{pkg}/tag/<tag>.tar.gz` already exists
4. If the tarball is missing:
   - call `git.Session.fetch(...)` for that single tag/commit
   - persist the returned pack to a temp file
   - build its index with `git.indexPack(...)`
   - open a temp worktree
   - check out the fetched commit with `git.Repository.checkout(...)`
   - archive that worktree into `{root}/p/{pkg}/tag/<tag>.tar.gz`
5. Repeat for every tag so that `update` leaves behind a complete tarball
   mirror for the package.

Important consequence:

- packbase may still use ephemeral temp directories while running `update`
- but it must not persist upstream mirror clones as the source of truth

## Wrong local attempt to discard

The local branch currently contains an incorrect intermediate implementation
that should be reverted before continuing:

- `syncSourceRepos(...)` was turned into a no-op
- `src/main.zig` gained request-path logic that intercepts
  `/p/<pkg>/tag/<tag>.tar.gz`
- missing tarballs are materialised on demand
- that path still shells out to `git fetch --depth 1`

This is explicitly not the desired behaviour and should not be deployed.

## Notes about tests

The current smoke rewrite also followed the wrong on-demand assumption and must
be corrected.

What the smoke should verify instead:

1. After `/api/update`, a source-backed package such as `remote-only` already
   appears as a fully materialised local package.
2. `remote-only` tarballs exist immediately after update, without needing a
   first HTTP request to `/p/...`.
3. If the upstream source disappears after update, the already materialised
   tarball is still served successfully by packbase.

Important test fixture detail:

- `src/git.zig` is an HTTP smart-Git client, not a `file://` client
- so the smoke fixture should expose the upstream test repo over HTTP smart-Git
  rather than pointing `PACKBASE_SOURCE` at `file:///...`

A good local smoke structure is:

1. seed a local upstream bare repo for `remote-only`
2. expose it through the local packbase pseudo-Git interface on the test host
3. put that HTTP URL in `packbase-source.json`
4. run `/api/update`
5. verify tarball presence
6. remove or disable the upstream fixture
7. verify the tarball remains downloadable

## Current code hotspots

Files that need the next round of work:

- `src/sync.zig`
  replace `ensureSourceRepo(...)` / mirror-clone logic with update-time tarball
  materialisation through `src/git.zig`
- `src/main.zig`
  remove the request-path on-demand tarball materialisation hook
- `test/smoke.sh`
  stop expecting `remote-only` to become local only after first tarball request

## Verification target

The issue can be considered complete when all of the following are true:

- `update` materialises source-backed tarballs without `git clone --mirror`
- source-backed tarballs are created during `update`, not at request time
- packbase can still serve those tarballs after the upstream Git source is gone
- no backend code path needs `git tag`, `git fetch`, or `git clone` to discover
  source package versions
- the materialisation path uses `src/git.zig` smart HTTP, not shell Git

## Session notes

What was learned in this session:

- the "lazy tarball on first request" idea conflicts with the actual product
  goal because it weakens packbase's mirror semantics
- `src/git.zig` already contains the client pieces needed to avoid runtime
  shelling out to Git for source-backed package ingestion
- the real refactor should happen inside `update`, not inside HTTP request
  serving

## Intermediate step — `make update` cleanup

Until the full refactor is done, `make update` on the server should remove `{root}/git/` after
packbase restarts, so that stale full-clone repos do not accumulate:

```makefile
update:
    git pull
    docker compose build packbase
    docker compose up -d packbase
    docker compose exec packbase rm -rf /data/git   # remove full clones
    docker compose logs --tail=20 packbase
```

Existing tarballs in `{root}/p/` are kept — only the raw clones are removed.

## Status

- [x] Identified root cause (full clone + all-tags archive)
- [x] Intermediate fix: `make update` removes `{root}/git/` (Issue 02b)
- [x] Clarified that on-demand tarball materialisation is the wrong direction
- [x] Identified `src/git.zig` as the correct client to reuse
- [ ] Replace source mirror clone logic with update-time tarball materialisation
- [ ] Remove the incorrect on-demand tarball path from `src/main.zig`
- [ ] Rework smoke tests around update-time mirroring and upstream-offline serving
- [ ] Eliminate shell Git from source-backed tarball creation
