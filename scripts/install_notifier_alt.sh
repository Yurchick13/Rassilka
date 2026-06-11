#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_SRC="$(cd "$SCRIPT_DIR/.." && pwd)"

TARGET_USER="${TARGET_USER:-${SUDO_USER:-$USER}}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
INSTALL_DIR="${INSTALL_DIR:-${TARGET_HOME}/.local/opt/vacation-notifier}"
SERVER_HTTP_URL="${SERVER_HTTP_URL:-http://192.168.76.95:8000}"
SERVER_WS_URL="${SERVER_WS_URL:-ws://192.168.76.95:8000/ws/registry}"
CLIENT_HEARTBEAT_TOKEN="${CLIENT_HEARTBEAT_TOKEN:-}"

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y python3 python3-pip python3-tk rsync
    apt-get install -y python3-venv || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y python3 python3-pip python3-tkinter rsync
  elif command -v yum >/dev/null 2>&1; then
    yum install -y python3 python3-pip tkinter rsync
  else
    echo "No supported package manager found (apt-get/dnf/yum)."
    exit 1
  fi
}

if [[ -z "$TARGET_HOME" ]]; then
  echo "Cannot determine home directory for user: $TARGET_USER"
  exit 1
fi

if [[ "${EUID}" -eq 0 ]]; then
  install_packages
fi

mkdir -p "$INSTALL_DIR"
rsync -a --delete "$PROJECT_SRC/redos_notifier/" "$INSTALL_DIR/redos_notifier/"

python3 -m venv "$INSTALL_DIR/.venv"
"$INSTALL_DIR/.venv/bin/pip" install --upgrade pip
"$INSTALL_DIR/.venv/bin/pip" install -r "$INSTALL_DIR/redos_notifier/requirements.txt"

cat > "$INSTALL_DIR/.env" <<EOF
SERVER_HTTP_URL=${SERVER_HTTP_URL}
SERVER_WS_URL=${SERVER_WS_URL}
NOTIFIER_AUTO_UPDATE_ENABLED=1
HEARTBEAT_INTERVAL_SECONDS=60
CLIENT_HEARTBEAT_TOKEN=${CLIENT_HEARTBEAT_TOKEN}
EOF

mkdir -p "$TARGET_HOME/.local/bin" "$TARGET_HOME/.local/share/applications" "$TARGET_HOME/.config/systemd/user" "$TARGET_HOME/.config/autostart"

cat > "$TARGET_HOME/.local/bin/vacation-notifier" <<EOF
#!/usr/bin/env bash
set -euo pipefail
set -a
source "${INSTALL_DIR}/.env"
set +a
exec "${INSTALL_DIR}/.venv/bin/python" "${INSTALL_DIR}/redos_notifier/notifier.py"
EOF

chmod +x "$TARGET_HOME/.local/bin/vacation-notifier"

cat > "$TARGET_HOME/.local/share/applications/vacation-notifier.desktop" <<EOF
[Desktop Entry]
Name=Vacation Notifier
Comment=Vacation registry notifications client
Exec=${TARGET_HOME}/.local/bin/vacation-notifier
Terminal=false
Type=Application
Categories=Office;
EOF

cat > "$TARGET_HOME/.config/autostart/vacation-notifier.desktop" <<EOF
[Desktop Entry]
Name=Vacation Notifier
Comment=Vacation registry notifications client
Exec=${TARGET_HOME}/.local/bin/vacation-notifier
Terminal=false
Type=Application
X-GNOME-Autostart-enabled=true
EOF

cat > "$TARGET_HOME/.config/systemd/user/redos-notifier.service" <<EOF
[Unit]
Description=Vacation Registry Notifier
After=network-online.target

[Service]
Type=simple
ExecStart=${TARGET_HOME}/.local/bin/vacation-notifier
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

if [[ "${EUID}" -eq 0 ]]; then
  chown -R "$TARGET_USER:$TARGET_USER" "$INSTALL_DIR" "$TARGET_HOME/.local/bin/vacation-notifier" "$TARGET_HOME/.local/share/applications/vacation-notifier.desktop" "$TARGET_HOME/.config/autostart/vacation-notifier.desktop" "$TARGET_HOME/.config/systemd/user/redos-notifier.service"
  if command -v loginctl >/dev/null 2>&1 && [[ -e "/var/lib/systemd/linger/$TARGET_USER" ]]; then
    loginctl disable-linger "$TARGET_USER" >/dev/null 2>&1 || true
  fi
fi

USER_UID="$(id -u "$TARGET_USER")"
if [[ -d "/run/user/${USER_UID}" ]]; then
  if [[ "${EUID}" -eq 0 ]]; then
    sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/${USER_UID}" systemctl --user daemon-reload || true
    sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/${USER_UID}" systemctl --user enable --now redos-notifier || true
  else
    systemctl --user daemon-reload || true
    systemctl --user enable --now redos-notifier || true
  fi
fi

cat <<EOF

Notifier installed for ALT Linux user: ${TARGET_USER}
Launcher: ${TARGET_HOME}/.local/bin/vacation-notifier
Autostart entry: ${TARGET_HOME}/.config/autostart/vacation-notifier.desktop

Autostart is configured automatically.
If systemd user service is not active yet, it will start on next login.
EOF
