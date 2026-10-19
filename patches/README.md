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
| `0009-rlogin-free-username-prompt.patch` | The Rlogin user name prompt leaked once answered | Not yet reported; suitable for upstream |
| `0010-http-proxy-blank-line-completes-headers.patch` | An HTTP proxy's response was not complete until a byte after it arrived: a body-less 407 stalled, and a 200 hung client-first protocols | Not yet reported; should be |
| `0011-proxy-socket-free-conf.patch` | Each proxied connection leaked its copy of the Conf | Not yet reported; suitable for upstream |
| `0012-proxy-command-format-once.patch` | Telnet and local proxies formatted their command twice when no prompt was needed, leaking the first (which can hold the proxy password) | Not yet reported; suitable for upstream |
| `0013-proxy-negotiator-init-reconnect.patch` | The proxy negotiator's `reconnect` flag was never initialised, so a proxied connection could reconnect to the proxy at random | Not yet reported; should be |
| `0014-preconnect-blank-credentials-in-copy.patch` | The pre-connect command blanked the proxy credentials in the session's Conf, not its copy: `%pass` expanded to the password (Event Log too) and the proxy lost its credentials | Not yet reported; should be (password exposure) |
| `0015-local-command-posix-spawn-and-reap.patch` | Local commands were forked in a multithreaded process, inherited stray descriptors, and (proxy command, auth plugin) were never reaped | Not yet reported; suitable for upstream |
| `0016-settings-malformed-colour-uses-default.patch` | A saved colour that was not "r,g,b" left the colour unset; the next use aborted | Not yet reported; should be (a damaged session aborts) |
| `0017-eddsa-decode-checks-point-length.patch` | A too-short Ed25519/Ed448 point failed an assertion while decoding a public key, e.g. a server's host key before verification | Not yet reported; should be **privately** (a server can abort the client) |
| `0018-settings-out-of-range-enums-load-as-default.patch` | `BugHMAC2` out of range, or unknown `ProxyMethod` and `ProxyType`, gave an unmapped or uninitialised value; saving aborted | Not yet reported; should be (a damaged session aborts) |
| `0019-terminal-negative-scrollback-is-none.patch` | A negative "Lines of scrollback" failed an assertion in `term_size()` | Not yet reported; should be (a setting aborts) |
| `0020-clipme-combining-chars-use-base-style.patch` | Copying a combining character read the never-written attributes and colour of its spare cell | Not yet reported; suitable for upstream (undefined behaviour) |
| `0021-gss-macos-library-names.patch` | The GSSAPI loader looked only for `.so` libraries; on macOS it now loads `GSS.framework` and `libgssapi_krb5.dylib` | Not yet reported; could be offered (macOS support) |
| `0022-fd-socket-no-sigpipe.patch` | Writing to a local command that had exited raised SIGPIPE and ended the whole process | Not yet reported; suitable for upstream |
| `0023-gssapi-free-userauth-mic.patch` | Each GSSAPI login leaked the MIC buffer from `get_mic()` | Not yet reported; suitable for upstream |
| `0024-macos-intel-gssapi-abi-packing.patch` | Match Apple's 2-byte packed GSSAPI types for dynamic GSSAPI on Intel macOS; prevents the OID layout mismatch that crashed in `GSS.framework` | Not yet reported; suitable for upstream |
