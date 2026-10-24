# opencode-console-mouse

Mouse + copy/paste + clipboard for **modern TUIs on the raw Linux console**
(tty1–tty6, no X/Wayland). Verified on Ubuntu 26.04 / kernel 7.0 with
[OpenCode](https://github.com/sst/opencode) v2, but `gpm2xterm` is
app-agnostic (any TUI that speaks xterm SGR mouse / OSC 52).

**TL;DR:** `sudo ./setup-phase2.sh`, then run your TUI as `oc …` — you get
clicks, drag-select, wheel, cross-tty copy (gpm), an OSC 52 clipboard with
`Ctrl+V`, and Shift/Ctrl+Enter newline. See `CHEATSHEET.md`.

> Based on, and fixing, upstream [RaphaelGF11/gpm2xterm](https://github.com/RaphaelGF11/gpm2xterm)
> (MIT-less at time of writing). Our wrapper is GPL-2.0+ (links libgpm). The
> upstream original file is intentionally not mirrored here.

## Status

- [x] **Phase 1 — DONE & RUNNING**: `consolation` installed & enabled (drag-select,
      copy, middle-click paste, wheel scroll, selection buffer shared across all
      VTs). Side buttons mapped: `BTN_SIDE`=extend selection, `BTN_EXTRA`=paste.
      See `setup-console-mouse.sh`. Clicks reach OpenCode via the kernel X10
      path (OpenCode sends `ESC[?1000h`; consolation forwards press/release as
      `ESC[M bxy`) — confirmed working by user.
- [x] **Phase 2 — FULLY WORKING** (user-confirmed via `/tmp/oc2.log`):
      clicks `<0`, drag `<32`, hover `<35`, wheel `<64/<65` all injected
      correctly; OSC52 copies captured; `Ctrl+V -> injected 52 byte paste`
      confirmed. gpm active/enabled, consolation disabled, `oc` launcher live.
      Debug trail: `GPM2XTERM_DEBUG=1 oc 2>/tmp/oc.log`.
- [x] **Phase 3 — Enter modifiers**: console sends identical `0x0D` for
      Enter/Shift+Enter/Ctrl+Enter (no CSI-u). Wrapper queries the kernel's
      live shift state (`TIOCL_GETSHIFTSTATE` = TIOCLINUX subcommand **6** —
      an early build wrongly used 12 = `GETFGCONSOLE`, whose VT-number reply
      collided with modifier bits and turned every Enter into newline) and
      translates a modified Enter to `ctrl+j` (OpenCode's `input_newline`).
      Layout-proof test: state != 0 means modified in any kernel version.
      Confirmed working: one message, two lines (Shift+Enter newline, Enter
      submit).

## Key findings (verified against kernel 7.0 source, consolation 0.0.10 source,
## gpm master source, and the opencode v2.1.4 binary)

1. The Linux console kernel VT implements only legacy mouse reporting: DECSET
   `?9`/`?1000` → emits `ESC[M bxy` when a daemon calls
   `TIOCLINUX/TIOCL_SETSEL/TIOCL_SELMOUSEREPORT`. No SGR (1006), no drag (1002),
   no wheel, no side buttons.
2. `consolation` (libinput) implements that forwarding natively via
   `TIOCL_GETMOUSEREPORTING`; it never forwards wheel (always console scroll).
   `gpm` (current) has **no** xterm-report code at all — gpm2xterm/lcxterm-style
   wrappers exist because of this.
3. OpenCode v2 TUI: embedded server (Bun/TS) + native-rendered TUI; requests
   `?1000/?1002/?1003/?1006` and parses both SGR (`ESC[<`) and X10 (`ESC[M`).
   Clipboard = OSC52 via a "native session" layer; probes capability via
   OSC52 query / XTGETTCAP `Ms` — the console never answers → `osc52_support:
   unsupported` → copy/paste become no-ops. Over SSH from Ghostty/Terminal both
   protocols are answered → everything works (that's the reference behaviour).
4. `/dev/gpmctl` is 0777 → non-root libgpm clients OK. `Gpm_Event` has
   `wdy` (wheel) and `clicks` fields (gpm.h 1.20.7 == master).

## Phase 2 details

`gpm2xterm/gpm2xterm.c` — rewrite of upstream gpm2xterm:
- SGR injection: press/release/drag(+32)/motion(35)/wheel(4/5) + modifiers.
- OSC52 emulation: stores copies, answers `?` queries → OpenCode gets a
  working clipboard on the console.
- XTGETTCAP: replies `Ms` capability → OpenCode marks osc52 supported.
- stdin EOF stops polling stdin but keeps relaying (fixed upstream bug).
- Build (no root needed): `prefix/` holds extracted libgpm-dev/libgpm2.
  `./gpm2xterm/build.sh` (fetches libgpm into `prefix/`, no root needed)
- Runtime requires **gpm** daemon (`setup-phase2.sh`); consolation is disabled
  while it's used to avoid double events. gpm server keeps console
  select/paste/scroll running in parallel (GPM_HARD defaultMask).
- Launch via `oc`: wraps `opencode` only when `TERM=linux` + `/dev/gpmctl`
  exists (console); plain `opencode` over SSH keeps native terminal mouse.
- TERM stays `linux` (16 colors — console has no truecolor; we deliberately
  do NOT advertise the `Tc` capability).
- Rollback: `sudo ./rollback-phase2.sh` (back to consolation).

### Gotchas / tuning knobs

1. **Why Ctrl+V needed wrapper-side emulation**: OpenCode's *terminal* clipboard
   provider implements only `writeText`/`clear` (OSC52) — its `read()` goes to
   the native OpenTUI/libghostty host clipboard service, which needs an OS
   clipboard or a Ghostty `1337;Capabilities` handshake. On the console it
   never sends an OSC52 query, so answering queries alone can't fix paste.
   The wrapper therefore intercepts Ctrl+V (0x16) and injects the stored OSC52
   copy as a bracketed paste (`\e[200~…\e[201~` when mode 2004 is on).
   OSC52 query replies are still implemented (helps other apps).
2. **libgpm xterm-mode**: with `TERM=xterm*`, `Gpm_Open()` writes its own
   `\e[?1001s\e[?1000h` to stdout and skips the socket — harmless on the
   console (`TERM=linux`) but pollutes output if run inside a graphical
   terminal. The `oc` launcher avoids wrapping there.
3. **Wheel encoding**: xterm SGR (and OpenTUI) use button **64 = wheel-up,
   65 = wheel-down** (the scroll bit), NOT 4/5 (those are legacy X10-only).
   Sending 4/5 made OpenCode treat each tick as a left click (→ double-click →
   word-select → copy). Fixed to 64/65. If vertical direction feels inverted,
   flip the ternary in `forward_gpm_event()` (`wdy > 0 ? 64 : 65`).
4. **Who sets the kernel selection (critical)**: the kernel requires
   `CAP_SYS_ADMIN` for `TIOCL_SETSEL` (selection.c `set_selection_user`), so
   the **non-root wrapper cannot** set the console selection — it EPERMs and
   the buffer silently freezes at its last value. Therefore the wrapper
   connects with `defaultMask = GPM_HARD | MOVE|DRAG|DOWN|UP` so gpm's **own
   root selection handler also runs** on every event. Result: a drag inside
   OpenCode updates BOTH OpenCode's in-app selection (via our SGR, feeds the
   OSC52/`Ctrl+V` clipboard) AND the kernel selection buffer (via gpm, feeds
   middle-click on other VTs). Gotcha: `defaultMask=GPM_HARD` alone (what the
   original gpm2xterm used) *consumes* events from the daemon — that both
   froze the kernel buffer (stale paste) and disabled middle-click.
   Side effect: gpm draws its own reverse-video selection highlight over the
   OpenCode screen; harmless, cleared by the next 1-cell click/drag.
5. **Stuck `?2004` poisons console paste**: kernel `paste_selection()` wraps
   the paste in `\e[200~…\e[201~` whenever the TARGET vt has DECSET `?2004`
   on. A killed TUI (SIGKILL — no cleanup written; `reset` doesn't clear it
   either) leaves the vt stuck → middle-click on that vt shows raw marker
   garbage. Manual unstick: `printf '\e[?2004l' > $(tty)`. The wrapper now
   writes `?2004l ?1003l ?1002l ?1000l ?1006l` at startup and on exit so it
   self-heals its own vt.
6. Test harness: `fakeapp.c` = minimal OSC52 client (copy → Ctrl+V → assert
   bracketed-paste injection).

## Files

- `setup-console-mouse.sh` — phase-1 installer (consolation; alternative setup).
- `setup-phase2.sh` — phase-2 installer (gpm + gpm2xterm + `oc` launcher).
- `rollback-phase2.sh` — undo phase 2, back to consolation.
- `bpcheck.c` — diagnostic: per-vt `?2004`/shift-state flags (`TIOCL_GETBRACKETEDPASTE`).
- `gpm2xterm/gpm2xterm.c` — our wrapper (GPL-2.0+; based on, and fixing,
  upstream RaphaelGF11/gpm2xterm — note: upstream has no license at the time
  of writing; upstream original kept out of this repo).
- `gpm2xterm/build.sh` — standalone build (fetches libgpm into `prefix/`, no root).
- `gpm2xterm/fakeapp.c` — headless test harness (OSC52 copy → Ctrl+V →
  assert bracketed-paste injection).
- `PR_BODY.md` — upstream PR description.
- `publish.sh` — one-shot: push repo + fork + open the upstream PR (needs `gh auth login`).
