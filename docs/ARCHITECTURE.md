# SwiftPutty — Architecture

Status: **M00 (analysis) — proposed architecture.** Nothing described in
"Proposed" sections exists in code yet.

All upstream references are to **PuTTY 0.85** (git tag `0.85`, commit
`a3cce3a48d4ab12e0fccb32998b9042d4f7c3ff1`) as vendored in
`Vendor/putty/`. Paths below are relative to `Vendor/putty/`; line numbers
are those of the pristine 0.85 tree.

---

## 1. The key question, answered

> How does PuTTY 0.85 reconfigure an already-running SSH session —
> specifically adding/removing/replacing local, remote, and dynamic port
> forwards — and what is the smallest stable bridge that lets the macOS
> frontend invoke the same behaviour without reconnecting?

**Short answer.** The frontend copies the session's `Conf`, lets the user
edit the copy, and then hands the whole new `Conf` to the running backend with
a single call: `backend_reconfig(backend, conf)`. Nothing is diffed in the
frontend. Each layer of the SSH stack diffs the new `Conf` against its own
saved copy. For forwarding, the diff is done by `portfwdmgr_config()` in
`ssh/portfwd.c`. It marks every existing forwarding record `DESTROY`, re-marks
those still present in the new `CONF_portfwd` map as `KEEP`, and marks new
entries `CREATE`. It then tears down the `DESTROY` records and sets up the
`CREATE` ones, in that order and on the same SSH connection:

- **Local and dynamic forwards** are listening sockets owned by the manager
  (`pfl_listen` / `pfl_terminate`).
- **Remote forwards** use SSH-2 `tcpip-forward` and `cancel-tcpip-forward`
  global requests, sent through the existing connection layer
  (`ssh2_rportfwd_alloc` / `ssh2_rportfwd_remove`).

No reconnect happens anywhere on this path.

**The bridge therefore needs exactly one reconfiguration entry point:**
"replace the running session's `Conf` with this one", executed on the PuTTY
core thread. It runs the same sequence the Windows and GTK frontends run
(`log_reconfig` → `ldisc_configure` → `term_reconfig` → `backend_reconfig`).
The Swift side never sends add/remove-tunnel commands to C. It produces a
complete new configuration. A Swift-side `SessionConfigurationDiff` is used
for UI classification and for *staging* (§6.4), not as a C API.

PuTTY reports forwarding outcomes only as Event Log text. A frontend that
wants a structured "this tunnel is up / failed / refused" state therefore
needs one small upstream patch: a status-notification hook (§7.3, patch
`0006`). Two latent upstream memory-safety bugs on the remote-forward
removal path (§5.6) also need fixing, both in SwiftPutty's patch set and,
ideally, upstream.

---

## 2. Upstream structure (0.85)

### 2.1 Portable core vs. platform code

| Area | Upstream location | Reuse in SwiftPutty |
|---|---|---|
| SSH protocol (transport, userauth, connection, channels, sharing, X11, agent fwd) | `ssh/*.c`, `ssh.h` | **Reuse unchanged** (plus §7 patches) |
| Port forwarding manager | `ssh/portfwd.c` | **Reuse** (patched: status hook, dup-record fix) |
| Crypto (ciphers, MACs, kex, keys, mpint) | `crypto/` | **Reuse unchanged** |
| Key files (PPK, OpenSSH import) | `sshpubk.c`, `import.c` | Reuse |
| Proxies (HTTP, SOCKS4/5, telnet, local cmd, SSH jump) | `proxy/` | Reuse |
| Terminal emulator | `terminal/terminal.c`, `terminal/bidi.c`, `terminal/lineedit.c` | **Reuse unchanged** |
| Line discipline | `ldisc.c` | Reuse |
| Config model | `conf.h` (master key list), `utils/conf.c`, `conf-enums.h` | Reuse |
| Save/load mapping (keyword ⇄ Conf) | `settings.c` (`load_open_settings`, `save_open_settings`) | Reuse, over our own storage backend |
| Event loop primitives | `callback.c` (toplevel callbacks), `timing.c` (timers) | Reuse |
| Event Log | `logging.c` | Reuse |
| Keepalives | `pinger.c` | Reuse |
| Other backends | `otherbackends/` (raw, telnet, rlogin, supdup) | Reuse (M11) |
| Character sets | `charset/` | Reuse |
| Portable dialog *description* | `config.c`, `dialog.c` | **Reference only.** Used to derive panel layout and mid-session rules; not linked into the UI |
| Windows frontend | `windows/*` | **Not used.** Behavioural reference |
| Unix non-GTK platform layer | `unix/uxsel.c`, `unix/network.c`, `unix/fd-socket.c`, `unix/agent-socket.c`, `unix/agent-client.c`, `unix/peerinfo.c`, `unix/local-proxy.c`, `unix/x11.c`, `unix/noise.c`, `unix/gss.c`, `unix/sharing.c`, `unix/serial.c`, `unix/unicode.c`, `unix/utils/*` | **Reuse.** This is the POSIX layer macOS needs |
| Unix GTK frontend | `unix/window.c`, `unix/gtk-*.c`, `unix/unifont.c`, `unix/config-gtk.c`, `unix/dialog.c`, `unix/main-gtk-*.c`, `unix/columns.c` | **Not used.** Replaced by the Swift frontend; reference for the Unix-side frontend contract |
| Unix CLI loop | `unix/cliloop.c` | Not linked. Our core-thread loop is modelled on it (§4) |
| Unix storage | `unix/storage.c` (writes `~/.putty`) | **Split** (D-011): reused unmodified for host keys, host CAs and the random seed, redirected to the app's state directory via `$PUTTYDIR`; its session functions are renamed away at compile time and the bridge supplies in-memory session settings (§2.4) |

**Feasibility (verified in M00):** the unmodified 0.85 tree configures and
builds its GTK-free targets (`plink`, `testcrypt`) on this machine with
Xcode 26.6 / Apple clang 21. That includes a universal arm64+x86_64 binary
(`plink -V` → `Release 0.85`). See D-006 for why the product build must
configure each architecture separately.

### 2.2 The frontend contract (what a frontend must implement)

PuTTY talks to a frontend through vtables declared in `putty.h`:

