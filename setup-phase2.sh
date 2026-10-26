#!/usr/bin/env bash
# Phase 2: full mouse + OSC52 clipboard inside OpenCode on the Linux console.
# Switches the console mouse daemon consolation -> gpm (gpm2xterm is a libgpm
# client; only one pointer daemon should run) and installs the wrapper + `oc`.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with: sudo $0" >&2; exit 1; }
PROJ=/home/naz/Projects/opencode-console-mouse

apt-get install -y gpm

# /etc/gpm.conf is sourced by /usr/share/gpm/gpm-systemd-wrapper.sh
cat > /etc/gpm.conf <<'EOF'
device=/dev/input/mice
type=exps2
responsiveness=
repeat_type=none
sample_rate=
append=
EOF

# exactly one pointer daemon at a time
systemctl disable --now consolation
systemctl enable --now gpm

# build if artifact missing OR older than source (gitignored; build.sh needs no root)
BIN="$PROJ/gpm2xterm/gpm2xterm"; SRC="$PROJ/gpm2xterm/gpm2xterm.c"
{ [ -x "$BIN" ] && [ "$BIN" -nt "$SRC" ]; } || bash "$PROJ/gpm2xterm/build.sh"
[ -x "$BIN" ] || { echo "ERROR: build produced no $BIN" >&2; exit 1; }
chown "${SUDO_USER:-root}" "$BIN" 2>/dev/null || true

install -m 0755 "$BIN" /usr/local/bin/gpm2xterm

# guard: verify the deployed binary actually matches the repo's build
BUILT=$(md5sum "$BIN" | cut -d' ' -f1)
LIVE=$(md5sum /usr/local/bin/gpm2xterm | cut -d' ' -f1)
[ "$BUILT" = "$LIVE" ] || { echo "ERROR: deployed binary mismatch ($LIVE != $BUILT)" >&2; exit 1; }
echo "gpm2xterm installed: $LIVE"

cat > /usr/local/bin/oc <<'EOF'
#!/bin/sh
# OpenCode with full mouse + clipboard on the Linux console; plain opencode
# elsewhere (ssh sessions keep their terminal's native mouse handling).
if [ -S /dev/gpmctl ] && [ "${TERM:-}" = "linux" ]; then
    exec gpm2xterm opencode "$@"
fi
exec opencode "$@"
EOF
chmod 0755 /usr/local/bin/oc

systemctl --no-pager --full status gpm | head -8
echo
echo "Done. On the console (tty1/tty2): run  oc  instead of  opencode"
echo "Rollback: sudo $PROJ/rollback-phase2.sh"
