# Issue 02 — Full `git clone` is used to produce tarballs

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

## Proposed direction — on-demand HTTP fetch with Zig's own git client

Zig's compiler already implements a minimal git smart HTTP client (what `zig fetch git+…` uses
internally). The same approach should be used by packbase:

1. **Remove the persistent `{root}/git/` directory** — no full clones stored on disk.
2. **On first request** for a package + tag, perform a shallow smart HTTP fetch:
   - `GET /info/refs?service=git-upload-pack` against the upstream URL.
   - Negotiate only the tree object for the requested ref.
   - Stream-extract the pack and materialise the tarball directly.
3. **Cache only the finished tarball** in `{root}/p/{pkg}/tag/{tag}.tar.gz`.
4. For the synthetic git serving layer (`ensureGitCacheFromTarballs`), build from already-
   present tarballs exactly as today — no change needed there.

This makes tarballs lazy (created on first request), keeps disk usage proportional to actual
demand, and removes the full-clone step entirely.

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
- [ ] Design on-demand fetch using `std.http.Client` + git pkt-line parser
- [ ] Implement lazy tarball materialisation
- [ ] Remove `syncSourceRepos` / `syncPackages` clone logic
- [ ] Update smoke tests for on-demand flow
