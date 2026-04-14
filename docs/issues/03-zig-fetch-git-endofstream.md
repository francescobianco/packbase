# Issue 03 — `zig fetch git+https://…` fails with `EndOfStream` during ls-refs

Status: resolved on April 15, 2026 — single-read bug in handleConnection fixed; see issue 05 for the follow-on pack-download fix

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

## Live findings gathered on April 15, 2026

The current live investigation adds stronger evidence that the remaining bug is
not in `packbase`'s `git-upload-pack` handler itself, but in the public proxy
path in front of it.

### Confirmed observations

1. `git ls-remote https://pb.yafb.net/lscolors` now works again after removing
   the incorrect trailing `0002` response-end packet from v2 command responses.
   This falsified the original H1 as a general fix: appending `0002` breaks Git
   clients with:

   ```text
   fatal: remote-curl: unexpected response end packet
   fatal: expected flush after ref listing
   ```

2. `zig fetch --save git+https://pb.yafb.net/lscolors` still fails with:

   ```text
   error: unable to iterate refs: EndOfStream
   ```

3. The v2 advertisement handshake over HTTPS is correct:

   - `GET /lscolors/info/refs?service=git-upload-pack`
   - `HTTP/2 200`
   - body includes `version 2`, `ls-refs=unborn`, `fetch=shallow wait-for-done`

4. The same `ls-refs` POST behaves differently depending on where it is
   executed:

   - Through the public HTTPS endpoint:

     - `POST https://pb.yafb.net/lscolors/git-upload-pack`
     - `HTTP/2 200`
     - `Content-Length: 0`
     - empty body

   - Directly against the internal `packbase` service from inside the remote
     Docker network:

     - `POST http://packbase:8080/lscolors/git-upload-pack`
     - `HTTP/1.1 200`
     - `Content-Length: 241`
     - body contains the expected `ls-refs` pkt-line payload

This is the strongest piece of evidence collected so far. The backend produces
the correct body, but the public path sometimes turns it into an empty `200`
response before it reaches Zig.

## Actual root cause (identified April 15, 2026)

The bug is **not** in Caddy. It is in `src/main.zig`.

`handleConnection` read the incoming TCP stream with a single `read()` call:

```zig
const bytes_read = try connection.stream.read(buffer);
const raw = buffer[0..bytes_read];
```

A single `read()` is not guaranteed to return the full HTTP message. Caddy,
acting as an HTTP/2→HTTP/1.1 reverse proxy, sends the request headers in one
TCP segment and the request body in a second segment. The single `read()` only
captures the headers; `findBody` returns an empty slice; `git upload-pack
--stateless-rpc` receives empty stdin and exits cleanly with zero output.
`packbase` then responds with `Content-Length: 0` and an empty body. Zig's git
client waits for the expected pkt-line refs data, receives nothing, and reports
`EndOfStream`.

This explains all observed symptoms:

- `curl` with `--data-binary` sometimes works because curl may coalesce headers
  and body into one segment, but not reliably through an HTTP/2 proxy.
- `git ls-remote` tolerates or retries around empty responses; Zig does not.
- The internal direct test against `packbase:8080` (HTTP/1.1, no proxy) worked
  because without an HTTP/2→HTTP/1.1 translation the body arrived in the first
  segment.

### Why Caddy appeared to be the culprit

The `Content-Length: 0` response was visible at the Caddy layer, so the proxy
was blamed. The other Caddy fixes (`@git_short` matcher, `flush_interval -1`,
HTTP/1.1 transport, `make update` recreating caddy) were all valid hygiene
improvements but did not address the underlying single-read bug.

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

## Resolution

### What actually fixed it

1. Fixed the single-read bug in `src/main.zig` `handleConnection`.
   The server now reads in a loop until the full HTTP headers are received
   (delimited by `\r\n\r\n`), then continues reading until `Content-Length`
   bytes of body are accumulated. This ensures `git upload-pack --stateless-rpc`
   always receives the complete pkt-line request body.

2. Removed the incorrect trailing `0002` response-end packet from the v2
   `git-upload-pack` command response. That packet was breaking standard Git
   clients and was not the right fix for Zig.

3. Added explicit Smart HTTP proxy matching for the short pseudo-Git URL form
   (`/name/info/refs`, `/name/git-upload-pack`, `/name/git-receive-pack`) in
   the Caddyfile, with `flush_interval -1`, HTTP/1.1 transport, and keepalive
   off for the Smart HTTP block.

4. Updated `make update` / deployment flow so that `caddy` is recreated too,
   not only `packbase`.

### Verified live after the fix

- `curl -H 'Git-Protocol: version=2' https://pb.yafb.net/lscolors/info/refs?service=git-upload-pack` → OK
- `git ls-remote https://pb.yafb.net/lscolors` → OK
- `zig fetch --save git+https://pb.yafb.net/lscolors` → OK

## Follow-up

While resolving this issue, a separate stability problem was observed in the
backend logs: intermittent `packbase` panics resulting in connection resets seen
by Caddy as `502`.

That concern is tracked separately in:

- `docs/issues/04-packbase-crashes-under-proxy-load.md`

## Status

- [x] Server correctly implements git protocol v2 (GIT_PROTOCOL=version=2 env var)
- [x] GET /info/refs v2 response verified correct
- [x] POST ls-refs response verified correct via curl
- [x] Root cause of Zig-specific EndOfStream identified (single TCP read in handleConnection)
- [x] Fix implemented and verified live with `zig fetch --save git+https://pb.yafb.net/lscolors`
