# Third-Party Notices

SwiftPutty is an independent project. It is **not** an official PuTTY
product and is not affiliated with or endorsed by the PuTTY developers.

## PuTTY

- **Component:** PuTTY portable core (SSH, cryptography, terminal emulator,
  port forwarding, proxies, settings) and Unix platform layer
- **Version:** 0.85 (git tag `0.85`, commit
  `a3cce3a48d4ab12e0fccb32998b9042d4f7c3ff1`)
- **Source:** https://the.earth.li/~sgtatham/putty/0.85/putty-0.85.tar.gz
  (SHA-256 `13fd4db2936d03b73812a7bcc2a658e4dd29cc776a56c3670a7fc6f1a0ee8af8`);
  project page https://www.chiark.greenend.org.uk/~sgtatham/putty/
- **Location in this repository:** `Vendor/putty/`
- **Licence:** MIT. The full text is in `Vendor/putty/LICENCE` and is
  reproduced below.
- **Local modifications:** applied at build time from `patches/` (the
  vendored tree is unmodified). Details in `docs/UPSTREAM_PUTTY.md`:
  - `0001-arm-arch-queries-sysctl-fallthrough.patch`: return a defined
    value from `test_sysctl_flag()` when `sysctlbyname()` fails.
  - `0002-pollwrap-hup-wakes-writers.patch`: treat `POLLHUP` as
    writable, so a refused connection is reported on macOS.
  - `0003-network-free-connect-error-message.patch`: free the error text
    of a failed asynchronous connection attempt.
  - `0004-terminal-free-last-selected-text.patch`: free the terminal's
    last-selected-text buffers when the terminal is freed.
  - `0005-ssh-bpp-free-clears-queues.patch`: free packets still queued
    when an SSH connection is torn down.
  - `0006-portfwd-status-hook.patch`: report the state of each configured
    port forwarding to the front end.
  - `0007-rportfwd-cancel-pending-reply.patch`: fix a use after free when
    a remote port forwarding is removed before the server has answered;
    free unanswered global requests at teardown.
  - `0008-portfwd-duplicate-rportfwd-free.patch`: fix a use after free
    after a duplicate remote port forwarding.
  - `0009-rlogin-free-username-prompt.patch`: free the Rlogin user name
    prompt once it has been answered.
  - `0010-http-proxy-blank-line-completes-headers.patch`: an HTTP proxy's
    response headers end at their blank line, without waiting for more.
  - `0011-proxy-socket-free-conf.patch`: free a proxied connection's copy
    of the configuration when it closes.
  - `0012-proxy-command-format-once.patch`: format the Telnet or local
    proxy command a second time only after prompting for it.
  - `0013-proxy-negotiator-init-reconnect.patch`: initialise the proxy
    negotiator's reconnect flag.
  - `0014-preconnect-blank-credentials-in-copy.patch`: keep the proxy
    credentials out of the pre-connect command, and in the session.
  - `0015-local-command-posix-spawn-and-reap.patch`: start local commands
    with posix_spawn, with only their own pipes, and always reap them.
  - `0016-settings-malformed-colour-uses-default.patch`: a saved colour
    that cannot be read loads as its default.
  - `0017-eddsa-decode-checks-point-length.patch`: reject EdDSA public keys
    whose point has the wrong length.
  - `0018-settings-out-of-range-enums-load-as-default.patch`: unknown saved
    values of two settings load as their defaults.
  - `0019-terminal-negative-scrollback-is-none.patch`: a negative scrollback
    size means no scrollback.
  - `0020-clipme-combining-chars-use-base-style.patch`: copied combining
    characters take their base character's attributes and colour.
  - `0021-gss-macos-library-names.patch`: load macOS's own GSSAPI
    libraries.
  - `0022-fd-socket-no-sigpipe.patch`: writing to a local command that has
    exited reports an error instead of raising SIGPIPE.
  - At link time, `unix/utils/subprocess_waiter.c` is replaced by
    SwiftPutty's own waiter, which installs no signal handler.
  - At compile time, `OSX_META_KEY_CONFIG` is defined for `settings.c`, as
    upstream's OS X build does, so the Meta-key settings are saved.
  - At compile time (no source change), the session-storage functions of
    `unix/storage.c` are renamed, so that SwiftPutty can supply its own
    session storage.

```
PuTTY is copyright 1997-2026 Simon Tatham.

Portions copyright Robert de Bath, Joris van Rantwijk, Delian
Delchev, Andreas Schultz, Jeroen Massar, Wez Furlong, Nicolas Barry,
Justin Bradford, Ben Harris, Malcolm Smith, Ahmad Khalifa, Markus
Kuhn, Colin Watson, Christopher Staite, Lorenz Diener, Christian
Brabandt, Jeff Smith, Pavel Kryukov, Maxim Kuznetsov, Svyatoslav
Kuzmich, Nico Williams, Viktor Dukhovni, Josh Dersch, Lars Brinkhoff,
and CORE SDI S.A.

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation files
(the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of the Software,
and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT.  IN NO EVENT SHALL THE COPYRIGHT HOLDERS BE LIABLE
FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

The vendored tree also contains third-party code that PuTTY itself
incorporates. It is covered by the notices inside `Vendor/putty/`, which
are retained unmodified.
