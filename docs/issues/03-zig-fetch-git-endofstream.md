# Issue 03 — `zig fetch git+https://…` fails with `EndOfStream` during ls-refs

Status: completed on April 15, 2026 in release `r0012`

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

## Why Caddy is now the main suspect

These are the concrete reasons collected during the live investigation:

1. The backend and the public endpoint disagree on the same request.
   If `packbase:8080` returns `241` bytes and `https://pb.yafb.net/...` returns
   `0`, the corruption is happening after `packbase` generated the response.

2. The failure appears specifically on the stateless Smart HTTP command POST,
   not on the advertisement GET.
   `info/refs` is consistently correct, while `git-upload-pack` `ls-refs` is
   where the empty-body behaviour appears.

3. The failing public path is served over HTTP/2, while the internal service is
   plain HTTP/1.1.
   This keeps pointing to an interaction in the proxy layer between:

   - HTTP/2 stream termination
   - upstream buffering/flush timing
   - upstream `Content-Length`
   - the client's expectation while parsing pkt-line responses

4. Zig is stricter than `git` and `curl`.
   `git ls-remote` may recover or tolerate cases that Zig's own HTTP/git client
   treats as EOF during ref iteration. That fits the observed symptom:
   Git works, Zig still fails.

5. The short pseudo-Git URL path `/lscolors/git-upload-pack` was originally not
   handled by the dedicated Caddy matcher.
   That means Smart HTTP requests for the short URL could go through the generic
   `reverse_proxy` path rather than a Git-specific one, making proxy behaviour
   inconsistent across URLs.

6. Recreating only `packbase` was insufficient for Caddy-related debugging.
   Earlier deploys were rebuilding and restarting only the application
   container, while `caddy` kept running with the old proxy config. This made
   proxy-layer fixes impossible to validate reliably until `make update` was
   changed to recreate `caddy` too.

## Current proxy-oriented working theory

The best current theory is:

- `packbase` generates a correct `ls-refs` body
- Caddy, on the public HTTPS Smart HTTP path, sometimes buffers or terminates
  the proxied response in a way that turns the upstream body into an empty
  `200 OK`
- Zig then waits for pkt-line data that never arrives and reports
  `EndOfStream`

This is why the current remediation effort focuses on the proxy layer:

- explicit Smart HTTP path matching in `Caddyfile`
- `flush_interval -1`
- forcing a cleaner upstream HTTP transport for Smart HTTP requests
- recreating `caddy` on deploy so config changes actually take effect

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

## Resolution

The issue was resolved through a combination of fixes applied and verified live
on `pb.yafb.net`.

### What actually fixed it

1. Removed the incorrect trailing `0002` response-end packet from the v2
   `git-upload-pack` command response.
   That packet was breaking standard Git clients and was not the right fix for
   Zig.

2. Added explicit Smart HTTP proxy matching for the short pseudo-Git URL form:

   - `/name/info/refs`
   - `/name/git-upload-pack`
   - `/name/git-receive-pack`

3. Forced a more stable proxy path for Smart HTTP in Caddy:

   - `flush_interval -1`
   - upstream transport pinned to HTTP/1.1
   - upstream keepalive disabled for the Smart HTTP block

4. Updated `make update` / deployment flow so that `caddy` is recreated too,
   not only `packbase`, ensuring proxy config changes actually reach production.

5. Fixed a server bug in `src/main.zig` where accepted connections were closed
   with `defer` inside the main `while (true)` loop, causing connection cleanup
   to be delayed until process exit instead of end-of-request.

### Verified live after the fix

- `curl -H 'Git-Protocol: version=2' https://pb.yafb.net/lscolors/info/refs?service=git-upload-pack` → OK
- `git ls-remote https://pb.yafb.net/lscolors` → OK
- `zig fetch --save git+https://pb.yafb.net/lscolors` → OK

Example successful live result:

```text
info: resolved to commit 4ee1068def0da4bb91147c318b524ce9e357a24e
```

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
- [x] Root cause of Zig-specific EndOfStream identified
- [x] Fix implemented and verified live with `zig fetch --save git+https://pb.yafb.net/lscolors`
