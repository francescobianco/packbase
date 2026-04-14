# packbase

[![CI](https://github.com/francescoalemanno/packbase/actions/workflows/ci.yml/badge.svg)](https://github.com/francescoalemanno/packbase/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.15-orange.svg)](https://ziglang.org)
[![Docker](https://img.shields.io/badge/Docker-ready-2496ED.svg)](Dockerfile)

**packbase** is a self-hosted distribution layer for Zig packages.  
It mirrors upstream Git repositories, materialises deterministic tarballs, and serves them over HTTP so that `zig fetch` never has to reach GitHub at install time.

```
upstream Git  ──►  packbase /api/fetch  ──►  /p/<pkg>/tag/<tag>.tar.gz
                                                    │
                                                    ▼
                                         zig fetch --save http://packbase/…
```

---

## Quick start

```bash
# Build and run
docker build -t packbase .
docker run -p 8080:8080 \
  -e PACKBASE_TOKEN=secret \
  -e PACKBASE_ROOT=/data \
  -v packbase-data:/data \
  packbase
```

### Mirror a package

```bash
curl -X POST http://localhost:8080/api/fetch \
  -H "Authorization: Bearer secret" \
  -H "Content-Type: application/json" \
  -d '{"url":"git+https://github.com/OrlovEvgeny/serde.zig"}'
# {"status":"ok","package":"serde.zig","tag":"v0.3.0","url":"/p/serde.zig/tag/v0.3.0.tar.gz"}
```

### Install from packbase in your project

```bash
zig fetch --save http://localhost:8080/p/serde.zig/tag/v0.3.0.tar.gz
```

`build.zig.zon` becomes:

```zig
.dependencies = .{
    .@"serde.zig" = .{
        .url = "http://localhost:8080/p/serde.zig/tag/v0.3.0.tar.gz",
        .hash = "122059e3…",
    },
},
```

---

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `PACKBASE_ROOT` | `public` | Root directory for served files and materialised packages |
| `PACKBASE_PORT` | `8080` | Listening port |
| `PACKBASE_TOKEN` | *(unset)* | Bearer token for `POST /api/fetch`. When unset, auth is disabled |

---

## API

### `POST /api/fetch`

Mirror an upstream Git repository.

**Headers**
- `Authorization: Bearer <token>` — required when `PACKBASE_TOKEN` is set
- `Content-Type: application/json`

**Body**
```json
{"url": "git+https://github.com/owner/repo"}
```

**Response `200`**
```json
{
  "status": "ok",
  "package": "repo",
  "tag": "v1.2.3",
  "url": "/p/repo/tag/v1.2.3.tar.gz"
}
```

**Error codes**

| Code | Meaning |
|---|---|
| `400` | Missing or malformed JSON body |
| `401` | Missing Authorization header |
| `403` | Invalid token |
| `422` | Repository has no tags |
| `502` | `git clone` failed (network or URL error) |

### `GET /p/<package>/tag/<tag>.tar.gz`

Download a previously mirrored tarball.

### `GET /git/<repo>.git/…`

Dumb-HTTP Git endpoint for pre-baked fixture repositories (used internally by CI).

### `GET /<repo>/…`

Alias del repository Git esposto in radice. Questo consente di clonare un
repository ospitato da packbase senza il prefisso `/git` e senza il suffisso
`.git`, ad esempio:

```bash
git clone https://pb.yafb.net/miopacchetto
```

Se il consumer usa URL VCS con prefisso `git+https://`, il path resta lo stesso:

```text
git+https://pb.yafb.net/miopacchetto
```

---

## Running the smoke test

```bash
make test-smoke
```

The smoke test:
1. Builds the Docker image.
2. Starts packbase with a test token.
3. Verifies the dumb-HTTP Git endpoint with `git clone`.
4. Calls `POST /api/fetch` to mirror `serde.zig` from GitHub.
5. Runs `zig fetch --save` against the packbase URL inside a container and confirms the `build.zig.zon` is updated with the hash.

To verify the short Git URL directly, run:

```bash
bash test/remote.sh pb.yafb.net hello
```

Or:

```bash
PACKBASE_REMOTE_DOMAIN=pb.yafb.net bash test/remote.sh
```

Artefacts survive in `test/tmp/` for inspection after the run.

---

## Building a distributed registry with packbase

packbase is intentionally minimal: one binary, one HTTP server, files on disk.  
That simplicity makes it easy to compose into a **distributed, multi-tier registry**.

### Topology

```
              ┌─────────────────────────────────────────────┐
              │              upstream (GitHub, etc.)         │
              └────────────────────┬────────────────────────┘
                                   │ git+https://
                    ┌──────────────▼──────────────┐
                    │   Central packbase node      │
                    │   (one per org / region)     │
                    │   POST /api/fetch            │
                    │   stores tarballs on S3/NFS  │
                    └──────┬──────────────┬────────┘
                           │              │
              ┌────────────▼──┐    ┌──────▼───────────┐
              │  Edge node A  │    │   Edge node B     │
              │  (on-prem DC) │    │   (CI farm)       │
              └───────┬───────┘    └────────┬──────────┘
                      │                     │
               zig fetch --save      zig fetch --save
```

### How it works

**1. Central node pulls from upstream once**

A cron job or webhook calls `POST /api/fetch` on the central node whenever a new tag appears upstream.  The central node clones the repo, creates a deterministic tarball, and stores it.

**2. Edge nodes serve from local cache**

Edge nodes point `PACKBASE_ROOT` at a replicated volume (S3 bucket, NFS share, or a nightly `rsync` from the central node).  They only serve `GET` requests; they never clone from GitHub.  Developer machines and CI runners always resolve packages from the nearest edge node.

**3. `build.zig.zon` pins a packbase URL**

```zig
.httpx = .{
    .url = "https://packages.example.com/p/httpx/tag/v1.4.2.tar.gz",
    .hash = "1220…",
},
```

Swapping the base URL (e.g. for a closer edge node) does not affect the hash, so reproducibility is preserved.

**4. Immutability guarantee**

Tag URLs never change.  Once `/p/httpx/tag/v1.4.2.tar.gz` exists on the central node it is never overwritten.  Edge nodes replicate the blob by content address, so builds remain reproducible even if the upstream tag moves or the repository disappears.

**5. Offline / air-gapped builds**

Once all dependencies are mirrored, the CI network can be locked down.  `zig fetch` resolves everything from the edge node on the internal network.  The upstream internet is no longer on the critical path.

### Deployment recipe (minimal)

```yaml
# docker-compose.yml for a central + one edge node
services:
  packbase-central:
    image: packbase
    environment:
      PACKBASE_TOKEN: "${PACKBASE_TOKEN}"
      PACKBASE_ROOT: /data
    volumes:
      - packages:/data
    ports: ["8080:8080"]

  packbase-edge:
    image: packbase
    environment:
      PACKBASE_ROOT: /data   # read-only replica, no token needed
    volumes:
      - packages:/data:ro
    ports: ["8081:8080"]

volumes:
  packages:
```

Mirror a package on the central node, then serve it from the edge:

```bash
# mirror once
curl -X POST http://central:8080/api/fetch \
  -H "Authorization: Bearer ${PACKBASE_TOKEN}" \
  -d '{"url":"git+https://github.com/owner/mylib"}'

# install from the edge (in build.zig.zon or via CLI)
zig fetch --save http://edge:8081/p/mylib/tag/v1.0.0.tar.gz
```

---

## Design

See [DESIGN.md](DESIGN.md) for the full architecture document.

## License

[MIT](LICENSE)
