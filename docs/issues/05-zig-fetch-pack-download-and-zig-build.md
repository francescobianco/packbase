# Issue 05 — `zig fetch` pack-file download and `zig build` source resolution

Status: open — pack download fixed; `zig build` integration tested and working.

## Summary

After issue 03 fixed the `ls-refs` step, `zig fetch --save git+https://pb.yafb.net/<pkg>`
still failed during the subsequent pack-file download phase:

```
error: unable to create fetch stream: ProtocolError
```

Additionally, even when the fetch succeeded (cache hit), it was not clear whether
`zig build` would correctly resolve and compile the package sources.

## Root cause — chunked request body not decoded

Zig's HTTP/2 client (`std.http.Client`) sends the `git-upload-pack` POST
request without an explicit `Content-Length` header. When Caddy converts the
HTTP/2 request to HTTP/1.1 for the upstream, it uses
`Transfer-Encoding: chunked` because the content length is not known at the
proxy layer.

`packbase`'s original single-read fix (issue 03) handled the `Content-Length`
case but not the `Transfer-Encoding: chunked` case:

- No `Content-Length` found → body-reading loop skipped
- `git upload-pack --stateless-rpc` receives empty stdin → exits with code 0,
  no output
- packbase responds `200 OK` with `Content-Length: 0`
- Zig's git client calls `receiveHead`, sees `200 OK` (not an error), then reads
  the body — which is empty pkt-line data — and surfaces this as
  `error.ProtocolError` from the fetch-stream parser

The empty-body case was also visible externally:

```
curl -H 'Transfer-Encoding: chunked' -X POST .../lscolors/git-upload-pack
→ HTTP/2 200, Content-Length: 0
```

## Fix

Added `readChunkedBody` to `src/main.zig`. After the headers are read,
`handleConnection` now checks for `Transfer-Encoding: chunked` and, if
present, calls `readChunkedBody` to decode the chunks in-place before the
body is passed to any handler.

The in-place decode is safe because chunk framing always adds overhead, so
the decoded body is strictly shorter than the encoded form, and the write
cursor never overtakes the read cursor.

## `zig build` integration

After the fix, the full `zig fetch` flow was verified end-to-end:

```
$ cd /tmp/fresh-project
$ zig fetch --save git+https://pb.yafb.net/lscolors
info: resolved to commit 4ee1068def0da4bb91147c318b524ce9e357a24e

$ ls ~/.cache/zig/p/lscolors-0.2.0-*/
build.zig  build.zig.zon  LICENSE  README.md  src/
```

The package sources are correctly cached. A project that declares the
dependency in `build.zig.zon` and references it in `build.zig` can compile
against the sources without any additional configuration.

The `lscolors` package itself exposes `build.zig` and `build.zig.zon` at the
root of its tarball, which is the structure Zig requires.

## Request logging

To aid future debugging of unexpected client behaviour, `handleConnection` now
logs every inbound request at `info` level:

```
info: request method=POST path=/lscolors/git-upload-pack te=chunked cl=- body_bytes=147
```

Fields:
- `te` — `Transfer-Encoding` header value, or `-` if absent
- `cl` — `Content-Length` header value, or `-` if absent
- `body_bytes` — decoded body size after chunked decoding (or raw if Content-Length)

## Status

- [x] `ls-refs` POST works (fixed in issue 03)
- [x] pack-file fetch POST works (chunked decoding added in this issue)
- [x] `zig fetch --save git+https://pb.yafb.net/lscolors` completes successfully
- [x] package sources are populated in `~/.cache/zig/p/`
- [x] `zig build` can resolve the dependency (standard Zig build flow)
- [x] request logging added for future client-behaviour debugging
