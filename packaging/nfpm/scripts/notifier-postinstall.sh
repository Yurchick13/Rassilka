#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/vacation-notifier"
LAUNCHER="/usr/bin/vacation-notifier"
AUTOSTART_NAME="vacation-notifier.desktop"
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
systemctl try-reload-or-restart polkit.service >/dev/null 2>&1 || systemctl try-reload-or-restart polkit >/dev/null 2>&1 || true
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

user_has_session() {
  local user="$1"
  command -v loginctl >/dev/null 2>&1 || return 1
  loginctl list-sessions --no-legend 2>/dev/null | awk -v user="$user" '$3 == user { found = 1 } END { exit(found ? 0 : 1) }'
}

cleanup_legacy_user_session() {
  local user="$1"
  local uid home had_legacy_config=0

  uid="$(id -u "$user" 2>/dev/null || true)"
  home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"

  [[ -n "$uid" ]] || return 0
  [[ -n "$home" && -d "$home" ]] || return 0

  if [[ -e "$home/.config/systemd/user/default.target.wants/$USER_SERVICE_NAME" \
        || -e "$home/.config/systemd/user/$USER_SERVICE_NAME" \
        || -e "$home/.config/autostart/$AUTOSTART_NAME" ]]; then
    had_legacy_config=1
  fi

  # Older packages created per-user units/autostart files and enabled linger.
  # That kept another user's user@UID.service alive and made RED OS ask for
  # that user's password on shutdown. The package now uses only global user
  # service activation for real login sessions, plus /etc/xdg/autostart.
  rm -f "$home/.config/systemd/user/default.target.wants/$USER_SERVICE_NAME" \
        "$home/.config/systemd/user/$USER_SERVICE_NAME" \
        "$home/.config/autostart/$AUTOSTART_NAME"

  if [[ "$had_legacy_config" == "1" && -e "/var/lib/systemd/linger/$user" ]] && command -v loginctl >/dev/null 2>&1; then
    loginctl disable-linger "$user" >/dev/null 2>&1 || true
  fi
}

configure_user_session() {
  local user="$1"
  local uid home runtime

  uid="$(id -u "$user" 2>/dev/null || true)"
  home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"

  [[ -n "$uid" ]] || return 0
  [[ -n "$home" && -d "$home" ]] || return 0

  cleanup_legacy_user_session "$user"

  mkdir -p "$home/.config" "$home/.local"
  chown -R "$user:$user" "$home/.config" "$home/.local" || true

  runtime="/run/user/$uid"
  if [[ -d "$runtime" ]]; then
    run_as_user "$user" env XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" systemctl --user daemon-reload || true
    if run_as_user "$user" env XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" systemctl --user restart "$USER_SERVICE_NAME"; then
      return 0
    fi

    run_as_user "$user" pkill -f '/opt/vacation-notifier/redos_notifier/notifier.py' >/dev/null 2>&1 || true
    run_as_user "$user" bash -lc "nohup $LAUNCHER >/dev/null 2>&1 &" || true
  fi
}

mapfile -t _active_users < <(getent passwd | awk -F: '$3>=1000 && $7 !~ /(false|nologin)$/ {print $1}' | sort -u || true)

for _user in "${_active_users[@]}"; do
  [[ -n "${_user:-}" ]] || continue
  [[ "$_user" == "root" ]] && continue
  configure_user_session "$_user"
done
