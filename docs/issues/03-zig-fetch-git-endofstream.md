# Issue 03 — `zig fetch git+https://…` fails with `EndOfStream` during ls-refs

## Summary

`zig fetch --save git+https://pb.yafb.net/<pkg>` fails at the ref-iteration step:

```
error: unable to iterate refs: EndOfStream
```

The failure occurs even though:
- The `GET /info/refs?service=git-upload-pack` handshake succeeds and correctly returns git
  protocol v2 capabilities.
- `git ls-remote https://pb.yafb.net/lscolors` works end-to-end (refs v0.1.0, v0.2.0 visible).
- A manual `curl` POST to `/lscolors/git-upload-pack` with a proper pkt-line `ls-refs` body
  receives a valid `HTTP/2 200` response with all refs and a correct `Content-Length: 273`.
- The same POST tested directly against the container on port 8080 (HTTP/1.1) returns a
  well-formed response.

## What is known

| Test | Result |
|------|--------|
| GET info/refs (v2) via HTTPS | ✅ `version 2` + capabilities |
| git ls-remote via HTTPS | ✅ all refs listed |
| curl POST ls-refs via HTTPS | ✅ `200 OK`, 273 bytes |
| curl POST ls-refs on port 8080 (HTTP/1.1) | ✅ valid refs response |
| `zig fetch --save git+https://...` | ❌ `EndOfStream` |

The problem is specific to Zig's own HTTP client, which diverges from curl and git-remote-https
in how it handles the response.

## Hypotheses (not yet confirmed)

### H1 — Missing `0002` response-end packet

Git protocol v2 defines three special packets:
- `0000` flush
- `0001` delimiter  
- `0002` response-end

When using stateless HTTP, some implementations expect the server to append a `0002` packet
at the very end of each command response. The current server sends `0000` + packed refs + `0000`
but no trailing `0002`. Zig's git client may require the `0002` to consider the response
complete; without it, it waits for more data until the TCP connection closes (EOF), which
surfaces as `EndOfStream` when Caddy closes the stream on its side before the expected data
arrives.

**Test**: append `0002` to the output of `git upload-pack --stateless-rpc` in
`handleUploadPackRequest` when `use_v2 = true`.

### H2 — HTTP/2 framing interaction

Caddy terminates TLS/HTTP2 and re-proxies to packbase over HTTP/1.1. Packbase responds with
`Content-Length` and `Connection: close`. Caddy maps this back to HTTP/2 DATA frames. Zig's
HTTP2 client may misinterpret the stream-end signal vs. the git response-end signal.

**Test**: add `X-Accel-Buffering: no` or `Cache-Control: no-cache` response headers to
prevent Caddy from buffering; or configure Caddy to use `flush_interval -1` for the git
routes.

### H3 — `Transfer-Encoding: chunked` vs `Content-Length`

If Caddy decides to use chunked encoding instead of forwarding the Content-Length, and Zig's
HTTP client reads exactly Content-Length bytes before declaring EOF, the trailing pkt-line
data could be cut off.

**Test**: add `header_up -Transfer-Encoding` in the Caddyfile reverse_proxy directive to
force passthrough of Content-Length.

## Next steps

1. Test H1: append `0002` after `git upload-pack` output in `handleUploadPackRequest` for v2.
2. Test H2: add `flush_interval -1` to the Caddyfile `handle @git` block.
3. Test H3: inspect raw bytes with `curl --http1.1 https://pb.yafb.net/...` and compare.
4. Add a minimal Zig HTTP test that replicates what `zig fetch` does, to reproduce locally
   without needing a full deployment.

## Status

- [x] Server correctly implements git protocol v2 (GIT_PROTOCOL=version=2 env var)
- [x] GET /info/refs v2 response verified correct
- [x] POST ls-refs response verified correct via curl
- [ ] Root cause of Zig-specific EndOfStream identified
- [ ] Fix implemented and smoke-tested with `zig fetch --save git+https://pb.yafb.net/lscolors`