| Interface | Declared | Purpose | SwiftPutty implementer |
|---|---|---|---|
| `Seat` / `SeatVtable` | `putty.h:1085` | Session-level I/O to the user: `output`, `eof`, `get_userpass_input`, `confirm_ssh_host_key`, `confirm_weak_crypto_primitive`, `confirm_weak_cached_hostkey`, `notify_remote_exit`, `notify_remote_disconnect`, `connection_fatal`, `nonfatal`, `update_specials_menu`, `set_trust_status`, `banner`, `get_ttymode`, … | Bridge C (`spb_seat.c`), forwarding to Swift callbacks |
| `TermWin` / `TermWinVtable` | `putty.h:1606` | The terminal's drawing/window surface: `setup_draw_ctx`, `draw_text`, `draw_cursor`, `char_width`, `set_title`, `bell`, `clip_write`, `clip_request_paste`, `request_resize`, `palette_set`, `set_scrollbar`, `set_raw_mouse_mode`, … | Bridge C (`spb_termwin.c`), recording into a frame buffer (§8) |
| `LogPolicy` / `LogPolicyVtable` | `putty.h` | Event Log sink: `eventlog`, `askappend`, `logging_error`, `verbose` | Bridge C, forwarding to Swift |
| `Backend` / `BackendVtable` | `putty.h:696` | The connection. Frontend calls `init`, `free`, `reconfig`, `send`, `size`, `special`, `get_specials`, `cfg_info`, … | Provided by PuTTY (`ssh_backend` etc.) |
| Platform hooks (free functions) | `unix/platform.h`, `putty.h`, `storage.h` | `uxsel_input_add`/`uxsel_input_remove`, `timer_change_notify`, `request_callback_notifications` target, `platform_default_*`, storage functions, `frontend_net_error_pending`, … | Bridge C |

### 2.3 Session object graph (as created by a PuTTY frontend)

```
frontend (Windows: WinGuiSeat in windows/window.c; GTK: GtkFrontend in unix/window.c)
 ├─ Conf *conf                 ← the CURRENT runtime config (single owner)
 ├─ Terminal *term             ← term_init(conf, ucsdata, &termwin)
 ├─ LogContext *logctx         ← log_init(&logpolicy, conf)
 ├─ Backend *backend           ← backend_init(vt, seat, &backend, logctx, conf, host, port, &realhost, nodelay, keepalive)
 └─ Ldisc *ldisc               ← ldisc_create(conf, term, backend, seat)
```

### 2.4 Configuration representation

- `Conf` (`utils/conf.c`) is an opaque, typed key/value store. Every primary
  key is declared once in **`conf.h`** with `CONF_OPTION(...)`: value type,
  optional subkey type, default, `SAVE_KEYWORD`, storage enum, and custom/
  not-saved flags. 0.85 has 211 primary keys. `conf_key_info[]` exposes this
  metadata at runtime.
- Persistence keywords (`SAVE_KEYWORD("HostName")` etc.) are what
  `settings.c:save_open_settings()` / `load_open_settings()` read and write
  through the abstract `storage.h` API (`open_settings_r/w`,
  `read_setting_s/i/filename/fontspec`, …).
- Port forwards are the mapping key `CONF_portfwd` (`conf.h:1131`):
  subkey `[46]?[LR](addr:)?port`, value `host:port`, or the literal `D` for
  dynamic (stored as an **L** key with value `D`). Saved as the single
  keyword `PortForwardings` (`settings.c:689`, `settings.c:1041`).
- Two related booleans: `CONF_lport_acceptall` ("Local ports accept
  connections from other hosts") and `CONF_rport_acceptall` ("Remote ports
  do the same").

**Consequence for SwiftPutty (D-004, D-011):** SwiftPutty does **not**
hand-write a Conf ⇄ Swift converter for 211 keys. The bridge implements
`storage.h`'s `settings_r` / `settings_w` over an in-memory keyword map
(`Core/src/spb_storage.c`, implemented in M01). Conversion in both
directions then goes through PuTTY's own `load_open_settings` /
`save_open_settings`. That yields upstream-identical defaults, legacy-key
handling, and `PortForwardings` parsing, and it makes PuTTY session import
nearly free (M12).

---

## 3. Runtime reconfiguration: complete call flow

### 3.1 Windows "Change Settings…" (`windows/window.c`)

```
WM_SYSCOMMAND IDM_RECONF                              windows/window.c:2355
  if (wgs->reconfiguring) break;                      ← re-entrancy guard
  term_pre_reconfig(term, conf)                       terminal/terminal.c:1701
        (copies the CURRENT window title — possibly set by the server via
         OSC — into CONF_wintitle, so an untouched title field does not
         reset the title)
  prev_conf = conf_copy(conf)
  do_reconfig(hwnd, conf, backend_cfg_info(backend))  windows/dialog.c:779
        backup = conf_copy(conf)
        setup_config_box(ctrlbox, midsession=true, protocol, protcfginfo)  config.c:1783
        win_setup_config_box(..., midsession=true, ...)                     windows/config.c:44
        modal dialog edits `conf` IN PLACE
        Cancel → conf_copy_into(conf, backup)
  if cancelled: break
  conf_cache_data(wgs)
  log_reconfig(logctx, conf)                          logging.c:405
  ldisc_configure(ldisc, conf); ldisc_echoedit_update(ldisc)   ldisc.c:105
  term_notify_palette_changed(term)  (if system colours toggled)
  term_reconfig(term, conf)                           terminal/terminal.c:1718
  setup_clipboards(...)
  init_palette(wgs)
  backend_reconfig(backend, conf)                     putty.h:768  → be->vt->reconfig
  term_size(...)  (if width/height/savelines/resize mode changed)
  window style / font / reset_window(init_lvl)
```

### 3.2 GTK "Change Settings…" (`unix/window.c`) — same contract, non-modal

```
change_settings_menuitem()                 unix/window.c:4790
  ctx->newconf = conf_copy(inst->conf)     ← dialog edits a COPY
  term_pre_reconfig(term, ctx->newconf)
  create_config_box(title, newconf, midsession=true, backend_cfg_info(backend), after_change_settings_dialog, ctx)
after_change_settings_dialog(ctx, retval)  unix/window.c:4817
  if (retval > 0):
     inst->conf = newconf
     log_reconfig → ldisc_configure/ldisc_echoedit_update → term_reconfig
       → setup_clipboards → backend_reconfig(backend, conf) → fonts/size/redraw
     conf_free(oldconf)
```

The GTK variant is the one SwiftPutty mirrors: an asynchronous sheet that
edits a copy, with an atomic swap on Apply.

### 3.3 `protcfginfo`: what the dialog may show mid-session

`backend_cfg_info()` → `ssh_cfg_info()` (`ssh/ssh.c:1259`) returns `0`
(version not yet known), `1` (SSH-1), `2` (SSH-2) or `-1` (bare
connection-sharing downstream). `config.c:setup_config_box()` hides whole
panels and controls when `midsession` is true, and some further ones based on
`protcfginfo` (§9 and `CONFIGURATION_PARITY.md`). **Connection → SSH →
Tunnels is always shown mid-session for SSH** (`config.c:3088`), together with
both accept-all checkboxes.

### 3.4 Inside the SSH backend

```
backend_reconfig(be, conf)                       putty.h:768
└─ ssh_reconfig(be, conf)                        ssh/ssh.c:1054
   ├─ pinger_reconfig(ssh->pinger, old, new)     pinger.c:59   ← keepalive interval (live)
   ├─ ssh_ppl_reconfigure(ssh->base_layer, conf) ssh/ppl.h:68  ← walks the layer stack
   │   └─ ssh2_transport_reconfigure()           ssh/transport2.c:2436
   │        - rekey timer / data limit (live; may trigger an immediate rekey)
   │        - compression / cipher list / des-cbc changed → mandatory rekey
   │          (deferred if kex in progress)
   │        - stores conf copy (kex/hostkey prefs used at next kex)
   │        └─ ssh_ppl_reconfigure(higher_layer)
   │            └─ ssh2_userauth_reconfigure()   ssh/userauth2-client.c:2596  (pass-through only)
   │                └─ ssh2_connection_reconfigure()   ssh/connection2.c:1752
   │                     conf_free(s->conf); s->conf = conf_copy(conf);
   │                     if (s->portfwdmgr_configured)
   │                         portfwdmgr_config(s->portfwdmgr, s->conf)   ← TUNNELS
   ├─ conf_free(ssh->conf); ssh->conf = conf_copy(conf)
   └─ ssh_cache_conf_values(ssh)                 ssh/ssh.c:927
```

Notes:

- If Apply happens **before** the connection layer has started forwarding
  (during kex or auth), `portfwdmgr_configured` is false. The new conf is
  simply stored, and the initial `portfwdmgr_config()` call at
  `ssh/connection2.c:1028` uses it once the connection layer starts. So early
  edits are not lost.
- If no base layer exists yet (still resolving/connecting/proxying), only
  `ssh->conf` is replaced (`ssh/ssh.c:1061`).
- SSH-1 has the same shape (`ssh/connection1.c:802`).

---

## 4. Event, socket, timer and callback model

All of the following state is **process-global** in upstream:

| Mechanism | File | Global state | Frontend obligation |
|---|---|---|---|
| fd watching | `unix/uxsel.c` | `static tree234 *fds` | Implement `uxsel_input_add(fd, rwx)` / `uxsel_input_remove(id)`; call `select_result(fd, SELECT_R/W/X)` when ready |
| Timers | `timing.c` | `static tree234 *timers`, `now` | Implement `timer_change_notify(next)`; call `run_timers(now, &next)` when due |
| Toplevel callbacks | `callback.c` | `static cbhead/cbtail`, `notify_frontend` | `request_callback_notifications(fn, ctx)`; call `run_toplevel_callbacks()` when notified |
| Random pool, storage, sharing, agent | various | globals | Single-threaded access |

Upstream frontends drive this from one thread: `unix/cliloop.c` with a
`poll()` loop, and `unix/gtk-common.c` with GLib fd watches (lines 70–250).
Neither PuTTY nor its globals are thread-safe.

**Decision D-003:** SwiftPutty runs **one dedicated "PuTTY core thread" for
the whole process**, serving every session. It runs a `poll()` loop modelled
directly on `unix/cliloop.c` (`first_fd`/`next_fd` → `pollwrap` →
`select_result`; `run_timers`; `run_toplevel_callbacks`), plus a self-pipe for
cross-thread wakeups. Every bridge entry point from Swift enqueues a command
and wakes the loop. Every PuTTY → frontend call happens on the core thread
and is forwarded to Swift, which hops to `@MainActor`. This is not a new
network stack. It is upstream's Unix network code (`unix/network.c`,
`unix/fd-socket.c`) driven by upstream's own select abstraction.

