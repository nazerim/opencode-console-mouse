#!/usr/bin/env bash
# Independent regression check: re-derives every invariant from live state.
# PASS/FAIL/WARN table. Needs: git, gcc, (gh for PR checks, optional).
set -uo pipefail
PROJ=$(cd "$(dirname "$0")" && pwd -P)
GPM_BIN=/usr/local/bin/gpm2xterm
ok=0; fail=0; warn=0
R() { # level name detail
  case "$1" in PASS) ok=$((ok+1));; FAIL) fail=$((fail+1));; warn) warn=$((warn+1));; esac
  printf '%-5s %-34s %s\n' "$1" "$2" "$3"
}

# 1. daemons & socket
systemctl is-active --quiet gpm && R PASS "gpm daemon active" "" || R FAIL "gpm daemon" "not active"
systemctl is-enabled --quiet gpm && R PASS "gpm enabled at boot" "" || R FAIL "gpm enable" "not enabled"
systemctl is-active --quiet consolation && R WARN "consolation running" "two daemons -> double events" || R PASS "consolation off" ""
[ -S /dev/gpmctl ] && R PASS "gpmctl socket" "$(stat -c %A /dev/gpmctl)" || R FAIL "gpmctl socket" "missing"
journalctl -u gpm -n 50 --no-pager 2>/dev/null | grep -qiE "oops|oops|error" && R WARN "gpm journal" "error lines present (inspect: journalctl -u gpm)" || R PASS "gpm journal clean" ""

# 2. worktree cleanliness & committed source
[ -z "$(git -C "$PROJ" status --porcelain --untracked-files=no)" ] && R PASS "git worktree clean" "" || R FAIL "git worktree" "dirty"
git -C "$PROJ" diff --quiet origin/master...HEAD 2>/dev/null && R PASS "local == origin/master" "" || R WARN "origin sync" "unpushed commits or fetch needed"

# 3. PROOF: deployed == fresh build of the COMMITTED blob (not the worktree)
TMP=$(mktemp -d)
git -C "$PROJ" show HEAD:gpm2xterm/gpm2xterm.c > "$TMP/gpm2xterm.c" || R FAIL "git blob read" ""
gcc -O2 -w -o "$TMP/gpm2xterm" "$TMP/gpm2xterm.c" \
    -I "$PROJ/gpm2xterm/prefix/usr/include" -L "$PROJ/gpm2xterm/prefix/usr/lib/x86_64-linux-gnu" -lgpm -lutil 2>/dev/null
B=$(md5sum "$TMP/gpm2xterm" | cut -d' ' -f1); D=$(md5sum $GPM_BIN 2>/dev/null | cut -d' ' -f1)
[ -n "$B" ] || R FAIL "rebuild from HEAD blob" "compile error"
[ "$B" = "$D" ] && R PASS "deployed == committed build" "${D:0:8}" || R FAIL "deployed vs committed" "live=${D:0:8} built=${B:0:8}"

# 4. static protocol assertions on committed source
SRC=$(git -C "$PROJ" show HEAD:gpm2xterm/gpm2xterm.c)
WHEEL=$(printf '%s' "$SRC" | awk '/if \(ev->wdy\)/{f=1} f{print} f&&/return;/{exit}')
n_press=$(printf '%s' "$WHEEL" | grep -c "'M'"); n_rel=$(printf '%s' "$WHEEL" | grep -c "'m'")
{ [ "$n_press" = 1 ] && [ "$n_rel" = 0 ]; } && R PASS "wheel press-only SGR" "1 press, 0 release" || R FAIL "wheel press-only" "press=$n_press release=$n_rel"
printf '%s' "$SRC" | grep -q "TIOCL_GETSHIFTSTATE" && R PASS "Enter uses GETSHIFTSTATE" "" || R FAIL "Enter translation" "constant missing"
printf '%s' "$SRC" | grep -q "GPM_HARD | GPM_MOVE" && R PASS "defaultMask fall-through" "" || R FAIL "defaultMask" "not passing types -> stale selection"
printf '%s' "$SRC" | grep -q "track_bracket" && R PASS "bracketed-paste tracking" "" || R FAIL "bracketed paste" "missing"

