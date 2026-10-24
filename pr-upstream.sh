#!/usr/bin/env bash
# Open (or update) the upstream PR to RaphaelGF11/gpm2xterm with our fixed
# gpm2xterm.c. Safe to re-run: pushes update the existing branch/PR.
set -euo pipefail
PROJ=$(cd "$(dirname "$0")" && pwd -P)
GH="${GH:-$HOME/.local/bin/gh}"; command -v "$GH" >/dev/null || GH=gh
"$GH" auth status >/dev/null 2>&1 || { echo "Not authenticated. Run:  $GH auth login" >&2; exit 1; }
LOGIN=$("$GH" api user --jq .login)
UPSTREAM="RaphaelGF11/gpm2xterm"
BRANCH="fix/console-selection-wheel-clipboard"
BASE=$("$GH" repo view "$UPSTREAM" --json defaultBranchRef --jq .defaultBranchRef.name)

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
cd "$WORK"   # NOT inside $PROJ: gh creates ./gpm2xterm which would collide
if "$GH" repo view "$LOGIN/gpm2xterm" >/dev/null 2>&1; then
  git clone -q "https://github.com/$LOGIN/gpm2xterm.git" "$WORK/gpm2xterm"
else
  "$GH" repo fork "$UPSTREAM" --clone=true >/dev/null
fi
cd "$WORK/gpm2xterm"
git config user.name "$("$GH" api user --jq '(.name // .login)')"
git config user.email "$("$GH" api user --jq '"\(.id)+\(.login)@users.noreply.github.com"')"
git checkout -q "origin/$BASE" 2>/dev/null || git checkout -q "remotes/origin/$BASE"
git checkout -q -B "$BRANCH"
cp -f "$PROJ/gpm2xterm/gpm2xterm.c" gpm2xterm.c
cp -f "$PROJ/gpm2xterm/fakeapp.c"   fakeapp.c
git add -A
git commit -q -F - <<'MSG'
Fix console selection/paste + wheel mapping; add OSC52 clipboard, Enter translation

- defaultMask: fall through to gpm's root selection handler (kernel now
  requires CAP_SYS_ADMIN for TIOCL_SETSEL; GPM_HARD alone consumed events,
  killing middle-click paste and freezing the selection buffer)
- wheel: map gpm wdy events to SGR 64/65 (xterm scroll-bit convention;
  4/5 decodes as button clicks in SGR)
- DECSET/OSC/DCS: robust state machine (multi-param sets, split reads,
  bare-ESC termination)
- stdin EOF vs raw-tty no-data; remove blocking event-drain hang
- OSC52 clipboard emulation + XTGETTCAP Ms reply (capability-gated apps)
- Ctrl+V served wrapper-side as bracketed paste
- Enter+shift-state -> ctrl+j (console sends identical 0x0D for all Enters)
- clear stuck DECSET modes at startup/exit (?2004 poisons console pastes)
- GPM2XTERM_DEBUG=1 full trace
MSG
git push -q -f -u origin "$BRANCH"

if "$GH" pr list --repo "$UPSTREAM" --head "$LOGIN:$BRANCH" --state open --json number --jq '.[0].number' | grep -qE '^[0-9]+$'; then
  echo "PR updated (already open):"
  "$GH" pr list --repo "$UPSTREAM" --head "$LOGIN:$BRANCH" --state open
else
  "$GH" pr create --repo "$UPSTREAM" --base "$BASE" --head "$LOGIN:$BRANCH" \
    --title "Fix console selection/paste + wheel mapping; add OSC52 clipboard & Enter translation" \
    --body-file "$PROJ/PR_BODY.md"
fi
