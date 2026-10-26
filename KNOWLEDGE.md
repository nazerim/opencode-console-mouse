# The Linux Text Console, Understood — a field guide

Knowledge distilled while building `opencode-console-mouse` (Ubuntu 26.04,
kernel 7.0, OpenCode v2 / OpenTUI). Everything here was verified against
kernel source, daemon source, live binaries, or hands-on testing at the
console. Written so nobody re-derives it the expensive way.

---

## 1. The shape of the stack

```
kernel: drivers/tty/vt/*          userspace                     app
─────────────────────────         ────────────────────          ────
vt.c        terminal emulator     gdm (absent) ← X/Wayland      vim, opencode, …
keyboard.c  keymap+shift_state    gpm / consolation / jamd      read stdin as
selection.c screen copy/paste       (read /dev/input, own       "a terminal"
vc_screen   primary+alt buffers     the *root* privileges)
fbcon/KMS   pixels to monitor     agetty → bash → tmux
```

* The VT layer *is* a terminal emulator — a small, fossilized one: DECSET
  subset, 16 colors, PSF bitmap fonts, 8192-row scrollback, and a
  selection/paste unit that is *global* (one `vc_sel` for all VTs, which is
  why cross-tty middle-click works).
* On modern GPUs this renders through KMS (`drivers/gpu/drm` + `video=efifb`
  fallback) — a high-res text grid that looks GUI-grade. Resolution comes
  from the monitor's preferred mode; console cols/rows = resolution ÷ font
  size. Check: `stty size` on the VT, `/sys/class/graphics/fb0/virtual_size`.
* "GNOME is running" is often cargo-cult: `graphical.target` as default does
  not mean a desktop exists — check `loginctl` session Type (tty vs x11/
  wayland) and the existence of `display-manager.service`.

## 2. What the console terminal actually implements

| Feature | Status | Notes |
|---|---|---|
| 16-color SGR | ✅ | `TERM=linux` |
| 256-color / truecolor | ❌ | kernel palette is 16 + AEC; `?2004`… see below |
| Alt screen `?1049`, save/restore | ✅ | implemented via `vc_saved_screen` in vt.c |
| DECSET **9** (X10 mouse) | ✅ | sets `vc_report_mouse=1` |
| DECSET **1000** (VT200 mouse) | ✅ | sets `vc_report_mouse=2` → also enables release reports |
| DECSET 1002/1003 (drag/any-motion) | ❌ | ignored (parsed as no-op) |
| DECSET **1006** (SGR mouse) | ❌ | ignored |
| DECSET 2004 (bracketed paste) | ✅* | *app-side*: tracked flag makes **kernel pastes** wrap in `\e[200~…\e[201~`; the kernel does not *emit* brackets for typed input |
| Mouse **reports** (X10) | ✅† | †only when a daemon injects them (next section) |
| OSC 52 clipboard | ❌ | silently swallowed; the *selection buffer* is the console's only clipboard |
| XTGETTCAP / DA1 responses | partial | no `Ms` support; DA1 answers `ESC[?6c`; `CSI 6n` CPR works |
| Kitty keyboard protocol, modifyOtherKeys | ❌ | hence: **no Enter+modifier distinction** |

## 3. Console mouse: the only sane architecture

The kernel gets **no mouse events by itself** (historically it could via
`gpm`-era hacks; today vt.c still has `mouse_report()`). The working chain:

```
/dev/input/event* → daemon (gpm/consolation, runs as root)
    │  1. asks the kernel: "does the foreground VT want mouse?"
    │     ioctl(fd, TIOCLINUX, TIOCL_GETMOUSEREPORTING /*7*/) → 0 | 1(9) | 2(1000)
    │  2. if yes, injects each event:
    │     ioctl(fd, TIOCLINUX, TIOCL_SETSEL + struct tiocl_selection
    │           {xs,ys,xe,ye, sel_mode = TIOCL_SELMOUSEREPORT|button})
    ▼
kernel mouse_report() writes  ESC [ M  (0x20+b) (0x21+x) (0x21+y)   into tty input
    ▼
app's stdin receives X10-style reports (press b=0/1/2, release b=3)
```

Consequences of this design:

* Only **3 buttons + release**, coords ≤ 223 (older) — no drag, no wheel,
  no side buttons can ever cross the kernel path, whatever the daemon is.
* **`TIOCL_SETSEL` requires `CAP_SYS_ADMIN`** (since ~2024 — `set_selection_user()`
  in selection.c; previously "same_owner()"). Only the **root daemon** (or a
  root-launched process) can set the selection buffer; non-root clients EPERM
  **silently**. This is the #1 modern trap: stale console "clipboard" bugs.
