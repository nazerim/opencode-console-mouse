# AGENTS.md — handoff for whoever (or whichever agent) picks this up next

You are likely in `/home/naz/Projects/opencode-console-mouse`, possibly the
session that built this. Everything was verified on: **Ubuntu 26.04, kernel
7.0.0, OpenCode v2.1.4 (OpenTUI/libghostty TUI), physical console on a
2560x1440 DP monitor (32", card2-DP-6), KMS fbcon, user `naz` (in sudo
group, needs password — you cannot `sudo` non-interactively; ask the human
to run root steps or paste the output).** Console geometry: **Terminus
11x22** bitmap font = 232x65 cells with 10px bottom slack (chosen over the
compact Fixed 8x16 and other candidates; `/etc/default/console-setup` is the
source of truth, applied via `setupcon`). Gotcha: `setupcon --force` applies
live but does NOT rewrite the boot cache — persist with `setupcon --force
--save` (the cached scripts under /etc/console-setup are what boot replays).

GitHub: `nazerim` via `~/.local/bin/gh` (authenticated;
`gh auth setup-git` done, so git pushes work from your shell tool).

## Read first

`KNOWLEDGE.md` is the full technical deep-dive (console stack, mouse/
clipboard/paste/font internals, protocol tables, the bug museum, what can
never work on a VT). This file is the operational handoff; KNOWLEDGE.md is
the "why". Don't change code without reading it.

## What this is (2 sentences)

`gpm2xterm` wraps a TUI inside a pty and emulates the parts a graphical
terminal provides that the Linux console can't: SGR mouse (clicks/drag/wheel),
OSC 52 clipboard (+ XTGETTCAP `Ms`), Ctrl+V paste injection, and modified-Enter
translation — while letting gpm (running as root) keep console selection/paste
working. The `oc` command launches any command wrapped, console-only.

## Current live state (verify with these, all non-root)

```
systemctl is-active gpm consolation          # expect: active inactive
ls -l /usr/local/bin/gpm2xterm /usr/local/bin/oc /etc/gpm.conf
/usr/local/bin/gpm2xterm 2>&1 | head -1      # "Usage: ... " line = binary intact
git log --oneline -3
```

Deployed binary now matches the committed source exactly (md5 `0542dd1…` on
both `gpm2xterm/gpm2xterm` and `/usr/local/bin/gpm2xterm`, wheel press-only
fix included).
After any edit to `gpm2xterm/gpm2xterm.c`, re-deploy with (ask the human):

```
./gpm2xterm/build.sh && sudo ./setup-phase2.sh
```

The script auto-rebuilds on missing/stale artifacts and aborts unless the
installed md5 matches the build — trust its `gpm2xterm installed: <md5>` line.

## Day-to-day usage (the human's workflow)

