# packbase

[![CI](https://github.com/francescoalemanno/packbase/actions/workflows/ci.yml/badge.svg)](https://github.com/francescoalemanno/packbase/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.15-orange.svg)](https://ziglang.org)
[![Docker](https://img.shields.io/badge/Docker-ready-2496ED.svg)](Dockerfile)

**packbase** is a self-hosted distribution layer for Zig packages built around one idea that must stay fixed:
the primary artifact is the tarball, not the Git repository.

This project matters because it defines a stricter and more reliable contract for package distribution:
- packbase stores deterministic release tarballs under `/p/<pkg>/tag/<tag>.tar.gz`
- `update` and `fetch` build and refresh the internal state of the registry
- the backend must know tags, versions, and package metadata from that internal state
- the Git-facing surface is only a pseudo-Git compatibility layer for clients such as `zig fetch`
- packbase must not depend on hosting or exposing persistent mirrored Git repositories as its source of truth
- packbase must not execute Git operations at request time just to discover what package data exists

In other words: Git is an ingress protocol and a compatibility interface, not the backend data model.
The backend truth is the tarball set plus the state derived from updates.

This distinction is the core value of the project. It makes packbase closer to a real package registry:
stable, cacheable, inspectable, and operationally simpler than a Git mirror disguised as one.

```
upstream Git  ──►  packbase fetch/update  ──►  internal state + tarballs
                                                      │
                                                      ├─► /p/<pkg>/tag/<tag>.tar.gz
                                                      └─► pseudo-Git interface for clients
```

`zig fetch` should be able to talk to packbase as if it were speaking to Git, while packbase internally remains a tarball-first registry.

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

L'immagine di produzione non include fixture pre-caricati. Se vuoi avere sempre
almeno un pacchetto disponibile su un deployment Compose, `compose.yml` monta i
fixture di test e li materializza sul volume dati al bootstrap del container.
Se i fixture montati non sono presenti, il bootstrap genera comunque un
pacchetto seed `hello` incorporato.

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
  "url": "/p/repo/tag/v1.2.3.tar.gz",
  "tarballs_created": 4,
  "tarballs_present": 0,
  "tarball_count": 4
}
```

**Error codes**

| Code | Meaning |
|---|---|
| `400` | Missing or malformed JSON body |
| `401` | Missing Authorization header |
| `403` | Invalid token |
| `422` | Repository has no tags |
| `502` | upstream fetch failed (network or URL error) |

### `GET /p/<package>/tag/<tag>.tar.gz`

Download a previously mirrored tarball.

### `GET /api/list`

Restituisce:
- `packages`: unione dei pacchetti locali e di quelli registrati tramite `PACKBASE_SOURCE`
- `local_packages`: pacchetti realmente materializzati nell'istanza
- `registered_packages`: pacchetti presenti nell'ultimo snapshot sincronizzato del source remoto

**Response `200`**
```json
{
  "packages": ["hello", "remote-only", "serde.zig"],
  "local_packages": ["hello", "serde.zig"],
  "registered_packages": ["hello", "remote-only"]
}
```

### `GET /api/info/<package>`

Restituisce lo snapshot persistito dell'ultimo `POST /api/update` per un pacchetto:
- visibilita del pacchetto nell'istanza
- presenza nel source catalog
- materializzazione locale
- tarball disponibili e loro dimensione
- dimensione totale occupata dal pacchetto nell'istanza
- esito dell'ultima verifica di fetchability pseudo-Git calcolata durante `update`

Le informazioni non vengono calcolate on demand: se manca lo snapshot, va eseguita prima `POST /api/update`.

**Response `200`**
```json
{
  "package": "hello",
  "available": true,
  "registered": false,
  "local": true,
  "tarball_dir_present": true,
  "tarball_count": 1,
  "latest_tag": "v0.1.0",
  "latest_size_bytes": 371,
  "size_bytes": 371,
  "tarballs": [{"tag": "v0.1.0", "size_bytes": 371}],
  "smart_http_ready": true,
  "pseudo_git_fetchable": true,
  "healthy": true
}
```

**Response `404`**
```json
{
  "status": "not_found",
  "package": "missing-package"
}
```

### `GET /api/status`

Restituisce metadati dell'istanza, incluso l'identificativo di rilascio della
build servita e lo stato persistito dell'ultima `update`.

**Response `200`**
```json
{
  "service": "packbase",
  "release": "r0007",
  "packages_total": 79,
  "packages_healthy": 74,
  "packages_unhealthy": 5,
  "update": {
    "state": "idle",
    "started_at": 1776183143,
    "updated_at": 1776183143,
    "source_packages": 79
  }
}
```

### `POST /api/update`

Riallinea in modo soft lo stato interno in modo pubblico e idempotente:
- materializza i tarball mancanti sotto `/p` per i pacchetti del source catalog che non sono `fresh`
- mantiene il supporto ai repository fixture locali
- aggiorna `update-server-info`
- scarica `PACKBASE_SOURCE`, conserva lo snapshot locale, calcola un diff con lo snapshot precedente e aggiorna la lista dei pacchetti registrati
- aggiorna lo snapshot persistito dei package sotto `.packbase/package-info.json`, includendo size e fetchability pseudo-Git
- applica un cooldown per evitare carico eccessivo quando viene chiamata ripetutamente

L'endpoint è pubblico e non richiede token.

**Response `200`**
```json
{
  "status": "ok",
  "repos_scanned": 1,
  "packages_synced": 1,
  "tarballs_created": 1,
  "tarballs_present": 0,
  "source_changed": true,
  "source_packages": 2,
  "source_added": 2,
  "source_updated": 0,
  "source_removed": 0
}
```

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
5. Runs `zig fetch --save git+http://.../hello` inside a container, confirming the pseudo-Git smart-HTTP path works through `git-upload-pack`.
6. Checks the service logs for a chunked `git-upload-pack` request.
7. Runs `zig build` against the fetched dependency so source resolution is verified, not just metadata fetch.

To verify the short Git URL directly, run:

```bash
bash test/remote.sh pb.yafb.net hello r0007
```

Or:

```bash
PACKBASE_REMOTE_DOMAIN=pb.yafb.net PACKBASE_EXPECTED_RELEASE=r0007 bash test/remote.sh
```

The remote smoke now checks these things against the deployed instance behind Caddy:
- root-level `git clone https://.../<repo>`
- `POST /api/update` followed by `/api/info/<repo>` for persisted integrity metadata
- `zig fetch --save git+https://.../<repo>`
- `zig build` against the fetched dependency
- liveness after a second `zig fetch`, so regressions that panic after the first request are visible
- batch installation of the 10 smallest healthy packages selected from `/api/list` and validated with `/api/info/<pkg>`

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
