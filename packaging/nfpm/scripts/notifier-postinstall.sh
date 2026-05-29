#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/vacation-notifier"
LAUNCHER="/usr/bin/vacation-notifier"
AUTOSTART_NAME="vacation-notifier.desktop"
SYSTEMD_USER_DIR="/usr/lib/systemd/user"
USER_SERVICE_NAME="redos-notifier.service"

python3 -m venv "$APP_DIR/.venv"
"$APP_DIR/.venv/bin/pip" install --upgrade pip
"$APP_DIR/.venv/bin/pip" install -r "$APP_DIR/requirements.txt"

if [[ ! -f /etc/vacation-notifier.env ]]; then
  cp /etc/vacation-notifier.env.example /etc/vacation-notifier.env
fi

chmod 644 /etc/vacation-notifier.env /etc/vacation-notifier.env.example || true
chmod 755 /usr/libexec/vacation-notifier-updater || true
update-desktop-database >/dev/null 2>&1 || true

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl --global enable "$USER_SERVICE_NAME" >/dev/null 2>&1 || true
systemctl enable --now vacation-notifier-updater.timer >/dev/null 2>&1 || true
systemctl start vacation-notifier-updater.service >/dev/null 2>&1 || true

run_as_user() {
  local user="$1"
  shift
  if command -v runuser >/dev/null 2>&1; then
    runuser -u "$user" -- "$@"
  else
    sudo -u "$user" "$@"
  fi
}

configure_user_session() {
  local user="$1"
  local uid home runtime

  uid="$(id -u "$user" 2>/dev/null || true)"
  home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"

  [[ -n "$uid" ]] || return 0
  [[ -n "$home" && -d "$home" ]] || return 0

  mkdir -p "$home/.config" "$home/.local" "$home/.config/autostart" "$home/.config/systemd/user/default.target.wants"
  chown -R "$user:$user" "$home/.config" "$home/.local" || true

  cat > "$home/.config/autostart/$AUTOSTART_NAME" <<EOF
[Desktop Entry]
Name=Vacation Notifier
Comment=Vacation registry notifications client
Exec=$LAUNCHER
Terminal=false
Type=Application
X-GNOME-Autostart-enabled=true
EOF

  ln -sfn "$SYSTEMD_USER_DIR/$USER_SERVICE_NAME" "$home/.config/systemd/user/default.target.wants/$USER_SERVICE_NAME"

  chown "$user:$user" "$home/.config/autostart/$AUTOSTART_NAME" || true
  chown -h "$user:$user" "$home/.config/systemd/user/default.target.wants/$USER_SERVICE_NAME" || true

  if command -v loginctl >/dev/null 2>&1; then
    loginctl enable-linger "$user" >/dev/null 2>&1 || true
  fi

  runtime="/run/user/$uid"
  if [[ -d "$runtime" ]]; then
    run_as_user "$user" env XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" systemctl --user daemon-reload || true
    run_as_user "$user" env XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" systemctl --user enable --now "$USER_SERVICE_NAME" || true
    run_as_user "$user" bash -lc "pgrep -f '/opt/vacation-notifier/redos_notifier/notifier.py' >/dev/null || nohup $LAUNCHER >/dev/null 2>&1 &" || true
  fi
}

mapfile -t _active_users < <(getent passwd | awk -F: '$3>=1000 && $7 !~ /(false|nologin)$/ {print $1}' | sort -u || true)

for _user in "${_active_users[@]}"; do
  [[ -n "${_user:-}" ]] || continue
  [[ "$_user" == "root" ]] && continue
  configure_user_session "$_user"
done
