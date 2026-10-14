# Configuration Parity — Windows PuTTY 0.85 → SwiftPutty

Generated in M00 from the dialog definitions in `config.c:setup_config_box()`
(portable) and `windows/config.c:win_setup_config_box()` (Windows-only). A
script walked every control with its enclosing `midsession` / `protcfginfo`
conditions, and the effect of each key was then checked against the
reconfigure handlers (`term_reconfig`, `ldisc_configure`, `log_reconfig`,
`ssh_reconfig` → `pinger_reconfig` / `ssh2_transport_reconfigure` /
`ssh2_connection_reconfigure` → `portfwdmgr_config`, `serial_reconfig`,
`telnet_reconfig`).

**Status values:** NOT STARTED · PARTIAL · COMPLETE · NOT APPLICABLE
**Runtime values:**

- **runtime** — shown in Change Settings and takes effect on the live session.
- **future** — shown in Change Settings but only used at a later event (next
  rekey, next terminal reset, newly created forwards). The note says when.
- **reconnect** — hidden in Windows Change Settings (`!midsession`). Needs
  a new session; SwiftPutty never reconnects silently.
- **unsupported** — no macOS equivalent.

Every row was NOT STARTED at M00; M05 added the configuration dialog
(D-028). COMPLETE rows are done; PARTIAL rows can be set before
connecting and take effect then, but cannot yet be changed in a running
session (Change Settings, M07), or are otherwise limited as noted. For
NOT STARTED rows, "macOS implementation" is the *planned* mapping.
`CONF_x` = PuTTY Conf key. Saved keyword = `conf.h` `SAVE_KEYWORD`.

## Session

| Windows PuTTY setting | macOS implementation | Status | Runtime | Notes |
|---|---|---|---|---|
| Host Name / IP (`CONF_host`) | Session panel edit box; upstream `prepare_session` applied at connect (user@, :suffix) | COMPLETE | reconnect |  |
| Port (`CONF_port`) | Session panel edit box (0 shown blank) | COMPLETE | reconnect | Default depends on protocol (load_custom). Follows the protocol while it is still the old default (`config_protocols_handler`) |
| Connection type (`CONF_protocol`) | Radio: SSH, Other: popup | PARTIAL | reconnect | M05: SSH and Raw; Serial, Telnet, Rlogin, SUPDUP in M11 |
| Saved Sessions list / Load / Save / Delete | Session panel: name box, list (Default Settings first), Load/Save/Delete; double-click opens | PARTIAL | Save: runtime (mid-session "Save the current session settings"); Load/Delete: reconnect (hidden) | Versioned JSON store, not the registry (D-027); PuTTY's rules (`sessionsaver_handler`). M05: before connecting; mid-session Save in M07 |
| Close window on exit (`CONF_close_on_exit`) | Radio Always/Never/Only on clean exit | PARTIAL | runtime | Read by the frontend at exit. M05: configuration dialog before connecting; live in Change Settings (M07). |

## Session → Logging

| Windows PuTTY setting | macOS implementation | Status | Runtime | Notes |
|---|---|---|---|---|
| Session logging type (`CONF_logtype`) | Radio | PARTIAL | runtime | `log_reconfig` closes/reopens the log. M05: configuration dialog before connecting; live in Change Settings (M07). |
| Log file name (`CONF_logfilename`) | Edit box + Browse… (NSSavePanel); `&H &Y &M &D &T &P` placeholders kept | PARTIAL | runtime | Same. Relative names resolve against the home directory, as Unix PuTTY. M05: configuration dialog before connecting; live in Change Settings (M07). |
| If log file exists (`CONF_logxfovr`) | Radio; "Ask" shows GTK's Overwrite/Append/Disable sheet (API v5, D-029) | PARTIAL | runtime | M05: configuration dialog before connecting; live in Change Settings (M07). |
| Flush log file frequently (`CONF_logflush`) | Checkbox | PARTIAL | runtime | M05: configuration dialog before connecting; live in Change Settings (M07). |
| Include header (`CONF_logheader`) | Checkbox | PARTIAL | runtime | M05: configuration dialog before connecting; live in Change Settings (M07). |
| Omit known password fields (`CONF_logomitpass`) | Checkbox (SSH only) | PARTIAL | runtime | M05: configuration dialog before connecting; live in Change Settings (M07). |
| Omit session data (`CONF_logomitdata`) | Checkbox (SSH only) | PARTIAL | runtime | M05: configuration dialog before connecting; live in Change Settings (M07). |

