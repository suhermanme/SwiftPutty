# M14 DNS blocking measurement

`name_lookup` reaches `getaddrinfo` synchronously on the single PuTTY core
thread (`Vendor/putty/unix/network.c:187–231`). Raw, SSH, Telnet, Rlogin,
SUPDUP, and forwarding setup call this path from their backend setup paths.
A blocked resolver therefore prevents the event loop from servicing every
session; moving this safely requires changing the synchronous upstream lookup
contract and its backend callers, not just relocating one call.

The focused `spb_dns_blocking_measurement` harness interposes only the resolver
call for a sentinel hostname. It first establishes a loopback echo session,
then holds a second session in lookup while sending a probe through the active
session. It waits 250 ms for progress before releasing the resolver and reports
the resolver hold, lookup-entry-to-output, and send-to-output latencies. This
removes DNS-server variability while measuring the shared-thread consequence
of a controlled resolver stall. A successful reproduction exits 0 when the
second session makes no progress during the hold; unexpected progress exits 1.

**Decision:** do not introduce asynchronous resolution in M14 without a
measured user-visible stall duration. It is a cross-backend semantic/API change.
The deterministic harness is designed to reproduce the shared-thread stall
without lossy output and to supply repeatable latency measurements. The source
establishes the synchronous blocking mechanism, but the harness has not yet
been executed; no empirical latency result is claimed here. This is a
provisional no-change decision, not an assertion that DNS latency is harmless.

After a normal core CMake configuration, build and run only the measurement:

```sh
cmake --build build/core-arm64 --target spb_dns_blocking_measurement
build/core-arm64/spb_dns_blocking_measurement
```

Repeat on the supported host architecture if comparing platform behavior.
The reported harness-controlled hold is at least 250 ms; measured resolver to
probe-output latency should be compared with that hold to verify event-loop
stalling. The harness does not claim to characterize public DNS latency.
