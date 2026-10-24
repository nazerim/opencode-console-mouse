# Console + OpenCode copy/paste cheat sheet

Current stack: **gpm** (console pointer daemon) + **gpm2xterm** wrapper (`oc`)
+ **OpenCode v2**. Two clipboards exist; know which one a gesture feeds.

- **Clipboard A — kernel selection (gpm):** global across all tty1–tty6, held
  by the kernel, pasted via middle-click (TIOCLINUX injects as typed input).
- **Clipboard B — wrapper OSC 52:** per-`oc` session, held in gpm2xterm memory,
  filled by OpenCode's own copies, drained by Ctrl+V (bracketed paste).

## Copy

| What you want to copy | Gesture | Goes to |
|---|---|---|
| Text on any console screen (shell, vim, logs…) | left-drag (double-click = word, triple = line) | A |
| Text inside OpenCode (chat, diffs, prompt) | left-drag inside the TUI | A **and** B (parallel) |
| A word inside OpenCode | double-click | B (auto-copied by OpenCode) |
| Whole last assistant message | `Ctrl+X` then `Y` | B |

## Paste

| Where you're pasting | Key | Source | Multi-line? |
|---|---|---|---|
| Shell prompt (any VT) | middle-click | A (kernel buffer) | safe (it's just input) |
| **Another tty, from OpenCode** | drag in OpenCode → switch VT → middle-click | **A** | ⚠️ newlines submit |
| OpenCode prompt (in `oc`) | `Ctrl+V` | B (OSC 52) | **safe** (bracketed paste) |
| OpenCode prompt (in `oc`) | middle-click | A (kernel buffer) | **safe** — OpenCode's VT has ?2004 on, so the kernel bracket-wraps the paste and the wrapper forwards it to the app |

> **How it works:** the wrapper forwards mouse to OpenCode (in-app selection +
> OSC 52 **B** for `Ctrl+V`) *and* passes events through to gpm's own **root**
> selection handler (the kernel only lets root set the selection), so a drag
> also fills the kernel buffer **A** — which is what middle-click pastes on
> every VT, including OpenCode. One drag feeds both clipboards.
> Kernel-set regions are screen-scoped (only what's visible under the drag).

## Cross-device escape hatch

| From | To | How |
|---|---|---|
| Console screen (via SSH in Ghostty/Terminal) | Mac clipboard | **Shift+drag** (bypasses app mouse-grab, uses terminal's own selection/OSC 52) |
| Mac clipboard | console | no route — console has no inbound clipboard; type it or use a file |

## Other mouse/keyboard behavior (current stack)

| Gesture / key | Effect |
|---|---|
| Wheel | scrolls OpenCode chat inside `oc` (SGR wheel via wrapper). On bare shell VTs gpm does **not** wheel-scroll — use `Shift+PgUp/PgDn` (kernel scrollback) or `tmux` |
| Enter | submit in OpenCode |
| Shift+Enter / Ctrl+Enter | newline in OpenCode prompt (`oc` only — wrapper detects held modifier via kernel shift-state ioctl; the two are indistinguishable on the console) |
| `Ctrl+J` | newline (native OpenCode binding, works everywhere) |
| Right-click | extend selection (console level) / right-click event to app inside `oc` |
| Side buttons | unmapped (gpm knows only 3 buttons + wheel; consolation had forward=paste) |
| `Ctrl+X e` | compose long prompts in `$EDITOR` |
| `@file` | reference file contents instead of pasting |

## Failure map

| Symptom | Likely cause |
|---|---|
| No clicks at all in OpenCode | launched `opencode`, not `oc` (plain opencode under gpm gets no mouse) |
| Ctrl+V pastes nothing | clipboard B empty — copy something inside OpenCode first (drag/double-click/`Ctrl+X y`) |
| Middle-click pastes nothing | clipboard A empty — drag-select first; check `systemctl status gpm` |
| Screen/keyboard frozen in `oc` | wrapper stuck: `pkill -f gpm2xterm`, then `reset` |
| Debug trail | `GPM2XTERM_DEBUG=1 oc 2>/tmp/oc.log` → grep `gpm2xterm` |