*Implemented in M02* (`Core/src/spb_eventloop.c`). The loop body is
`cli_main_loop` from `unix/cliloop.c` with the wake pipe added to the poll
set; each iteration then runs the queued commands, the toplevel callbacks
and a per-session `CONNECTED` check (D-018). Because uxsel and the timer
queue are only touched on the core thread and are rescanned every
iteration, `uxsel_input_add`/`remove` and `timer_change_notify` need no
action, exactly as in cliloop. Running the loop on macOS exposed an
upstream `pollwrap` bug (refused connections spun the loop), fixed by
patch `0002`.

Known consequence: `name_lookup()` (`unix/network.c`, `getaddrinfo`) is
synchronous. A slow DNS lookup in one session stalls all sessions on the core
thread. Windows and GTK PuTTY avoid this by running one *process* per
session. Tracked as risk R-2 (§11). It does not block the main thread.

---

## 5. Port forwarding internals (exact)

### 5.1 Data structures

| Structure | File:line | Role |
|---|---|---|
| `struct PortFwdManager { cl, conf, forwardings }` | `ssh/portfwd.c:737` | Per-connection manager; `forwardings` is a `tree234` of `PortFwdRecord` ordered by `pfr_cmp` |
| `struct PortFwdRecord { status(DESTROY/KEEP/CREATE), type('L'/'R'/'D'), sport, dport, saddr, daddr, sserv, dserv, remote, addressfamily, local }` | `ssh/portfwd.c:683` | One configured forwarding |
| `pfr_cmp` | `ssh/portfwd.c:694` | Identity = (type, addressfamily, saddr, sport, [daddr, dport unless 'D']) |
| `struct PortListener { cl, s, is_dynamic, hostname, port, plug }` | `ssh/portfwd.c:52` | A listening socket (local or dynamic) |
| `struct PortForwarding { c, cl, s, socks_state, hostname, port, socksbuf, plug, chan }` | `ssh/portfwd.c:26` | One **accepted/forwarded TCP stream**, an SSH channel ↔ socket pair |
| `struct ssh_rportfwd { sport, dport, shost, dhost, addressfamily, log_description, share_ctx, pfr }` | `ssh.h:203` | A remote forwarding registered with the connection layer |
| `s->rportfwds` (tree234, `ssh2_rportfwd_cmp` on `(shost, sport)`) | `ssh/connection2.h:35`, `ssh/connection2-client.c:197` | Remote forwards known to the connection layer |
| `struct outstanding_global_request { handler, ctx, next }`, `s->globreq_head/tail` | `ssh/connection2.c:170` | FIFO of pending `want_reply` global requests |
| `ConnectionLayerVtable.rportfwd_alloc / rportfwd_remove / lportfwd_open` | `ssh.h:215` | Interface from `portfwd.c` into the SSH-1/SSH-2 connection layers |

### 5.2 `portfwdmgr_config(mgr, conf)` — the reconciliation algorithm

`ssh/portfwd.c:778`:

1. `mgr->conf = conf_copy(conf)`.
2. Mark every existing record `DESTROY` (`:796`).
3. For each `CONF_portfwd` entry: parse the key (`[A46]?[LR]`, optional
   `addr:`, port or service name via `net_service_lookup`) and the value
   (`host:port` or `D` → type `'D'`). Build a candidate record and
   `add234()` it. If an equal record exists (per `pfr_cmp`), re-tag the
   existing one `KEEP` and free the candidate (`:893`). Otherwise tag it
   `CREATE`.
