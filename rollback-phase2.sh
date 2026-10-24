#!/usr/bin/env bash
# Undo Phase 2: back to consolation (drag/copy/paste/scroll on the console,
# basic clicks in OpenCode). Removes the gpm daemon and the `oc`/gpm2xterm
# launcher. Safe to run even if Phase 2 was never applied.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with: sudo $0" >&2; exit 1; }

systemctl disable --now gpm 2>/dev/null || true
apt-get remove -y gpm 2>/dev/null || true
rm -f /etc/gpm.conf /usr/local/bin/gpm2xterm /usr/local/bin/oc

systemctl enable --now consolation
echo "Reverted to consolation. 'systemctl status consolation' to verify."