## Terminal

| Windows PuTTY setting | macOS implementation | Status | Runtime | Notes |
|---|---|---|---|---|
| Auto wrap mode initially on (`CONF_wrap_mode`) | Checkbox | PARTIAL | runtime | `term_reconfig` also changes the *current* mode if the setting changed. M05: configuration dialog before connecting; live in Change Settings (M07). |
| DEC Origin Mode initially on (`CONF_dec_om`) | Checkbox | PARTIAL | runtime | Same. M05: configuration dialog before connecting; live in Change Settings (M07). |
| Implicit CR in every LF (`CONF_lfhascr`) | Checkbox | PARTIAL | runtime | M05: configuration dialog before connecting; live in Change Settings (M07). |
| Implicit LF in every CR (`CONF_crhaslf`) | Checkbox | PARTIAL | runtime | M05: configuration dialog before connecting; live in Change Settings (M07). |
| Use background colour to erase screen (`CONF_bce`) | Checkbox | PARTIAL | runtime | M05: configuration dialog before connecting; live in Change Settings (M07). |
| Enable blinking text (`CONF_blinktext`) | Checkbox | PARTIAL | runtime | M05: configuration dialog before connecting; live in Change Settings (M07). |
| Answerback to ^E (`CONF_answerback`) | Text field | PARTIAL | runtime | M05: configuration dialog before connecting; live in Change Settings (M07). |
| Local echo (`CONF_localecho`) | Radio Auto/Force on/Force off | PARTIAL | runtime | `ldisc_configure`. M05: configuration dialog before connecting; live in Change Settings (M07). |
| Local line editing (`CONF_localedit`) | Radio | PARTIAL | runtime | `ldisc_configure` + `ldisc_echoedit_update`. M05: configuration dialog before connecting; live in Change Settings (M07). |
| Printer for ANSI printing (`CONF_printer`) | Popup of CUPS printers | NOT STARTED | runtime | `term_reconfig` aborts an active print job when cleared. Initially stubbed (`stubs/no-print.c`) |

## Terminal → Keyboard

