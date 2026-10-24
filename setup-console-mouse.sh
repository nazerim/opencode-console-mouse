#!/usr/bin/env bash
# Console mouse setup: consolation (libinput-based gpm alternative)
# - drag = select, middle-click = paste, wheel = scroll
# - side buttons: back = extend selection, forward = paste
# - selection buffer is shared across all VTs (tty1..tty6)
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with: sudo $0" >&2; exit 1; }

apt-get install -y consolation

# DAEMON_OPTS is read by /usr/lib/systemd/system/consolation.service
# No spaces in values -> no quoting needed for systemd EnvironmentFile.
cat > /etc/default/consolation <<'EOF'
DAEMON_OPTS=--map BTN_SIDE=endselect --map BTN_EXTRA=paste
EOF

systemctl daemon-reload
systemctl enable --now consolation
systemctl --no-pager status consolation