4. **Destroy pass** (`:914`): for each `DESTROY` record, log `"Cancelling …"`,
   then
   - remote: `ssh_rportfwd_remove(cl, pfr->remote)` (`:950`);
   - local/dynamic: `pfl_terminate(pfr->local)` (`:953`) → `sk_close(listener)`;
   - remove from tree and `pfr_free`.
5. **Create pass** (`:967`): for each `CREATE` record:
   - `'L'`: `pfl_listen(daddr, dport, saddr, sport, cl, conf, &pfr->local, af)`
     → `new_listener(..., local_host_only = !CONF_lport_acceptall, ...)`.
     The event log records `"Local port … forwarding to …"` or `"… failed: <err>"`.
   - `'D'`: `pfl_listen(NULL, -1, ...)` (dynamic listener).
   - `'R'`: `shost = saddr ?: (CONF_rport_acceptall ? "" : "localhost")`;
     `pfr->remote = ssh_rportfwd_alloc(cl, shost, sport, daddr, dport, af, desc, pfr, NULL)` (`:1026`).

So **modify = destroy old + create new, inside one call, destroy first.** The
Windows UI has no Edit button. "Remove" pre-fills the Add fields with the
removed entry (`config.c:1286` `portfwd_handler`), and the user then presses
Add. Both changes are applied by one `portfwdmgr_config` call on Apply.

`KEEP` records are untouched. Changing an unrelated setting (colours, say)
leaves all forwardings alone.

### 5.3 Local forwarding (L)

- **Add:** `pfl_listen` → `new_listener()` (`unix/network.c`). Bind errors
  come back synchronously as a string. They are only logged, and the record
  stays in the tree with `local == NULL`.
- **Accept:** `pfl_accepting()` (`ssh/portfwd.c:508`) creates a
  `PortForwarding` + `Channel` via `portfwd_raw_new`, then `wrap_lportfwd_open`
  → `cl->vt->lportfwd_open` → SSH-2 `direct-tcpip` channel open.
- **Remove:** `pfl_terminate()` (`:610`) closes **only the listening
  socket**. Accepted streams are separate `PortForwarding` objects that hold
  no reference to the `PortListener`, so **established forwarded connections
  survive removal**, and new connections are refused by the OS. This matches
  the project requirement as-is.
- **Failure retry quirk:** a failed listen leaves a record with
  `local == NULL`. On the next Apply it matches `KEEP` and is **not retried**
  until the user removes and re-adds it.

### 5.4 Dynamic forwarding (D)

Same listener path, with `is_dynamic = true`. Per accepted connection,
`pfd_receive` (`ssh/portfwd.c:182`) runs a SOCKS server state machine:
**SOCKS4, SOCKS4A, and SOCKS5 with "no authentication" only**, CONNECT only.
SOCKS5 address types IPv4, IPv6 and hostname are accepted. Once parsed, it
opens a `direct-tcpip` channel. Removal is identical to local (listener only).

### 5.5 Remote forwarding (R) — SSH-2

- **Add:** `ssh2_rportfwd_alloc()` (`ssh/connection2-client.c:231`):
  1. Builds an `ssh_rportfwd`. `add234(s->rportfwds)` keyed on
     `(shost, sport)`. **Returns NULL on a duplicate.**
  2. Sends `SSH2_MSG_GLOBAL_REQUEST "tcpip-forward"`, `want_reply=true`,
     `shost`, `sport`.
  3. `ssh2_queue_global_request_handler(s, ssh2_rportfwd_globreq_response, rpf)`
     (`ssh/connection2.c:175`) appends to the FIFO.