* `TIOCL_GETSHIFTSTATE` is **6** (not 12; 12 is `TIOCL_GETFGCONSOLE`, which
  answers a VT *number* into your buffer — indistinguishable from modifier
  bits and thus a hilarious bug generator).
* shift_state bit layout changed (kernel ≥6.13-ish): modern weights are
  Shift=1, AltGr=2, Ctrl=4, Alt=8, ShiftL=16, ShiftR=32, CtrlL=64, CtrlR=128
  (keymaps(5)); the legacy layout was LSHFT=1,RSHFT=2,ALT=4,CTRL=8.
  **Test `state != 0`**, never specific bits.

### The daemons

| | gpm | consolation | jamd |
|---|---|---|---|
| input backend | own (mice/exps2/…) | **libinput** | libinput |
| console selection/paste | ✅ | ✅ | ✅ |
| wheel scrollback | ❌ (not in `do_selection`; use Shift+PgUp) | ✅ | ✅ |
| forwards mouse to apps | ❌ (X10 code absent from current tree!) | ✅ (X10 press/release only) | ✅ |
| gpm client API (`/dev/gpmctl`, 0777) | ✅ libgpm | ❌ (uses TIOCL path, no socket) | ❌ |
| side-button mapping | ❌ (3 buttons only) | ✅ `--map 'BTN_SIDE=paste'` | — |
| state | stalled (1.20.7) | packaged in Ubuntu | packaged in Debian |

### gpm client API traps (the `defaultMask` truth)

`libgpm` clients connect to `/dev/gpmctl` (world-writable) and send
`Gpm_Connect { eventMask, defaultMask, minMod, maxMod, pid, vc }`.
In `do_client()`:

```c
res = !(defaultMask & event->type);       // "should the daemon's own
                                          //  selection handler ALSO run?"
... write(client_fd, event);
return (defaultMask & GPM_HARD) ? res : 1;
```

* `defaultMask = 0` → event delivered to client **and** daemon handler runs
  (classic selection co-existence).
* `defaultMask = GPM_HARD` alone → **consumed**: daemon selection dies
  (middle-click paste stops, selection buffer freezes — silently, see §5).
* `defaultMask = GPM_HARD | MOVE|DRAG|DOWN|UP` → client gets events *and*
  falls through: daemon keeps selection/pointer/paste. **This is the
  documented-in-none-the-places configuration gpm2xterm needs.**
* `Gpm_GetEvent()` does a blocking `read()` — **never drain-loop it**; one
  event per `select()` pass (a while-loop hangs the whole pty relay on the
  final empty read — this froze the screen on first mouse move).
* libgpm switches to "xterm mode" when `TERM=xterm*`: Gpm_Open writes its
  own enable sequences to stdout and bypasses the socket — so any wrapper
  must only run under `TERM=linux` (guard in the `oc` launcher).

## 4. Mouse protocols — the table that matters

| Event | legacy X10 (`ESC [ M b x y`, b=code+0x20) | SGR (`ESC [ < b ; x ; y M/m`) |
|---|---|---|
| left/middle/right press | 0/1/2 | 0/1/2 `M` |
| release | 3 | same-code `m` (or 3 in *X10* — SGR keeps the button!) |
| **wheel up / down** | **4 / 5** | **64 / 65** ← (scroll bit 0x40) — NOT 4/5; SGR 4/5 decodes as left+release → apps see *clicks*. **Press-only**: a trailing `\e[<64;x;ym` re-decodes as `64&3=0`=left-release in strict parsers → pairs with the press into a *synthesized click at the cursor* (OpenCode toggled collapsible blocks per tick). Ghostty-class terminals send wheel as a press with no release. |
| drag (cell motion, 1002) | n/a | 32+btn `M` |
| any-motion (1003) | n/a | 35 `M` |
| modifiers | +4 shift +8 meta +16 ctrl | same, ORed into b |

Modern apps (Bubble Tea, OpenTUI, Zig/ghostty-vt, textual…) enable
`?1000;1002;1006` and parse SGR; many *also* still parse X10 (`ESC[M`).
The console kernel only ever produces X10. A wrapper (gpm2xterm) is what
bridges rich app expectations to gpm events:

```
gpm event: type∈{MOVE,DRAG,DOWN,UP}, buttons∈{4:L,2:M,1:R}, wdy=±1 (wheel!)
SGR out:   DOWN→<b;…M   UP→<b;…m   DRAG→<b+32;…M   MOVE→<35;…M   wdy→<64/65;…M (press only!)
```

## 5. Clipboard — three clipboards, none of them "the clipboard"

