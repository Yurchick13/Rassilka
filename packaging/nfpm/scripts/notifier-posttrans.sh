#!/usr/bin/env bash
set -euo pipefail

LAUNCHER="/usr/bin/vacation-notifier"
AUTOSTART_NAME="vacation-notifier.desktop"
USER_SERVICE_NAME="redos-notifier.service"

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

  rm -f "$home/.config/systemd/user/default.target.wants/$USER_SERVICE_NAME" \
        "$home/.config/systemd/user/$USER_SERVICE_NAME" \
        "$home/.config/autostart/$AUTOSTART_NAME"

  if [[ "$had_legacy_config" == "1" && -e "/var/lib/systemd/linger/$user" ]] && command -v loginctl >/dev/null 2>&1; then
    loginctl disable-linger "$user" >/dev/null 2>&1 || true
    if ! user_has_session "$user"; then
      loginctl terminate-user "$user" >/dev/null 2>&1 || true
    fi
  fi
}

restart_user_session() {
  local user="$1"
  local uid runtime

  uid="$(id -u "$user" 2>/dev/null || true)"
  [[ -n "$uid" ]] || return 0

  runtime="/run/user/$uid"
  [[ -d "$runtime" ]] || return 0

  run_as_user "$user" env XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" systemctl --user daemon-reload || true
  if run_as_user "$user" env XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" systemctl --user restart "$USER_SERVICE_NAME"; then
    return 0
  fi

  run_as_user "$user" pkill -f '/opt/vacation-notifier/redos_notifier/notifier.py' >/dev/null 2>&1 || true
  run_as_user "$user" bash -lc "nohup $LAUNCHER >/dev/null 2>&1 &" || true
}

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl --global enable "$USER_SERVICE_NAME" >/dev/null 2>&1 || true
systemctl enable --now vacation-notifier-updater.timer >/dev/null 2>&1 || true

mapfile -t _users < <(getent passwd | awk -F: '$3>=1000 && $7 !~ /(false|nologin)$/ {print $1}' | sort -u || true)
for _user in "${_users[@]}"; do
  [[ -n "${_user:-}" ]] || continue
  [[ "$_user" == "root" ]] && continue
  cleanup_legacy_user_session "$_user"
  restart_user_session "$_user"
done