- Console TUI: `oc` / `oc -c` (only wraps when `TERM=linux` + gpm socket).
- Copy: drag/double-click inside `oc` (feeds OpenCode's OSC52 clipboard AND
  gpm's kernel selection buffer simultaneously).
- Paste: `Ctrl+V` in-app; middle-click anywhere, any VT.
- `Ctrl+X y` copies the last message in OpenCode; `Shift/Ctrl+Enter` = newline,
  `Enter` = submit. Full table: `CHEATSHEET.md`.

## Debug playbook (when "X stopped working")

1. Capture: `GPM2XTERM_DEBUG=1 oc 2>/tmp/oc.log` (human runs it on the
   console; reproduce; `Ctrl+X q`; then you read `/tmp/oc.log`).
2. Interpret the trace:
   - no `mouse: 1000=1…` → app never enabled mouse → app-side/TERM issue.
   - `gpm ev …` missing → gpm daemon dead or client dropped:
     `systemctl restart gpm` (root), check `/dev/gpmctl` (must be 0777).
   - `-> SGR` present but app unresponsive → protocol mismatch in the app,
     not the wrapper.
   - stale text on other VT → check `defaultMask` still lists event types
     (this is the #1 regression trap, see README gotcha 4).
   - paste garbage with `[200~` on a shell VT → stuck `?2004`:
     `gcc -O2 -o bpcheck bpcheck.c && ./bpcheck < /dev/ttyN`; unstick:
     `printf '\e[?2004l' > $(tty)`.
3. Headless regression (no console needed, run anywhere):
   ```
   cd gpm2xterm && ./build.sh && gcc -O2 -o fakeapp fakeapp.c &&
   (sleep 0.5; printf '\026'; sleep 1) | TERM=linux ./gpm2xterm ./fakeapp >/dev/null 2>/dev/null;
   xxd resp.bin   # expect: osc52 query reply + 1b5b 3230 307e ... 1b5b 3230 317e
   ```

## Hard-won constraints — do NOT re-litigate these

- Kernel VT: DECSET 9/1000 only; X10 `ESC[M` output; **no** SGR/drag/wheel/side
  buttons natively (verified in vt.c/selection.c/keyboard.c at 7.0).
- `TIOCL_SETSEL` needs **CAP_SYS_ADMIN** (post-2023 kernel) → non-root wrapper
  can never set the selection; gpm-as-root must do it (pass-through defaultMask).
- Console `shift_state` bit layout changed again recently (keymap weights:
  Shift=1 AltGr=2 Ctrl=4 Alt=8 ShiftL=16…). Enter test uses `state != 0`, not
  bits — keep it that way.
- SGR wheel = **64/65**, never 4/5 (4/5 decodes as clicks in SGR).
- OpenCode's clipboard read never emits an OSC52 query on the console (terminal
  provider has no read(); native read wants OS clip / Ghostty caps) → Ctrl+V
  must be answered wrapper-side with bracketed paste.
- libgpm `Gpm_Open` in `TERM=xterm*` writes junk to stdout — never run the
  wrapper outside `TERM=linux` (the `oc` launcher enforces this).
- `Gpm_GetEvent` blocks — never drain-loop it; one event per select() pass.
- gpm does not know buttons beyond 3+wheel → side-button mapping only exists
  in the consolation path (rollback script restores it).
- Console has no truecolor (`Tc` deliberately unanswered), TERM stays `linux`.

## Upstream PR status & how to iterate

- PR: **RaphaelGF11/gpm2xterm #1** — https://github.com/RaphaelGF11/gpm2xterm/pull/1
  (opened 2026-10-24 by nazerim). State at handoff: **OPEN, 0 comments,
  0 reviews**; upstream repo dormant since ~2026-09-25 (owner active
  elsewhere); last upstream push 2026-01-07.
- Check for movement:
  ```
  gh pr view 1 --repo RaphaelGF11/gpm2xterm --json state,comments,reviews --jq '.state'
  gh pr view 1 --repo RaphaelGF11/gpm2xterm --json comments --jq '.[].body'
  ```
- If the maintainer requests changes: edit `gpm2xterm/gpm2xterm.c` here (source
  of truth), run the fakeapp regression, then `./pr-upstream.sh` — it is
  idempotent and force-updates the PR branch.
- Upstream has **no LICENSE**; we offered GPL-2.0+ (dual-MIT possible) in the
  PR body. If he adds one, note it in our README header block.

## Public repo

https://github.com/nazerim/opencode-console-mouse (public, master). Commit
convention: normal messages are fine; the pre-auth placeholder was already
re-author'd to the noreply identity.

## Open TODO / ideas (nice-to-have, unranked)

- [ ] Watch PR #1 (and optionally post the repo to OpenCode Discord/HN "show");
- [ ] `oc` + `tmux` combo untested (tmux as the wrapper child should work:
      wrapper feeds tmux SGR; tmux redistributes to panes).
- [ ] Consider an AUR/PPA/deb packaging if upstream stays silent.
- [ ] `scroll_speed` / `scroll_acceleration` in `~/.config/opencode/tui.json`
      if wheel speed feels wrong (app-side knob, not wrapper).
- [ ] If future apps use **SGR alternate mouse (1005/1006-only)** quirks,
      extend `send_sgr` — current output is standard `CSI < b ; x ; y M/m`.
- [ ] Optional: a `disable-paste`-style hardening note if the human ever runs
      untrusted TUIs (any app could read the kernel selection via paste).

## Files map

README.md (deep findings + gotchas) · CHEATSHEET.md (usage tables) ·
gpm2xterm/ (source, build.sh, fakeapp.c) · setup-console-mouse.sh (phase 1) ·
setup-phase2.sh / rollback-phase2.sh (deploy/undo, need sudo) · pr-upstream.sh
(update PR) · publish.sh (one-shot publish+PR) · bpcheck.c (vt flags) ·
PR_BODY.md (PR text).