1. **Kernel selection buffer** (`vc_sel`): filled only by `TIOCL_SETSEL`
   (CAP_SYS_ADMIN) from *screen regions*; drained by `TIOCL_PASTESEL`,
   which **wraps in `\e[200~…\e[201~` if the target vt has `?2004` on**
   (paste_selection() in selection.c) — so a stuck `?2004` (killed TUI, no
   cleanup; `reset` does *not* clear it) turns every shell paste into
   marker garbage. Unstick: `printf '\e[?2004l' > $(tty)`.
2. **OSC 52**: app → terminal ("the terminal is the clipboard").
   `ESC]52;<codes>;<b64|?> BEL|ST`. `?` = query — a terminal that supports
   *read* replies with its buffer. Graphical terminals relay to the OS
   clipboard; the console answers nothing → apps that *probe* (OpenCode
   checks `osc52_support`, derived from query reply / XTGETTCAP `Ms`
   = `ESC P + q 4d73 ST` → `1b5d3532...07` hex for `ESC]52;%p1%s;%p2%s BEL`)
   conclude "unsupported".
3. **App-internal clipboard**: OpenCode v2's *terminal provider* implements
   `writeText`/`clear` but **no `read()`** — its paste reads via the native
   libghostty/OpenTUI clipboard service (OS clipboard or Ghostty's
   `1337;Capabilities` handshake). On a raw VT that path has nothing to
   talk to → `Ctrl+V` sends **no OSC52 query at all**. Lesson: emulating
   "answer OSC52 queries" is not enough for paste; **the wrapper must
   answer the keystroke**: intercept `Ctrl+V` (0x16) and inject
   `\e[200~ + b64decode(stored copy) + \e[201~` itself.

**Debugging truth:** the buffer contents are verifiable without trusting
your eyes — `cat > /tmp/paste.bin` + paste + `xxd` distinguishes "kernel
wrapped markers" (`1b 5b 32 30 30 7e`) from "literal garbage characters
that happen to look like markers" (`6b 5b 32 30 30 7e` — a user-selected
snippet of a chat discussing `[200~`, which is exactly how one session
here was chased in circles; Unicode arrows survived because the selection
copy is UTF-8 aware).

## 6. Keyboard: the Enter problem

`Enter`, `Shift+Enter`, `Ctrl+Enter` are **identical bytes** (`0x0D`) on a
VT; `Alt+Enter` differs only because Meta prepends `ESC`. CSI-u / kitty
protocol do not exist there. Wrapper-side fix that works:

1. read a lone `0x0D` from stdin,
2. instantly `ioctl(TIOCLINUX, TIOCL_GETSHIFTSTATE /*6*/)` on the tty,
3. if result ≠ 0 → a modifier was physically held → rewrite the keystroke
   to something the app maps to newline (`0x0A` = `ctrl+j`, near-universal
   in readline-family apps), else pass through (submit).

Race-free in practice (key release is ms-slow, ioctl is µs). Bonus truth:
the console's `console-setup`/`setupcon` font stack (§7) has nothing to
do with this; the kernel simply *cannot* distinguish those Enters — the
problem is unsolvable app-side and trivially solvable wrapper-side.

## 7. Console fonts & geometry (console-setup)

* Formats: **PSF1/PSF2** bitmaps only (`/usr/share/consolefonts/*.psf.gz`,
  PSF2 = `0x86 'Arr'` + u32 height/width); TTF/OTF **cannot load**; no
  antialiasing, no ligatures. Conversion exists (`psfconfromttf`) but
  quality at 1440p is mediocre.
* Naming: many families name files **HxW** (`Terminus22x11` = 11 wide ×
  22 high) while console-setup config says `FONTSIZE="11x22"` = WxH.
  Parse PSF2 headers before trusting either.
* Ubuntu ships ~750 faces: Terminus (8x12…16x32 + Bold), Fixed
  (8x13…8x18), Goha/GohaClassic (8x12/14/16), VGA, **DejaVu** (16x30
  through 64x118 — yes, the bitmap of *the* DejaVu Sans Mono), Unifont.
  `fonts-spleen` (apt) adds the modern programmer bitmap (8x16, 12x24…).
* Fit math matters: at 2560×1440, h=16/20/24/32 divide evenly → last row
  **flush to the panel edge** (looks clipped on some monitors); h=22 and
  28 leave 10/12px slack. 320×90 @8x16 on 32″ ≈ 5pt — that was the real
  "last line disappearing".
* **Three-layer persistence** (all must agree):
  1. `/etc/default/console-setup` (FONTFACE/FONTSIZE/CODESET/CHARMAP) —
     the source of truth for reconfigures;
  2. **live application**: `sudo setupcon --force`;
  3. **boot cache**: `/etc/console-setup/cached_setup_font.sh` — what
     `console-setup.service` replays at boot. ⚠️ **`--force` does NOT save
     it; you need `sudo setupcon --force --save`** or the font silently
     reverts on reboot. Verify: `grep psf /etc/console-setup/cached_setup_font.sh`.
