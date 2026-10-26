# Fix console selection/paste, wheel mapping, parser robustness + OSC 52 clipboard

Hi! Used your project as the base for a full "mouse + clipboard" setup for modern
TUIs on the Linux console (target app: OpenCode v2 / OpenTUI). In the process I
found and fixed a set of real bugs, and added a few features. Details below —
happy to split this into smaller PRs if you prefer.

## Bug fixes

1. **`defaultMask = GPM_HARD` alone consumes events from gpm's own selection
   handler.** In gpm's `do_client()`, `res = !(defaultMask & event->type)` —
   with `defaultMask = GPM_HARD` (256) it returns "handled", so
   `do_selection()` never runs: middle-click paste dies, and the kernel
   selection buffer freezes at its last value (stale pastes on other VTs).
   Listing the event types (`GPM_HARD | GPM_MOVE|GPM_DRAG|GPM_DOWN|GPM_UP`)
   makes events fall through to the daemon again. This also matters for a
   second reason: the modern kernel requires `CAP_SYS_ADMIN` for
   `TIOCL_SETSEL` (`set_selection_user()`), so only gpm's root daemon can
   update the console selection — a non-root client silently gets `EPERM`.

2. **Wheel events were not mapped.** gpm delivers wheel as `GPM_MOVE` with
   `wdy = ±1` (and `buttons = GPM_B_NONE`). The old code ignored `wdy`
   entirely; whatever leaked through produced bogus left-clicks. Fixed to
   emit SGR **64/65** (xterm's scroll-bit convention — what Ghostty-class
   parsers expect; note 4/5 is legacy-X10-only and decodes as
   button-1/2 press in SGR, which apps treat as clicks → double-click
   selection spam) — and as a **press with no `m` release**: a trailing
   `\e[<64m` re-decodes as `64&3=0` (left-release) in strict parsers
   (observed with OpenTUI), pairing with the press into a phantom
   synthesized *click* at the cursor.

3. **DECSET detection used `strstr` over raw chunks**: broke on
   multi-parameter sets (`\e[?1000;1002;1006h`), sequences split across
   `read()` boundaries, and matched `1000` inside `2004` etc. Replaced with a
   small state machine (rolling carry buffer, proper OSC/DCS framing,
   bare-ESC termination).

4. **stdin EOF tore down the relay** (`read()==0` → `break`), killing output
   when stdin is a pipe; and on a raw tty `read()==0` means "no data", not
   EOF — the old logic would permanently disable the keyboard.

5. **Non-blocking hazard**: any `while (Gpm_GetEvent() > 0)` drain loop
   blocks forever on the final `read()` (the socket is blocking) — froze the
   whole relay on the first mouse event. One event per `select()` iteration.

## New features

- **OSC 52 clipboard emulation**: stores the app's copies, answers `?`
  queries, and replies to the `XTGETTCAP +q4d73` ("Ms") capability probe —
  so capability-gated apps (OpenCode v2 checks `osc52_support`) enable
  clipboard features on the console.
- **Ctrl+V handled wrapper-side**: many modern apps only ever *write* OSC 52
  (their read path wants an OS clipboard or a Ghostty `1337;Capabilities`
  handshake). The wrapper intercepts a lone `Ctrl+V` (0x16) and injects the
  stored clipboard as a bracketed paste — multi-line-safe.
- **Enter translation**: the console sends identical `0x0D` for Enter /
  Shift+Enter / Ctrl+Enter (no CSI-u/kitty). The wrapper queries the kernel's
  live shift state (`TIOCL_GETSHIFTSTATE`) and maps a modified Enter to
  `ctrl+j` (newline in most prompt UIs). Layout-proof: tests state != 0
  instead of hard-coded bits (the kernel renumbered the modifier bits).
- **Stuck-mode cleanup**: writes `?2004l ?1003l ?1002l ?1000l ?1006l` at
  startup and exit. Without this, a killed TUI leaves `?2004` on the
  foreground vt, which makes the kernel wrap **every** console paste
  (gpm middle-click) on that vt in `\e[200~…\e[201~` — raw garbage at a
  plain shell prompt.
- `GPM2XTERM_DEBUG=1` traces: mouse-mode detection, gpm events, exact SGR
  bytes emitted, OSC52/XTGETTCAP activity, Enter translations.

## Testing

- Live on Ubuntu 26.04 / kernel 7.0, physical console (tty1), with OpenCode
  v2.1.4 (OpenTUI/libghostty renderer): clicks, drag-select, wheel both
  directions, OSC 52 copy → `Ctrl+V` paste (incl. multi-line), cross-tty
  middle-click paste (OpenCode selection → shell prompt, UTF-8 intact),
  Shift/Ctrl+Enter newline vs Enter submit.
- `fakeapp.c` regression harness (in my downstream repo) asserts the OSC52
  round-trip and bracketed-paste injection headlessly.

## License note

This repo has no license file, so legally the default is "all rights
reserved" — worth adding one (GPL-2.0+ would match libgpm). My contribution
here is offered under GPL-2.0-or-later (dual-MIT possible at your discretion).