- **Reply:** `ssh2_connection_filter_queue` handles `REQUEST_SUCCESS/FAILURE`
  (`ssh/connection2.c:360`) by popping the FIFO head and calling its handler.
  `ssh2_rportfwd_globreq_response` (`ssh/connection2-client.c:211`):
  - success → log "enabled";
  - failure → log "refused", remove `rpf` from `rportfwds`,
    `portfwdmgr_close(mgr, rpf->pfr)` (drops the manager's record),
    `free_rportfwd(rpf)`.
- **Inbound connection:** `chan_open_forwarded_tcpip` (`:40`) looks up
  `(fwdaddr, fwdport)` in `rportfwds`. If unknown → `ADMINISTRATIVELY_PROHIBITED`.
  Otherwise `portfwdmgr_connect()` (`ssh/portfwd.c:1119`) makes the local TCP
  connection (synchronous `name_lookup`).
- **Remove:** `ssh2_rportfwd_remove()` (`:274`) sends `"cancel-tcpip-forward"`
  with **`want_reply=false`**, removes `rpf` from `rportfwds` immediately and
  frees it. Any further server-initiated opens on that port are rejected
  locally ("Remote port is not recognised"). Existing forwarded-tcpip
  channels are independent channels and survive.
- **Repeated reconfiguration:** a historical crash here ("Fix linked-list
  mismanagement in global request queue", upstream commit `03e71efc`, first
  released in **0.77**) occurred exactly when a remote forward was added via
  Change Settings and then another added later. 0.85 contains the fix
  (`ogr->next = NULL`; `globreq_tail` reset).
- **Re-tries:** because a *refused* remote forward is deleted from the
  manager but remains in `Conf`, **every subsequent Apply re-requests it**
  (asymmetric with local, §5.3).
- **SSH-1:** `ssh1_rportfwd_remove` (`ssh/connection1.c:671`) is a no-op;
  SSH-1 cannot cancel remote forwards. SwiftPutty marks live remote-forward
  removal as *unsupported* on SSH-1 sessions.

### 5.6 Upstream hazards found during M00 (to be fixed by local patches)

Both were found by reading the 0.85 source and **have not yet been reproduced**.
They are still present in upstream `main` as of the M00 check (only const
changes to `portfwd.c` since 0.85). M08 must reproduce each under ASan before
and after the patch.

**H-1. Removing a remote forward whose `tcpip-forward` reply is still
outstanding → use-after-free.** `ssh2_rportfwd_remove` frees `rpf`, but the
`outstanding_global_request` queued in `ssh2_rportfwd_alloc` still holds `rpf`
as its `ctx`. When the server's reply arrives,
`ssh2_rportfwd_globreq_response` dereferences freed memory. On success it
reads `log_description`. On failure it calls `del234(s->rportfwds, rpf)`
(the comparator reads freed `shost`), then `assert`, then
`portfwdmgr_close(rpf->pfr)`.
*Triggers:* Apply that removes or modifies a remote forward within one RTT of
the Apply that added it. This is likely under rapid UI changes, an automated
test loop, or a slow/high-latency server. It is exactly the "repeat
remote-forward changes many times" scenario the project must survive.
*Fix (patch `0007`):* when an `rpf` with a pending reply is removed, mark it
`cancelled` and leave the free to the reply handler. If the reply was
SUCCESS, also send `cancel-tcpip-forward` then (or, if it was already sent,
just free). SwiftPutty additionally serialises remote-forward changes per
port (§6.4) as defence in depth.

**H-2. Duplicate remote listen address → dangling tree entry.** In the create
pass, if `ssh_rportfwd_alloc` returns NULL (another remote forward already
uses the same `(shost, sport)`), `portfwdmgr_config` calls `pfr_free(pfr)`
**without removing it from `mgr->forwardings`** (`ssh/portfwd.c:1031–1034`).
The next `portfwdmgr_config` (any Apply) or `portfwdmgr_free` touches freed
memory. *Trigger:* two configured remote forwards that differ in key but map
to the same server listen address, e.g. `R8080` and `4R8080`, or
`R8080=a:80` alongside a connection-sharing downstream forwarding 8080.
*Fix (patch `0008`):* `del234(mgr->forwardings, pfr)` before `pfr_free`,
mirroring the destroy pass. SwiftPutty validation also rejects such
configurations before Apply.

Both fixes are small, local and suitable for reporting upstream (§UPSTREAM).

---

## 6. SwiftPutty runtime configuration architecture (proposed)

### 6.1 Three configuration states

```
SavedSessionConfiguration     (on disk, versioned Codable, App Support)
        │ launch: copy
        ▼
RuntimeSessionConfiguration   (owned by SessionController; mirrors the C-side Conf)
        │ Change Settings… opens with a fresh export from the RUNNING Conf
        ▼
Edited copy (sheet)  ──Apply──►  SessionConfigurationDiff  ──►  RunningSession.apply(...)
                                                                    │
                                                                    ▼
                                         spb_session_reconfigure(new full settings)
                                                                    │ core thread
                                                                    ▼
                    (term_pre_reconfig already ran at export time)
                    log_reconfig → ldisc_configure → term_reconfig → backend_reconfig
```

- Opening Change Settings calls `spb_session_export_settings()`. On the core
  thread this does `term_pre_reconfig(term, copy)` and then
  `save_open_settings(memwriter, copy)`, so the sheet starts from the **live**
  `Conf` (including earlier runtime Applies and the live window title),
  exactly as in Windows and GTK.
- Apply never touches `SavedSessionConfiguration`. "Save" is a separate,
  explicit action (Windows shows the Save button in the Session panel
  mid-session as "Save the current session settings", `config.c:1905`).

### 6.2 Why the C API is "replace whole config", not "add tunnel"

`portfwdmgr_config` *is* the diff engine. Exposing `add_tunnel` /
`remove_tunnel` in C would either duplicate it (and drift from upstream) or
reach into `PortFwdManager` internals, which the project rules forbid. The
Swift diff exists to:

1. classify each changed field as runtime-applicable / future-connections /
   requires-reconnect / unsupported (§9) and show that in the UI;
2. decide whether staging is needed for tunnel edits (§6.4);
3. produce a human-readable change summary for the Event Log.

### 6.3 Conf round-trip fidelity

Mid-session the sheet only edits keywords that `config.c` exposes
mid-session. Keys the user cannot edit must not be clobbered. That includes
`NOT_SAVED` keys such as `ssh_nc_host` and `ssh_simple`, which
`save_open_settings` does not export. Also, **`load_open_settings` actively
resets every `NOT_SAVED` key to its default** (`settings.c:714–733`), so it
must never be run directly over the running Conf.

The bridge therefore applies changes as an **overlay**, generically over
`conf_key_info[]`:

1. `scratch = conf_new(); load_open_settings(memreader(new_settings), scratch)`
2. `newconf = conf_copy(running)`
3. for every key with `!conf_key_info[k].not_saved`: copy the value
   (or the whole mapping, for subkeyed keys such as `CONF_portfwd`) from
   `scratch` into `newconf`
4. `backend_reconfig(..., newconf)` etc.

M07 verifies that this round-trip is the identity for all 211 keys (R-3).

### 6.4 Tunnel edit staging (make-before-break where possible)

PuTTY applies an edit as destroy-then-create in one call. If the new one
fails, the user ends up with neither. SwiftPutty keeps PuTTY's mechanism but
sequences `reconfigure` calls from Swift:

| Edit | Strategy | Calls |
|---|---|---|
| Different source (bind addr/port) | **Make-before-break** | (1) Conf = old ∪ new → wait for new status (`LISTENING`, or `REMOTE_ENABLED`/`REFUSED`); (2) on success Conf = new (removes old); on failure Conf = old (removes new), surface error |
| Same source port (L/D) | Break-before-make + rollback | (1) Conf = new; (2) if `LISTEN_FAILED`, Conf = old, report "kept previous forwarding" |
| Same source port (R) | Break-before-make (protocol requires cancel before re-request); rollback on `REFUSED` | Same as above, serialised: never issue a change for a port with a pending `tcpip-forward` reply (H-1 defence) |
| Pure add / pure delete | Single call | — |

For Windows-parity purists, a hidden preference can switch staging off
(single-call PuTTY behaviour). It defaults to on.

### 6.5 Structured forwarding status (needs patch `0006`)

Swift needs per-tunnel state: `requested`, `listening`, `failed(msg)`,
`remoteEnabled`, `remoteRefused`, `cancelled`. Upstream only logs text.
Patch `0006` adds an optional `LogPolicyVtable.portfwd_status` method. It is
NULL-checked, so all existing upstream implementers are unaffected through
designated initialisers. Calls are added at the four outcome sites:
`pfl_listen` result in the create pass, `ssh2_rportfwd_globreq_response`
success/failure, the destroy pass, and the duplicate branch. Each record
carries its original `CONF_portfwd` key/value so Swift can map events to
`SSHTunnel.id` exactly. If the patch were ever rejected, the fallback is
parsing the stable Event Log strings in §5; that is documented but not
planned.

---

## 7. Proposed C bridge API (`PuTTYBridge.h`)

Design rules:

- Opaque handles only. Swift never sees `Conf`, `Terminal`, `Backend`,
  `tree234`, or any PuTTY struct.
- All **calls are thread-safe and asynchronous**: they enqueue onto the core
  thread and return immediately. All **callbacks arrive on the core
  thread**. The Swift trampoline copies the data and hops to `@MainActor` /
  `SessionController`. Callback payload pointers are valid only during the
  callback.
- Strings are UTF-8 and NUL-terminated. Integers are fixed-width.
- Every asynchronous request carries a caller-chosen `uint64_t request_id`
  that is echoed in its completion.
- Secrets passed in (`answer_prompt`) are wiped by the bridge after use with
  `smemclr`.
- Prefix `spb_` (SwiftPutty bridge). Versioned via `SPB_API_VERSION`.

```c
/* PuTTYBridge.h — PROPOSED (M00). Not yet implemented. */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define SPB_API_VERSION 1

/* ---------- Library / core thread ---------- */
const char *spb_putty_version(void);                 /* "Release 0.85" */
int         spb_api_version(void);
typedef struct spb_core_options {
    const char *state_dir;      /* App Support dir: host keys, random seed */
} spb_core_options;
bool spb_core_start(const spb_core_options *opts, char **err_out); /* idempotent */
void spb_core_shutdown(void);   /* closes all sessions, joins core thread */
void spb_string_free(char *s);

/* ---------- Settings document (PuTTY save-keyword space) ---------- */
typedef struct spb_settings spb_settings;            /* opaque keyword map */
spb_settings *spb_settings_new_defaults(void);       /* = do_defaults() via load_open_settings on empty map */
spb_settings *spb_settings_copy(const spb_settings *);
void spb_settings_free(spb_settings *);
void spb_settings_set_str(spb_settings *, const char *keyword, const char *value);
void spb_settings_set_int(spb_settings *, const char *keyword, int32_t value);
void spb_settings_remove(spb_settings *, const char *keyword);
/* iterate keyword/value pairs (deterministic, sorted) */
size_t      spb_settings_count(const spb_settings *);
const char *spb_settings_key_at(const spb_settings *, size_t i);
const char *spb_settings_value_at(const spb_settings *, size_t i);
/* validate by round-tripping through load_open_settings/save_open_settings */
bool spb_settings_normalise(spb_settings *, char **err_out);

/* ---------- Session ---------- */
typedef struct spb_session spb_session;              /* opaque */
typedef uint64_t spb_request_id;

typedef enum { SPB_STATE_CREATED, SPB_STATE_CONNECTING, SPB_STATE_AUTHENTICATING,
               SPB_STATE_CONNECTED, SPB_STATE_CLOSED, SPB_STATE_FAILED } spb_state;

typedef enum { SPB_PF_REQUESTED, SPB_PF_LISTENING, SPB_PF_LISTEN_FAILED,
               SPB_PF_REMOTE_ENABLED, SPB_PF_REMOTE_REFUSED,
               SPB_PF_CANCELLED, SPB_PF_DUPLICATE } spb_portfwd_state;

typedef struct spb_portfwd_status {
    const char *conf_key;      /* e.g. "L5432", "4R0.0.0.0:8080" (PuTTY CONF_portfwd subkey) */
    const char *conf_value;    /* e.g. "10.0.0.15:5432" or "D" */
    spb_portfwd_state state;
    const char *message;       /* error text or NULL */
} spb_portfwd_status;

typedef enum { SPB_HOSTKEY_UNKNOWN, SPB_HOSTKEY_CHANGED } spb_hostkey_kind;
typedef struct spb_hostkey_prompt {
    spb_hostkey_kind kind;
    const char *host; int32_t port;
    const char *keytype;                 /* e.g. "ssh-ed25519" */
    const char *fingerprint_sha256;
    const char *fingerprint_md5;
    const char *const *text_lines;       /* PuTTY's SeatDialogText, flattened */
    size_t n_text_lines;
} spb_hostkey_prompt;
typedef enum { SPB_HOSTKEY_REJECT, SPB_HOSTKEY_ACCEPT_ONCE, SPB_HOSTKEY_ACCEPT_AND_STORE } spb_hostkey_answer;

typedef struct spb_prompt_item { const char *text; bool echo; } spb_prompt_item;
typedef struct spb_userpass_prompt {
    const char *name, *instruction;
    const spb_prompt_item *items; size_t n_items;
} spb_userpass_prompt;

/* Terminal frame: a coalesced snapshot of changed rows (see §8). */
typedef struct spb_frame spb_frame;          /* opaque; accessors below */

typedef struct spb_callbacks {
    void (*state_changed)(void *ctx, spb_state, const char *detail);
    void (*event_log)(void *ctx, const char *line);                 /* already secret-free */
    void (*frame_ready)(void *ctx, const spb_frame *frame);         /* coalesced, ≤ 1 per vsync request */
    void (*title_changed)(void *ctx, const char *title, bool icon_title);
    void (*bell)(void *ctx, int32_t mode);
    void (*clipboard_write)(void *ctx, int32_t clipboard, const uint32_t *text, size_t len, bool must_deselect);
    void (*request_paste)(void *ctx, int32_t clipboard);
    void (*request_resize)(void *ctx, int32_t cols, int32_t rows);
    void (*hostkey_prompt)(void *ctx, spb_request_id id, const spb_hostkey_prompt *);
    void (*userpass_prompt)(void *ctx, spb_request_id id, const spb_userpass_prompt *);
    void (*weak_crypto_prompt)(void *ctx, spb_request_id id, const char *const *lines, size_t n);
    void (*portfwd_status)(void *ctx, const spb_portfwd_status *);
    void (*reconfigure_done)(void *ctx, spb_request_id id, bool ok, const char *err);
    void (*settings_exported)(void *ctx, spb_request_id id, spb_settings *owned);
    void (*remote_exit)(void *ctx, int32_t exitcode);
} spb_callbacks;

spb_session *spb_session_create(const spb_settings *settings,
                                const spb_callbacks *cb, void *ctx,
                                int32_t cols, int32_t rows);
void spb_session_start(spb_session *);                      /* backend_init on core thread */
void spb_session_close(spb_session *);                      /* graceful; state→CLOSED */
void spb_session_release(spb_session *);                    /* after CLOSED; no callbacks after return */
uint64_t spb_session_transport_id(const spb_session *);     /* stable id of the live Backend; tests assert unchanged across reconfig */

/* Input */
void spb_session_key_utf8(spb_session *, const char *utf8, size_t len);     /* term_keyinput → ldisc */
void spb_session_key_special(spb_session *, int32_t keysym, uint32_t mods); /* bridge maps to PuTTY key sequences (format_*_key) */
void spb_session_paste(spb_session *, const uint32_t *text, size_t len);    /* term_do_paste (bracketed paste aware) */
void spb_session_mouse(spb_session *, int32_t button, int32_t action, int32_t col, int32_t row, uint32_t mods);
void spb_session_resize(spb_session *, int32_t cols, int32_t rows, int32_t px_w, int32_t px_h);
void spb_session_scroll(spb_session *, int32_t whence, int32_t lines);
void spb_session_focus(spb_session *, bool focused);
void spb_session_special(spb_session *, int32_t special_code, int32_t arg); /* break, IGNORE, rekey… */

/* Prompt answers */
void spb_session_answer_hostkey(spb_session *, spb_request_id, spb_hostkey_answer);
void spb_session_answer_userpass(spb_session *, spb_request_id,
                                 const char *const *responses, size_t n, bool cancelled);
void spb_session_answer_weak_crypto(spb_session *, spb_request_id, bool accept);

/* Live reconfiguration — THE critical entry point */
void spb_session_export_settings(spb_session *, spb_request_id);  /* → settings_exported */
void spb_session_reconfigure(spb_session *, const spb_settings *new_settings, spb_request_id);
                                                     /* → reconfigure_done; portfwd_status events follow */

/* Diagnostics */
size_t spb_debug_live_sessions(void);
size_t spb_debug_live_sockets(void);
```

What each critical call does on the core thread:

- `spb_session_reconfigure`: `newconf = conf_copy(s->conf)`; overlay keywords
  from `new_settings` (§6.3); validate; then the GTK sequence
  `log_reconfig` → `ldisc_configure` + `ldisc_echoedit_update` →
  `term_reconfig` → `backend_reconfig(s->backend, newconf)`; swap
  `s->conf`; emit `reconfigure_done`. Port-forward outcomes then arrive
  asynchronously through `portfwd_status` (local/dynamic synchronously during
  the call; remote when the server replies).
- `spb_session_export_settings`: `copy = conf_copy(s->conf)`;
  `term_pre_reconfig(s->term, copy)`; `save_open_settings(memw, copy)`.

Estimated footprint: about 1.5–2.5 kLOC of C in `Bridge/` for seat, termwin,
logpolicy, storage, event loop, key mapping and frame capture, plus a few small
upstream patches.

---

## 8. Terminal frontend

*Implemented in M03* (`Core/src/spb_terminal.c`, `Core/src/spb_input.c`,
`Sources/TerminalUI`). Differences from the proposal below:

- **Cells arrive resolved.** The TermWin resolves colours exactly as GTK
  PuTTY's `do_text_internal` does (reverse video, bold as colour, dim at
  2/3, true colour, the active block cursor's colours), so a cell is
  characters + RGB foreground/background + flags (D-021). Overlay cursors
  (passive block, underline, vertical line) are cell flags that the next
  `draw_text` over that cell clears, which is exactly how they behave as
  pixels in GTK.
- **Pull, not display link.** The grid is the published frame, guarded
  by a mutex that the core thread holds for the whole of a paint
  (`setup_draw_ctx` … `free_draw_ctx`). After a paint, the frontend gets
  one `terminal_updated` notification, and no more until it has read the
  frame (`spb_session_read_frame`, which copies only the dirty rows).
  PuTTY's own update timer already batches output, so 20,000 lines arrive
  as single-digit frame counts. AppKit's display cycle paces redraws.
- `char_width` returns 1, as in GTK PuTTY: double-width characters are
  drawn across two cells.
- Clipboards follow PuTTY's Unix model (D-022): mouse selection writes an
  app-private "selection" buffer (`CLIP_PRIMARY`); `CLIP_CLIPBOARD` is the
  general pasteboard. The frontend registers its clipboards with the
  terminal as GTK's `setup_clipboards` does.
- Keys: Swift classifies key events by key code (D-023); C translates them
  with GTK's `key_event` logic and PuTTY's formatters. Input-method
  composition text is drawn by PuTTY itself (`term_set_preedit_text`).

The original proposal:

- `Terminal` lives on the core thread. `term_update`/`term_paint` call
  `TermWin.draw_text`/`draw_cursor` *on the core thread*. The bridge's
  TermWin records these calls into a per-session **shadow cell grid**
  (codepoints including combining chars, attrs, true-colour, wide flags,
  cursor). It publishes a coalesced, immutable **frame** (dirty rows only)
  at most once per display refresh. The main thread requests frames via
  `CVDisplayLink`/`CADisplayLink`-paced "ready for next" flags, so there is
  never one update per character.
- `TerminalNSView` (AppKit, CoreText/CoreGraphics) renders frames, measures
  cell metrics from the configured monospaced font, uses `char_width`
  callbacks for wide/ambiguous characters (`CONF_cjk_ambig_wide`), and
  handles `NSTextInputClient` for IME. SwiftUI embeds it via
  `NSViewRepresentable`.
- Input goes Swift → `spb_session_key_*` → core thread → `term_keyinput*` /
  ldisc. Key translation reuses PuTTY's portable formatters
  (`format_arrow_key`, `format_function_key`, `format_small_keypad_key`,
  `format_numeric_keypad_key` in `terminal/terminal.c`) so keyboard parity
  matches upstream, including Funky type and app cursor/keypad.
- Selection, scrollback and copy are PuTTY's (`term_mouse`, `term_copyall`)
  for exact semantics. Mouse events are posted to the core thread.
- macOS `wchar_t` is 32-bit, which PuTTY's Unix build already handles
  (`unix/unicode.c`).

## 9. Reconfigurability classification (from upstream)

The authoritative per-setting table is `docs/CONFIGURATION_PARITY.md`. The
rules come from `config.c:setup_config_box(midsession=true, protocol,
protcfginfo)`, `windows/config.c:win_setup_config_box`, and what each
reconfigure handler actually reads:

| Class | Upstream evidence | Examples |
|---|---|---|
| **runtime-applicable** | Shown mid-session, consumed by `term_reconfig`, `ldisc_configure`, `log_reconfig`, `pinger_reconfig`, `ssh2_transport_reconfigure` (rekey), `portfwdmgr_config`, `serial_reconfig` | Tunnels, accept-all flags, keepalive interval, rekey time/data, cipher list & compression (forces rekey), terminal/keyboard/bell/features, colours, fonts, selection, logging, serial speed/bits/parity/flow |
| **future-connections-only** | Shown mid-session but only read at specific later events | KEX list / host-key-alg preferences / GSSAPI kex (used at next rekey); `rport_acceptall` affects only *newly created* remote forwards; `lport_acceptall` only new listeners |
| **requires-reconnect** | Hidden when `midsession` (`if (!midsession)` blocks in `config.c`) | Host/port/protocol, proxy, Connection/Data (username, terminal type, environment), SSH protocol options, Auth, TTY modes, X11, Bugs, sharing, TCP options, address family, logical host name |
| **unsupported** | Platform-specific or N/A on macOS | `alt_f4`, `alt_space`, `alt_only`, logical palettes, sunken edge, font quality (ClearType), Caps-Lock-Cyrillic (§ parity doc) |

The Swift UI uses the same rules to disable non-runtime controls in Change
Settings (as Windows hides them). It never silently reconnects.

## 10. Repository layout

As of M05:

```
swift_putty/
├── Package.swift                  SwiftPuttyKit: binary core + Swift modules + tests (D-012)
├── App/
│   ├── SwiftPutty.xcodeproj       app target; local package reference to ".."
│   └── SwiftPutty/                SwiftUI app sources (folder-synchronised group)
├── Sources/
│   ├── PuTTYBridge/               Swift wrapper; the only consumer of PuTTYBridge.h
│   ├── SessionLayer/              SessionController (M02); configuration diff (M07)
│   ├── TestServers/               test-only loopback TCP servers (not a product)
│   ├── TerminalUI/                TerminalView (AppKit), renderer, key mapping, font (M03)
│   ├── Persistence/               SavedSessionStore: saved sessions, versioned JSON (M05, D-027)
│   └── ConfigurationUI/           PuTTY's configuration dialog: model + SwiftUI panels (M05, D-028)
├── Tests/SwiftPuttyKitTests/      Swift tests (swift test; one serialized root suite)
├── Core/                          C side of the bridge
│   ├── include/                   PuTTYBridge.h + module.modulemap (module PuTTYBridgeC)
│   ├── src/                       spb_*.c: core, event loop (core thread), session, seat, terminal (TermWin), input, settings, storage, platform
│   ├── cmake/                     SwiftPuttyCore.cmake (injected into upstream's build), RepackArchive.cmake
│   └── tests/                     C bridge tests (ctest)
├── Vendor/putty/                  pristine PuTTY 0.85
├── patches/                       0001…, applied to build/putty-src by scripts/prepare-putty-src.sh
├── scripts/                       prepare-putty-src.sh, build-core.sh, build-app.sh, test-all.sh
├── build/                         generated: putty-src, core-<arch>, SwiftPuttyCore.xcframework, DerivedData
├── docs/
└── THIRD_PARTY_NOTICES.md
```

The C bridge implemented in M01 is the subset of §7 that needs no event
loop: library info (`spb_api_version`, `spb_putty_version`,
`spb_putty_ssh_version`, `spb_putty_licence_text`, `spb_putty_copyright`),
core lifecycle (`spb_core_init`/`shutdown`), the settings document
(`spb_settings_*`), session objects that own a `Conf`
(`spb_session_create`/`release`/`id`/`copy_settings`), and diagnostics.
Changes from the §7 proposal: `spb_settings_set` takes string values only,
because PuTTY's Unix storage stores every value as a string; and
`spb_session_copy_settings` is a synchronous M01 accessor that will be
superseded by the asynchronous `spb_session_export_settings` once sessions
run on the core thread (M02/M07).

M02 adds the core thread and the session executor (§4, D-003, D-017 …
D-019). Differences from the §7 proposal:

- `spb_core_init` starts the core thread; `spb_core_shutdown` stops and
  joins it, after the teardown of every released session has run.
  `spb_core_barrier` waits for all previously queued work (tests and
  diagnostics only).
- `spb_session_create(settings, callbacks, ctx, err)` takes the callback
  table; `cols`/`rows` arrive with the terminal (M03).
  `spb_session_start`, `spb_session_send`, `spb_session_send_eof`,
  `spb_session_close` and `spb_session_release` are asynchronous and
  execute in call order. Release does not wait: it suppresses further
  callbacks and ends with a final `released(ctx)` callback (D-017).
- States are `CREATED → CONNECTING → CONNECTED → CLOSED | FAILED`.
  `AUTHENTICATING` arrives with SSH (M04). PuTTY has no "connected"
  notification, so `CONNECTED` is derived from `backend_sendok` (D-018).
- M02 callbacks: `state_changed`, `event_log`, `output` (raw bytes until
  the terminal exists), `remote_exit`, `released`.
- Only the Raw protocol is started in M02 (D-019).
- New diagnostics: `spb_debug_uxsel_fds`, `spb_debug_loop_iterations`,
  `spb_debug_after_delay` (schedules through PuTTY's timer queue).

M04 (API v4) enables SSH (D-024). Instead of the §7 proposal's separate
`hostkey_prompt` / `userpass_prompt` / `weak_crypto_prompt` callbacks:

- User name, password and keyboard-interactive prompts never leave C:
  the Seat hands them to the Terminal (`term_get_userpass_input`), as GTK
  PuTTY does.
- Host-key and weak-crypto confirmations share one `prompt` callback
  (`spb_prompt`: kind, id, PuTTY's `SeatDialogText` items) and one
  `spb_session_answer_prompt(id, CANCEL | ACCEPT_ONCE |
  ACCEPT_AND_STORE)`. `prompt_cancelled` withdraws a dialog whose
  connection ended.
- `AUTHENTICATING` is not a separate state: a session is `CONNECTING`
  until the backend accepts input (D-018), which for SSH is after
  authentication and channel setup.

M05 (API v5, D-029) adds the log file question
(`SPB_PROMPT_LOG_FILE_EXISTS`, answers `SPB_ANSWER_LOG_OVERWRITE` /
`SPB_ANSWER_LOG_APPEND` / `SPB_ANSWER_CANCEL`) in a second dialog slot per
session, kept until release; and `spb_settings_prepare_session`
(upstream `prepare_session`), which `spb_session_create` now applies as
GTK PuTTY's `new_session_window` does. Saved sessions stay on the Swift
side (D-027); the core still never opens a session by name.

M06 (API v6, D-030) adds `SPB_KEY_C` / `SPB_KEY_V` (Ctrl+Shift+C/V,
decided by the bridge per `CONF_ctrlshiftcv`, as GTK's `key_event`),
Ctrl+Insert copy, and `spb_charset_name` / `spb_charset_canonical_name`
(upstream's character set list). The core is compiled with
`OSX_META_KEY_CONFIG`, so the Meta-key settings are saved.

## 11. Risks and open questions

| ID | Risk | Mitigation / milestone |
|---|---|---|
| R-1 | H-1/H-2 upstream memory-safety bugs on forwarding paths | Patches `0007`/`0008`; ASan reproduction tests (M08, M13); report upstream |
| R-2 | Single core thread: blocking `getaddrinfo` in one session stalls all sessions | Accept for M02–M10; measure; options: patch `name_lookup` to resolve on a helper thread, or per-session helper process (decide by M14) |
| R-3 | `load_open_settings` resets `NOT_SAVED` keys; overlay must preserve them (§6.3) | Generic overlay over `conf_key_info[]`; round-trip test over all 211 keys in M07 |
| R-4 | Universal build loses HW crypto if configured as one multi-arch CMake build | Per-arch configure + `lipo` (D-006, verified) |
| R-5 | `TermWin` drawing on core thread vs AppKit on main | Frame snapshot design (§8); benchmark in M03/M14 |
| R-6 | App Sandbox vs. listeners, serial, arbitrary key files, `SSH_AUTH_SOCK` | Evaluate in M15; developer builds unsandboxed |
| R-7 | `pfl_closing` frees a listener that a `PortFwdRecord` still points to (if a listening socket ever reports closing) | Audit in M13 |
| R-8 | arm64 slice cannot be executed on the x86_64 development host | **Mitigated (M03):** CI (`.github/workflows/ci.yml`) runs the full `scripts/test-all.sh --clean` on Apple Silicon (`macos-26`) and Intel (`macos-26-intel`) runners for every push to `main` and every pull request |
