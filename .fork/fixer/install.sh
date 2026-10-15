#!/usr/bin/env bash
# Install (or update) the local upstream-sync fixer as a systemd user timer.
#   .fork/fixer/install.sh            install/update and start
#   .fork/fixer/install.sh --remove   stop and remove
set -euo pipefail

NAME=lc-fork-fixer
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="${XDG_DATA_HOME:-$HOME/.local/share}/$NAME"
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

if [ "${1:-}" = "--remove" ]; then
  systemctl --user disable --now "$NAME.timer" 2>/dev/null || true
  rm -f "$UNITS/$NAME.service" "$UNITS/$NAME.timer"
  systemctl --user daemon-reload
  echo "Removed $NAME (kept $DEST and its logs)."
  exit 0
fi

mkdir -p "$DEST" "$UNITS"
install -m 755 "$SRC/fork-fixer.py" "$DEST/fork-fixer.py"
install -m 644 "$SRC/prompt.md" "$DEST/prompt.md"

cat > "$UNITS/$NAME.service" <<EOF
[Unit]
Description=Fix failed LiveContainer fork upstream syncs with Claude Code
After=network-online.target

[Service]
Type=oneshot
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/bin/python3 -I $DEST/fork-fixer.py
Nice=10
EOF

cat > "$UNITS/$NAME.timer" <<EOF
[Unit]
Description=Check for failed LiveContainer fork upstream syncs

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now "$NAME.timer"
echo "Installed $NAME. Status: systemctl --user list-timers $NAME.timer"
echo "Logs: journalctl --user -u $NAME.service  and  ${XDG_STATE_HOME:-$HOME/.local/state}/$NAME/logs/"