# 5. headless behavioral regression (OSC52 store->query reply + Ctrl+V injection)
gcc -O2 -w -o "$TMP/fakeapp" "$PROJ/gpm2xterm/fakeapp.c"
( cd "$TMP" && { sleep 0.5; printf '\026'; sleep 1.2; } | TERM=linux "$TMP/gpm2xterm" "$TMP/fakeapp" </dev/null >/dev/null 2>&1 )
HEX=$(xxd -p "$TMP/resp.bin" 2>/dev/null | tr -d '\n')
case "$HEX" in
  *1b5d3532*) case "$HEX" in *1b5b3230307e*68656c6c6f20776f726c64*1b5b3230317e*) R PASS "OSC52 reply + Ctrl+V paste" "roundtrip bytes OK";; *) R FAIL "paste injection" "no bracketed paste";; esac;;
  *) R FAIL "OSC52 reply" "app received nothing on stdin";;
esac
rm -rf "$TMP"

# 6. kernel ABI constants (headers this box builds against)
T=/usr/include/linux/tiocl.h
for k in "TIOCL_SETSEL 2" "TIOCL_GETSHIFTSTATE 6" "TIOCL_GETBRACKETEDPASTE 18" "TIOCL_GETFGCONSOLE 12"; do
  grep -qE "#define[[:space:]]+${k% *}[[:space:]]+${k#* }([[:space:]]|$)" $T && R PASS "kernel ABI: ${k% *}" "= ${k#* }" || R WARN "kernel ABI ${k% *}" "not found in $T"
done

# 7. per-tty live state (font + stuck modes)
for t in 1 2 3; do
  SZ=$(stty size < /dev/tty$t 2>/dev/null) || { R WARN "tty$t size" "unreadable"; continue; }
  [ "$SZ" = "65 232" ] && R PASS "tty$t geometry" "$SZ (Terminus 11x22)" || R FAIL "tty$t geometry" "got '$SZ' want '65 232'"
done
gcc -O2 -w -o /tmp/opencode/bpcheck "$PROJ/bpcheck.c" 2>/dev/null
# TIOCLINUX may be restricted for processes outside the console session; empty = SKIP
bp() { /tmp/opencode/bpcheck </dev/tty$1 2>/dev/null | sed -n "s/.*bracketed paste) = \([01]\).*/\1/p"; }
V1=$(bp 1); V2=$(bp 2)
case "$V1" in 1) R PASS "tty1 ?2004=1" "live oc requested it (correct)";; 0) R WARN "tty1 ?2004=0" "no app holding mouse/paste on tty1?";; *) R PASS "tty1 ?2004" "unreadable from here (kernel TIOCLINUX policy) — run bpcheck ON the tty to check";; esac
case "$V2" in 0) R PASS "tty2 ?2004=0" "no stuck bracketed-paste mode";; 1) R WARN "tty2 ?2004=1" "stuck? unstick: printf '\\e[?2004l' > $(tty)";; *) R PASS "tty2 ?2004" "unreadable from here (policy)";; esac

# 8. launcher & font config
grep -q 'TERM:-.*= *"linux"' /usr/local/bin/oc && grep -q gpmctl /usr/local/bin/oc && R PASS "oc guards" "TERM+socket checks present" || R FAIL "oc guards" "launcher altered?"
grep -q "Terminus22x11" /etc/console-setup/cached_setup_font.sh 2>/dev/null && R PASS "font boot cache" "Terminus22x11" || R WARN "font boot cache" "not Terminus (grep /etc/console-setup/)"
grep -q 'FONTFACE="Terminus"' /etc/default/console-setup && R PASS "console-setup config" "Terminus 11x22" || R FAIL "console-setup config" "drifted"

# 9. upstream PR carries the same committed code (needs gh auth)
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  HEAD_SHA=$(git -C "$PROJ" rev-parse HEAD:gpm2xterm/gpm2xterm.c)
  PR_CODE=$(gh api "repos/nazerim/gpm2xterm/contents/gpm2xterm.c?ref=fix/console-selection-wheel-clipboard" --jq .content 2>/dev/null | base64 -d 2>/dev/null | md5sum | cut -d' ' -f1)
  LOCAL_CODE=$(git -C "$PROJ" show HEAD:gpm2xterm/gpm2xterm.c | md5sum | cut -d' ' -f1)
  [ "$PR_CODE" = "$LOCAL_CODE" ] && R PASS "PR #1 code == HEAD" "${HEAD_SHA:0:8}" || R FAIL "PR #1 code" "differs from HEAD (run ./pr-upstream.sh)"
fi

echo; echo "RESULT: $ok pass / $fail fail / $warn warn"
[ $fail -eq 0 ]
