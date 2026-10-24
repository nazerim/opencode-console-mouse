#!/usr/bin/env bash
# One-shot publish:
#   1) push this project to <you>/opencode-console-mouse
#   2) fork RaphaelGF11/gpm2xterm, apply our fixed gpm2xterm.c, open a PR
# Requires: gh authenticated (run: gh auth login)
set -euo pipefail
PROJ=$(cd "$(dirname "$0")" && pwd -P)
cd "$PROJ"
GH="${GH:-$HOME/.local/bin/gh}"; command -v "$GH" >/dev/null || GH=gh
"$GH" auth status >/dev/null 2>&1 || { echo "Not authenticated. Run:  $GH auth login" >&2; exit 1; }

LOGIN=$("$GH" api user --jq .login)
NAME=$("$GH" api user --jq '(.name // .login)')
EMAIL=$("$GH" api user --jq '"\(.id)+\(.login)@users.noreply.github.com"')
git config user.name "$NAME"; git config user.email "$EMAIL"

# fix authorship of the pre-auth placeholder commit (unpushed)
if git log --format='%ae' | grep -q "placeholder@local"; then
  git commit --amend --reset-author --no-edit -q
fi

# ---- 1) own repo ----
if ! git remote get-url origin >/dev/null 2>&1; then
  "$GH" repo create "$LOGIN/opencode-console-mouse" --public --source=. --remote=origin >/dev/null
fi
git push -u origin "$(git branch --show-current)"
echo "pushed: https://github.com/$LOGIN/opencode-console-mouse"

# ---- 2) upstream PR ----
UPSTREAM="RaphaelGF11/gpm2xterm"
BRANCH="fix/console-selection-wheel-clipboard"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
"$GH" repo fork "$UPSTREAM" --clone=true >/dev/null
cd "$WORK/gpm2xterm"
BASE=$("$GH" repo view "$UPSTREAM" --json defaultBranch --jq .defaultBranch)
git checkout -q -b "$BRANCH"
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
git push -q -u origin "$BRANCH"
"$GH" pr create --repo "$UPSTREAM" --base "$BASE" \
  --head "$LOGIN:$BRANCH" \
  --title "Fix console selection/paste + wheel mapping; add OSC52 clipboard & Enter translation" \
  --body-file "$PROJ/PR_BODY.md"
