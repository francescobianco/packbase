# Issue 04 — `packbase` intermittently panics under proxy traffic, causing `502`

## Summary

During the live investigation and rollout for issue 03, the service showed a
separate stability problem:

- `packbase` occasionally panicked while serving requests
- Caddy then reported upstream failures such as:

```text
read tcp ...: read: connection reset by peer
```

- public clients observed `502` responses on routes such as:

  - `/api/info`
  - `/lscolors/info/refs?service=git-upload-pack`

This is not the same problem as the Zig `EndOfStream` bug. Issue 03 was
resolved in release `r0012`, but these backend panics still deserve an
independent investigation.

## Evidence collected live

### Caddy logs

Observed in production:

```text
read tcp 172.18.0.3:...->172.18.0.2:8080: read: connection reset by peer
```

with `502` returned to public clients.

### packbase logs

Observed in production:

```text
thread 1 panic: reached unreachable code
/opt/zig/lib/std/mem/Allocator.zig:426:9: 0x103c80b in handleConnection (packbase)
/src/src/main.zig:31:29: 0x103d591 in main (packbase)
```

The panic appeared while the service was under real HTTPS traffic routed
through Caddy.

## What was already fixed nearby

One concrete bug was fixed while investigating this:

- accepted connections in the main server loop were previously closed with
  `defer` directly inside `while (true)`, delaying connection cleanup until
  process exit instead of request completion

That fix shipped in `r0012`, and it stabilized the issue 03 path enough for
`zig fetch` to succeed. However, this issue remains open until we prove that the
backend no longer emits allocator panics under load or malformed traffic.

## Suspected areas

1. Request-lifetime memory ownership in `handleConnection`
2. Request parsing and path routing on malformed or partial HTTP traffic
3. Interactions between allocator-backed buffers and slices retained across
   request handling
4. Error paths that may double-free or free memory not owned by the allocator

## Next steps

1. Reproduce the panic locally against the current codebase
2. Add tracing around `handleConnection` and request routing
3. Identify the exact allocator assertion being violated
4. Add a regression test or load-style probe once the crash path is isolated

## Status

- [x] Panic observed live
- [x] Related connection-lifetime bug fixed in `r0012`
- [ ] Root cause isolated
- [ ] Regression test added
- [ ] Stability verified after fix
