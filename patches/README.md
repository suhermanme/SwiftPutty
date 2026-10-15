# Local patches to PuTTY

`scripts/prepare-putty-src.sh` copies `Vendor/putty/` to
`build/putty-src/` and applies every `*.patch` here in name order with
`patch -p1`. It fails if any patch does not apply cleanly.
`Vendor/putty/` itself is never modified.

Each patch:

- is a unified diff relative to the PuTTY source root (`a/…`, `b/…`);
- starts with a header naming the upstream version it was made against,
  its purpose, and its upstream status;
- is listed in `docs/UPSTREAM_PUTTY.md` and `THIRD_PARTY_NOTICES.md`.

| Patch | Purpose | Upstream status |
|---|---|---|
| `0001-arm-arch-queries-sysctl-fallthrough.patch` | `test_sysctl_flag()` returned an indeterminate value when `sysctlbyname()` failed on macOS | Not yet reported; suitable for upstream |
| `0002-pollwrap-hup-wakes-writers.patch` | A refused non-blocking `connect()` (`POLLHUP` only on macOS) was never dispatched, so the poll loop spun forever | Not yet reported; suitable for upstream |
| `0003-network-free-connect-error-message.patch` | The error text of each failed asynchronous `connect()` leaked | Not yet reported; suitable for upstream |
| `0004-terminal-free-last-selected-text.patch` | `term_free()` leaked the last selected text kept for local paste | Not yet reported; suitable for upstream |
| `0005-ssh-bpp-free-clears-queues.patch` | `ssh_bpp_free()` leaked packets still queued when a session closed | Not yet reported; suitable for upstream |
| `0006-portfwd-status-hook.patch` | Structured port forwarding status for front ends (optional `LogPolicy` method) | SwiftPutty-specific; could be offered |
| `0007-rportfwd-cancel-pending-reply.patch` | Use after free when a remote forwarding is removed before the server answers (H-1); leaked outstanding global requests at teardown | Not yet reported; should be (memory safety) |
| `0008-portfwd-duplicate-rportfwd-free.patch` | Use after free after a duplicate remote forwarding (H-2) | Not yet reported; should be (memory safety) |