* `dpkg-reconfigure console-setup` only lists valid combos (guided picker,
  works on the text console itself).

## 8. What will NEVER work on the raw VT (stop chasing)

| Desire | Why impossible |
|---|---|
| Truecolor / 256-color | 16-entry palette in hardware-emulated CGA legacy; no palette API for apps |
| CSI-u / modified Enter *native* | no protocol support in kernel VT |
| Drag-motion mouse *through the kernel path* | vt.c has only modes 9/1000; daemon can only inject X10 |
| Side buttons in apps | X10/SGR protocols both only carry 3 buttons + wheel; kernel ioctl only 1/2/3 |
| OSC52 *relay to a system clipboard* | there is no system clipboard; kernel ignores OSC entirely |
| Scrollback of alt-screen content | scrollback belongs to primary buffer; alt-screen apps must implement their own (hence keyboard scroll bindings matter) |
| Font antialiasing/TrueType | PSF bitmaps only |

(All of these work *one layer up*: any graphical terminal, or a
Wayland/X session — which is what makes the console rig a niche bridge,
not a replacement.)

## 9. The bug museum (what actually bit us, symptom → cause)

1. `oc` hangs on launch, screen frozen → `while (Gpm_GetEvent())` drain
   loop; blocking socket read after last event stalls the relay.
2. Clicks worked, then stopped entirely → wrapper still consumed events
   (`defaultMask=GPM_HARD` alone) *and* old build mis-detected DECSET
   (`strstr` scan; combined `?1000;1002;1006h` never registered).
3. Wheel scrolled nothing / later "wheel = double-click copy" → gpm
   delivers wheel as MOVE+`wdy` (upstream ignored it), and SGR wheel codes
   are **64/65**, not 4/5.
4. Cross-tty paste stuck on stale text (hours-old selection, UTF-8 "k[200~"
   red herring) → `TIOCL_SETSEL` now needs **CAP_SYS_ADMIN**; non-root
   wrapper EPERMs *silently*; fixed by daemon pass-through defaultMask.
5. Every plain Enter became a newline → used `TIOCL_GETSHIFTSTATE`=12;
   real value is **6**, and 12 returned the *VT number* into the byte.
6. Middle-click pasted `k[200~k~` garbage → stuck `?2004` on a VT left by a
   SIGKILLed TUI (reset doesn't clear it) — kernel wrapped all pastes; and
   partly a false positive: they really *had* selected that literal string.
7. Font reverted after reboot → `setupcon --force` applies but does not
   rewrite `/etc/console-setup/cached_*`; `--save` is mandatory.
8. Meta keys: raw console sends Alt as `ESC <key>` — fine — but `Ctrl+Alt+F`
   letters are VT switches; bind app scroll away from those.
 9. Wheel scrolled fine but each tick also **toggled collapsible blocks**
    (thoughts/tools expanded-closed on their own) -> the trailing
    `\e[<64;x;ym` release decoded as `64&3=0` = left-button-release, which
    strict parsers (OpenTUI) pair with the press into a synthesized click at
    the cursor. Fix: emit wheel as a **press-only** `\e[<64/65M` (as
    Ghostty-class terminals do). Lesson: any "scroll-bit" event must not be
    sent with an `m` release.
10. "Applied the fix, restarted, *same bug*" → the deploy had silently kept
    the **stale binary** (build artifact deleted/older than source; the
    installer's `install` line no-op'd or errored mid-run). Fix procedure is
    now mechanical: after every deploy verify `md5sum
    /usr/local/bin/gpm2xterm gpm2xterm/gpm2xterm` match (setup-phase2.sh now
    auto-builds on missing/stale artifact and aborts on hash mismatch).

## 10. How to learn more than this document (read the sources)

* Kernel: `drivers/tty/vt/{vt.c,selection.c,keyboard.c}` — all answers to
  §2–§5, small and readable; `git.kernel.org` plain URLs fetch them.
* `man 4 console_codes` + `xterm ctlseqs` + invisible-island +
  terminalguide.namepad.de — protocol semantics.
* gpm master tree (`src/daemon/do_client.c`, `do_selection.c`,
  `selection_paste.c`) — the only real docs of the client API.
* Console apps with native mouse (btop, links, emacs, mc) are precedents
  for what "works" means here.
* `GPM2XTERM_DEBUG=1 oc 2>/tmp/oc.log` + `bpcheck` + the `fakeapp`
  headless harness = the project's own instrumentation.

*— maintained in `/home/naz/Projects/opencode-console-mouse`, 2026-10-25*