| Windows PuTTY setting | macOS implementation | Status | Runtime | Notes |
|---|---|---|---|---|
| Backspace key (`CONF_bksp_is_delete`) | Radio ^H / ^? | NOT STARTED | runtime | Read per keypress |
| Home and End keys (`CONF_rxvt_homeend`) | Radio Standard/rxvt | NOT STARTED | runtime | |
| Function keys and keypad (`CONF_funky_type`) | Popup ESC[n~ / Linux / Xterm R6 / VT400 / VT100+ / SCO / Xterm 216+ | NOT STARTED | runtime | Uses PuTTY `format_function_key` |
| Shift/Ctrl/Alt with arrow keys (`CONF_sharrow_type`) | Radio | NOT STARTED | runtime | |
| Initial state of cursor keys (`CONF_app_cursor`) | Radio | NOT STARTED | future | Takes effect at the next terminal power-on/reset |
| Initial state of numeric keypad (`CONF_app_keypad`, `CONF_nethack_keypad`) | Radio Normal/Application/NetHack | NOT STARTED | future (app) / runtime (NetHack) | NetHack mode is read per key |
| AltGr acts as Compose key (`CONF_compose_key`) | — | NOT APPLICABLE | unsupported | No AltGr on macOS; Option-key handling replaces it (below) |
| Control-Alt is different from AltGr (`CONF_ctrlaltkeys`) | — | NOT APPLICABLE | unsupported | Same |
| *(macOS addition)* Option acts as Meta (`CONF_osx_option_meta`) | Checkbox (left/right) | NOT STARTED | runtime | Upstream Unix-only key, already in `conf.h` |
| *(macOS addition)* Command acts as Meta (`CONF_osx_command_meta`) | Checkbox | NOT STARTED | runtime | Upstream Unix-only key; conflicts with menu shortcuts, so default off |

## Terminal → Bell

| Windows PuTTY setting | macOS implementation | Status | Runtime | Notes |
|---|---|---|---|---|
| Action on bell (`CONF_beep`) | None / System alert (`NSSound.beep`) / Visual / Custom sound | NOT STARTED | runtime | Windows "Play a custom sound file" → `NSSound(contentsOf:)` |
| Custom sound file (`CONF_bell_wavefile`) | File chooser (AIFF/WAV/CAF) | NOT STARTED | runtime | |
| Taskbar/caption indication (`CONF_beep_ind`) | Dock bounce (`requestUserAttention`) / steady dock badge | NOT STARTED | runtime | Flashing → informational bounce, steady → critical bounce/badge |
| Bell overload protection (`CONF_bellovl`, `_n`, `_t`, `_s`) | Checkbox + three fields | NOT STARTED | runtime | Implemented inside PuTTY's terminal |

## Terminal → Features

| Windows PuTTY setting | macOS implementation | Status | Runtime | Notes |
|---|---|---|---|---|
| Disable application cursor keys (`CONF_no_applic_c`) | Checkbox | NOT STARTED | runtime | |
| Disable application keypad (`CONF_no_applic_k`) | Checkbox | NOT STARTED | runtime | |
| Disable xterm mouse reporting (`CONF_no_mouse_rep`) | Checkbox | NOT STARTED | runtime | `term_reconfig` drops raw mouse mode |
| Disable remote resizing (`CONF_no_remote_resize`) | Checkbox | NOT STARTED | runtime | |
| Disable alternate screen (`CONF_no_alt_screen`) | Checkbox | NOT STARTED | runtime | `term_reconfig` swaps back immediately |
| Disable remote window title changing (`CONF_no_remote_wintitle`) | Checkbox | NOT STARTED | runtime | |
| Response to remote title query (`CONF_remote_qtitle_action`) | Radio None/Empty string/Window title | NOT STARTED | runtime | Security-relevant; keep upstream default |
| Disable remote clearing of scrollback (`CONF_no_remote_clearscroll`) | Checkbox | NOT STARTED | runtime | |
| Disable destructive backspace (`CONF_no_dbackspace`) | Checkbox | NOT STARTED | runtime | |
| Disable remote charset config (`CONF_no_remote_charset`) | Checkbox | NOT STARTED | runtime | |
| Disable Arabic shaping (`CONF_no_arabicshaping`) | Checkbox | NOT STARTED | runtime | Flushes bidi cache |
| Disable bidi (`CONF_no_bidi`) | Checkbox | NOT STARTED | runtime | |
| Disable bracketed paste (`CONF_no_bracketed_paste`) | Checkbox | NOT STARTED | runtime | |

## Window

| Windows PuTTY setting | macOS implementation | Status | Runtime | Notes |
|---|---|---|---|---|
| Columns / Rows (`CONF_width`, `CONF_height`) | Number fields; the window opens at that size | PARTIAL | runtime | Hidden mid-session only if the backend forbids resize. M05: configuration dialog before connecting; live in Change Settings (M07). |
| When window is resized (`CONF_resize_action`) | Radio: change rows/cols, change font size, both, forbid | NOT STARTED | runtime | |
| Lines of scrollback (`CONF_savelines`) | Number field | PARTIAL | runtime | `term_size`. M05: configuration dialog before connecting; live in Change Settings (M07). |
| Display scrollbar (`CONF_scrollbar`) | Checkbox (NSScroller visibility) | PARTIAL | runtime | M05: configuration dialog before connecting; live in Change Settings (M07). |
| Display scrollbar in full screen (`CONF_scrollbar_in_fullscreen`) | Checkbox | NOT STARTED | runtime | macOS full-screen space |
| Reset scrollback on keypress (`CONF_scroll_on_key`) | Checkbox | PARTIAL | runtime | M05: configuration dialog before connecting; live in Change Settings (M07). |
| Reset scrollback on display activity (`CONF_scroll_on_disp`) | Checkbox | PARTIAL | runtime | M05: configuration dialog before connecting; live in Change Settings (M07). |
| Push erased text into scrollback (`CONF_erase_to_scrollback`) | Checkbox | PARTIAL | runtime | M05: configuration dialog before connecting; live in Change Settings (M07). |

## Window → Appearance

| Windows PuTTY setting | macOS implementation | Status | Runtime | Notes |
|---|---|---|---|---|
| Cursor appearance (`CONF_cursor_type`) | Radio Block/Underline/Vertical line | PARTIAL | runtime | M05: configuration dialog before connecting; live in Change Settings (M07). |
| Cursor blinks (`CONF_blink_cur`) | Checkbox | NOT STARTED | runtime | |
| Font (`CONF_font`) | Font description + Change… popover: fixed-pitch family and size; stored as `"<PostScriptName> <pt>"` | PARTIAL | runtime | Unix FontSpec is a string; we store `"<PostScriptName> <pt>"`. Default `Menlo-Regular 12` (Windows: Courier New 10), set in M01. M05: configuration dialog before connecting; live in Change Settings (M07). |
| Allow variable-pitch fonts | Checkbox (font panel filter) | NOT STARTED | runtime | UI-only in Windows too |
| Font quality (`CONF_font_quality`) | — | NOT APPLICABLE | unsupported | ClearType/antialias options; macOS always antialiases. Kept in the model for round-trip |
| Hide mouse pointer when typing (`CONF_hide_mouseptr`) | Checkbox (`NSCursor.setHiddenUntilMouseMoves`) | NOT STARTED | runtime | |
| Gap between text and window edge (`CONF_window_border`) | Number field | NOT STARTED | runtime | |
| Sunken-edge border (`CONF_sunken_edge`) | — | NOT APPLICABLE | unsupported | Win32 window style |
| *(Unix/GTK)* Bold/wide/wide-bold fonts, shadow bold (`CONF_boldfont`, `CONF_widefont`, `CONF_wideboldfont`, `CONF_shadowbold`, `CONF_shadowboldoffset`) | Optional advanced font section | NOT STARTED | runtime | Not in Windows UI; keys exist in `conf.h` |

## Window → Behaviour

| Windows PuTTY setting | macOS implementation | Status | Runtime | Notes |
|---|---|---|---|---|
| Window title (`CONF_wintitle`) | Text field | PARTIAL | runtime | `term_pre_reconfig` pre-fills the live title. M05: configuration dialog before connecting; live in Change Settings (M07). |
| Separate window and icon titles (`CONF_win_name_always`) | Checkbox (icon title → miniaturised title) | NOT STARTED | runtime | |
| Warn before closing window (`CONF_warn_on_close`) | Checkbox (close confirmation sheet) | NOT STARTED | runtime | |
| Window closes on ALT-F4 (`CONF_alt_f4`) | — | NOT APPLICABLE | unsupported | ⌘W is standard |
| System menu on ALT-Space / ALT alone (`CONF_alt_space`, `CONF_alt_only`) | — | NOT APPLICABLE | unsupported | No system menu on macOS |
| Ensure window is always on top (`CONF_alwaysontop`) | Checkbox (`NSWindow.level = .floating`) | NOT STARTED | runtime | |
| Full screen on Alt-Enter (`CONF_fullscreenonaltenter`) | Checkbox (Option-Return → toggleFullScreen) | NOT STARTED | runtime | ⌃⌘F always available |

## Window → Translation

| Windows PuTTY setting | macOS implementation | Status | Runtime | Notes |
|---|---|---|---|---|
| Remote character set (`CONF_line_codepage`) | Popup of PuTTY charset names (UTF-8 default) | NOT STARTED | runtime | Upstream `charset/` |
| Treat CJK ambiguous as wide (`CONF_cjk_ambig_wide`) | Checkbox | NOT STARTED | runtime | |
| Caps Lock acts as Cyrillic switch (`CONF_xlat_capslockcyr`) | — | NOT APPLICABLE | unsupported | macOS input sources replace it |
| Line drawing handling (`CONF_vtmode`) | Radio (Unicode / poor man's / font has XWindows encoding…) — subset meaningful on macOS | NOT STARTED | runtime | Windows-specific modes (ANSI/OEM font) are NOT APPLICABLE |
| Copy and paste line drawing as lqqqk (`CONF_rawcnp`) | Checkbox | NOT STARTED | runtime | |
| Enable VT100 line drawing in UTF-8 (`CONF_utf8linedraw`) | Checkbox | NOT STARTED | runtime | |

## Window → Selection (+ Copy)

| Windows PuTTY setting | macOS implementation | Status | Runtime | Notes |
|---|---|---|---|---|
| Action of mouse buttons (`CONF_mouse_is_xterm`) | Radio: Windows / Compromise / xterm | NOT STARTED | runtime | Right-click context menu vs paste follows this, as in Windows |
| Shift overrides application's mouse (`CONF_mouse_override`) | Checkbox | NOT STARTED | runtime | |
| Default selection mode (`CONF_rect_select`) | Radio Normal/Rectangular (Option-drag = other) | NOT STARTED | runtime | Windows uses Alt-drag |
| Auto-copy selected text (`CONF_mouseautocopy`) | Checkbox | NOT STARTED | runtime | |
| Mouse paste / Ctrl+Ins / Ctrl+Shift+C,V clipboards (`CONF_mousepaste`, `CONF_ctrlshiftins`, `CONF_ctrlshiftcv` + `_custom`) | Mapped to NSPasteboard general / "selection" (app-private) | NOT STARTED | runtime | ⌘C/⌘V always use the general pasteboard |
| Permit control characters in paste (`CONF_paste_controls`) | Checkbox | NOT STARTED | runtime | |
| Copy as RTF (`CONF_rtf_paste`) | Checkbox (writes `.rtf` pasteboard type too) | NOT STARTED | runtime | |
| Character classes (`CONF_wordness`) | Table editor | NOT STARTED | runtime | `term_reconfig` resets classes |

## Window → Colours

| Windows PuTTY setting | macOS implementation | Status | Runtime | Notes |
|---|---|---|---|---|
| Allow ANSI colours (`CONF_ansi_colour`) | Checkbox | NOT STARTED | runtime | |
| Allow xterm 256-colour (`CONF_xterm_256_colour`) | Checkbox | NOT STARTED | runtime | |
| Allow 24-bit colour (`CONF_true_colour`) | Checkbox | NOT STARTED | runtime | |
| Indicate bold by (`CONF_bold_style`) | Radio font / colour / both | NOT STARTED | runtime | |
| Attempt to use logical palettes (`CONF_try_palette`) | — | NOT APPLICABLE | unsupported | 256-colour display mode concept |
| Use system colours (`CONF_system_colour`) | Checkbox (NSColor.textColor/textBackgroundColor, follows dark mode) | NOT STARTED | runtime | `term_notify_palette_changed` |
| Colour list + RGB (`CONF_colours`) | Table + NSColorWell | NOT STARTED | runtime | `term_reconfig` updates the palette unless overridden by OSC |

## Connection

| Windows PuTTY setting | macOS implementation | Status | Runtime | Notes |
|---|---|---|---|---|
| Seconds between keepalives (`CONF_ping_interval`) | Number field | PARTIAL | runtime | `pinger_reconfig`. Saved as `PingInterval` minutes + `PingIntervalSecs`, as settings.c M05: configuration dialog before connecting; live in Change Settings (M07). |
| Disable Nagle (`CONF_tcp_nodelay`) | Checkbox | COMPLETE | reconnect |  |
| TCP keepalives (`CONF_tcp_keepalives`) | Checkbox | COMPLETE | reconnect |  |
| Internet protocol version (`CONF_addressfamily`) | Radio Auto/IPv4/IPv6 | COMPLETE | reconnect |  |
| Logical name of remote host (`CONF_loghost`) | Text field | COMPLETE | reconnect | Host-key lookup name |
| Command to run before connection (`CONF_pre_connect_command`) | — | NOT STARTED | reconnect | **Security review needed** before enabling (runs a local command) |

## Connection → Data

| Windows PuTTY setting | macOS implementation | Status | Runtime | Notes |
|---|---|---|---|---|
| Auto-login username (`CONF_username`) | Text field | COMPLETE | reconnect | A `user@` prefix on the host name overrides it (`prepare_session`) |
| When username not specified (`CONF_username_from_env`) | Radio Prompt / Use system username | COMPLETE | reconnect | macOS: `getpwuid` via `unix/utils/get_username.c` |
| Terminal-type string (`CONF_termtype`) | Text field (default `xterm`) | COMPLETE | reconnect |  |
| Terminal speeds (`CONF_termspeed`) | Text field | COMPLETE | reconnect |  |
| Environment variables (`CONF_environmt`) | Key/value table | NOT STARTED | reconnect | |

## Connection → Proxy

| Windows PuTTY setting | macOS implementation | Status | Runtime | Notes |
|---|---|---|---|---|
| Proxy type (`CONF_proxy_type`) | Popup None/SOCKS4/SOCKS5/HTTP/Telnet/SSH (jump)/Local command | NOT STARTED | reconnect | All via upstream `proxy/` |
| Proxy host / port (`CONF_proxy_host`, `CONF_proxy_port`) | Text fields | NOT STARTED | reconnect | |
| Exclude hosts (`CONF_proxy_exclude_list`) | Text field | NOT STARTED | reconnect | |
| Consider proxying local host (`CONF_even_proxy_localhost`) | Checkbox | NOT STARTED | reconnect | |
| DNS at proxy end (`CONF_proxy_dns`) | Radio No/Auto/Yes | NOT STARTED | reconnect | |
| Proxy username (`CONF_proxy_username`) | Text field | NOT STARTED | reconnect | |
| Proxy password (`CONF_proxy_password`) | Secure field. **Never written to the session file**; optional Keychain item | NOT STARTED | reconnect | Deviation: PuTTY saves this in plaintext |
| Telnet/local proxy command (`CONF_proxy_telnet_command`) | Text field | NOT STARTED | reconnect | |
| Print proxy diagnostics (`CONF_proxy_log_to_term`) | Radio | NOT STARTED | reconnect | |

## Connection → SSH

| Windows PuTTY setting | macOS implementation | Status | Runtime | Notes |
|---|---|---|---|---|
| Remote command (`CONF_remote_cmd`) | Multiline text | NOT STARTED | reconnect | |
| Don't start a shell (`CONF_ssh_no_shell`) | Checkbox | NOT STARTED | reconnect | Useful for tunnel-only sessions |
| Enable compression (`CONF_compression`) | Checkbox | NOT STARTED | runtime | SSH-2: triggers an immediate rekey (`ssh2_transport_reconfigure`). Hidden mid-session on SSH-1 |
| Share SSH connections (`CONF_ssh_connection_sharing`, `_upstream`, `_downstream`) | Checkboxes | NOT STARTED | reconnect | Unix sharing via `unix/sharing.c` (Unix-domain socket in a private dir) |
| SSH protocol version (`CONF_sshprot`) | Radio 2 / 1 (SSH-1 hidden behind "legacy") | NOT STARTED | reconnect | |

## Connection → SSH → Kex / Host keys / Cipher

| Windows PuTTY setting | macOS implementation | Status | Runtime | Notes |
|---|---|---|---|---|
| Kex algorithm order (`CONF_ssh_kexlist`) | Reorderable list with warn-below separator | NOT STARTED | future | Shown mid-session (SSH-2); used at the next rekey |
| Attempt GSSAPI key exchange (`CONF_try_gssapi_kex`) | Checkbox | NOT STARTED | future | macOS GSS: `unix/gss.c` dlopen; feasibility TBD (M09) |
| Max minutes before rekey (`CONF_ssh_rekey_time`) | Number field | NOT STARTED | runtime | May rekey immediately if shortened |
| Minutes between GSS checks (`CONF_gssapirekey`) | Number field | NOT STARTED | runtime | |
| Max data before rekey (`CONF_ssh_rekey_data`) | Text field (e.g. `1G`) | NOT STARTED | runtime | |
| Host key algorithm order (`CONF_ssh_hklist`) | Reorderable list | NOT STARTED | future | Next rekey |
| Prefer algorithms with known host key (`CONF_ssh_prefer_known_hostkeys`) | Checkbox | NOT STARTED | future | Next rekey |
| Manually configured host keys (`CONF_ssh_manual_hostkeys`) | List + Add/Remove | NOT STARTED | reconnect | |
| Configure host CAs | Separate CA manager window (`host_ca_*` storage API) | NOT STARTED | runtime | Global store, not per-session; button shown mid-session |
| Cipher order (`CONF_ssh_cipherlist`) | Reorderable list | NOT STARTED | runtime | Change forces a rekey |
| Enable legacy single-DES (`CONF_ssh2_des_cbc`) | Checkbox | NOT STARTED | runtime | Forces a rekey |

## Connection → SSH → Auth (+ Credentials, GSSAPI)

| Windows PuTTY setting | macOS implementation | Status | Runtime | Notes |
|---|---|---|---|---|
| Display pre-auth banner (`CONF_ssh_show_banner`) | Checkbox | NOT STARTED | reconnect | |
| Bypass authentication (`CONF_ssh_no_userauth`) | Checkbox | NOT STARTED | reconnect | |
| Disconnect if trivial auth (`CONF_ssh_no_trivial_userauth`) | Checkbox | NOT STARTED | reconnect | |
| Attempt auth using Pageant (`CONF_tryagent`) | Checkbox "Attempt authentication using SSH agent" | NOT STARTED | reconnect | Uses `SSH_AUTH_SOCK` (macOS/OpenSSH agent). Pageant pipe N/A |
| Attempt TIS/CryptoCard (SSH-1) (`CONF_try_tis_auth`) | Checkbox (legacy) | NOT STARTED | reconnect | |
| Attempt keyboard-interactive (`CONF_try_ki_auth`) | Checkbox | NOT STARTED | reconnect | |
| Allow agent forwarding (`CONF_agentfwd`) | Checkbox | NOT STARTED | reconnect | |
| Allow username changes (`CONF_change_username`) | Checkbox | NOT STARTED | reconnect | |
| Private key file (`CONF_keyfile`) | NSOpenPanel; security-scoped bookmark if sandboxed | NOT STARTED | reconnect | PPK + OpenSSH formats via upstream |
| Certificate (`CONF_detached_cert`) | NSOpenPanel | NOT STARTED | reconnect | |
| Authentication plugin (`CONF_auth_plugin`) | Text field | NOT STARTED | reconnect | Runs a local command; review in M13 |
| Attempt GSSAPI auth (`CONF_try_gssapi_auth`) | Checkbox | NOT STARTED | reconnect | |
| Allow GSSAPI delegation (`CONF_gssapifwd`) | Checkbox | NOT STARTED | reconnect | |
| GSSAPI library preference / custom path (`CONF_ssh_gsslist`, `CONF_ssh_gss_custom`) | Reorderable list + path | NOT STARTED | reconnect | Depends on Unix GSS libs on macOS |

## Connection → SSH → TTY / X11 / Tunnels / Bugs

| Windows PuTTY setting | macOS implementation | Status | Runtime | Notes |
|---|---|---|---|---|
| Don't allocate a pty (`CONF_nopty`) | Checkbox | NOT STARTED | reconnect | |
| Terminal modes (`CONF_ttymodes`) | Table Auto/Nothing/value | NOT STARTED | reconnect | |
| Enable X11 forwarding (`CONF_x11_forward`) | Checkbox | NOT STARTED | reconnect | Works with XQuartz `DISPLAY` |
| X display location (`CONF_x11_display`) | Text field | NOT STARTED | reconnect | |
| Remote X11 auth protocol (`CONF_x11_auth`) | Radio MIT-Magic-Cookie-1 / XDM-Authorization-1 | NOT STARTED | reconnect | |
| X authority file (`CONF_xauthfile`) | File chooser | NOT STARTED | reconnect | |
| **Local ports accept connections from other hosts (`CONF_lport_acceptall`)** | Checkbox | NOT STARTED | future | Read by `pfl_listen` only when a listener is *created*; existing listeners keep their bind |
| **Remote ports do the same (`CONF_rport_acceptall`)** | Checkbox | NOT STARTED | future | Used only for *newly requested* remote forwards with no explicit bind address |
| **Forwarded ports list (`CONF_portfwd`)** — add/remove L, R, D, Auto/IPv4/IPv6, optional bind address | Table + Add/Remove/**Edit** sheet; per-row live status (Listening / Failed / Requested / Enabled / Refused) | NOT STARTED | **runtime** | `portfwdmgr_config`. Edit = staged remove+add (ARCHITECTURE §6.4). SSH-1: remote removal unsupported |
| SSH server bug workarounds (`CONF_sshbug_*`, 15 keys) | Popup Auto/Off/On each | NOT STARTED | reconnect | |

## Connection → Serial

| Windows PuTTY setting | macOS implementation | Status | Runtime | Notes |
|---|---|---|---|---|
| Serial line (`CONF_serline`) | Popup enumerating `/dev/cu.*` (and `/dev/tty.*` on request) + free text | NOT STARTED | reconnect | `unix/serial.c` |
| Speed (`CONF_serspeed`) | Number field | NOT STARTED | runtime | `serial_reconfig` → `serial_configure`; errors are discarded upstream (FIXME), so SwiftPutty re-reads termios and reports |
| Data bits / Stop bits (`CONF_serdatabits`, `CONF_serstopbits`) | Fields | NOT STARTED | runtime | Same |
| Parity / Flow control (`CONF_serparity`, `CONF_serflow`) | Popups | NOT STARTED | runtime | Same |

## Connection → Telnet / Rlogin / SUPDUP

| Windows PuTTY setting | macOS implementation | Status | Runtime | Notes |
|---|---|---|---|---|
| OLD_ENVIRON ambiguity (`CONF_rfc_environ`) | Radio | NOT STARTED | reconnect | |
| Telnet negotiation mode (`CONF_passive_telnet`) | Radio | NOT STARTED | reconnect | |
| Keyboard sends Telnet specials (`CONF_telnet_keyboard`) | Checkbox | NOT STARTED | runtime | `telnet_reconfig` stores conf |
| Return sends Telnet New Line (`CONF_telnet_newline`) | Checkbox | NOT STARTED | runtime | |
| Rlogin local username (`CONF_localusername`) | Text field | NOT STARTED | reconnect | Panel hidden mid-session (`DISPLAY_NON_RECONFIGURABLE_PROTOCOL`) |
| SUPDUP location, ASCII set, MORE, scrolling (`CONF_supdup_*`) | Fields | NOT STARTED | reconnect | Panel hidden mid-session |

## Not in the Windows dialog but in `conf.h`

These keys are kept in the model for round-trip fidelity (D-004):
`CONF_remote_cmd2`, `CONF_ssh_subsys`, `CONF_ssh_subsys2`, `CONF_ssh_nc_host`,
`CONF_ssh_nc_port`, `CONF_ssh_simple`, `CONF_stamp_utmp`, `CONF_login_shell`,
`CONF_scrollbar_on_left`, `CONF_winclass`, `CONF_utf8_override`,
`CONF_sshbug_*` not exposed in the UI, `CONF_tcp_*` (shown above). Most are
`NOT_SAVED` or used only by plink/pterm. Their status is NOT APPLICABLE
unless a later milestone needs them.

## Process for keeping this complete

M12 adds a unit test that enumerates `conf_key_info[]` through the bridge
and fails if any key is missing from this document's key list. This keeps
the matrix exhaustive across upstream updates.
