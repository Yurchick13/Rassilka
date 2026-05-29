#!/usr/bin/env bash
set -euo pipefail

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

cleanup_user_session() {
  local user="$1"
  local uid home runtime

  uid="$(id -u "$user" 2>/dev/null || true)"
  home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"

  [[ -n "$uid" ]] || return 0
  [[ -n "$home" && -d "$home" ]] || return 0

  runtime="/run/user/$uid"
  if [[ -d "$runtime" ]]; then
    run_as_user "$user" env XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" systemctl --user disable --now "$USER_SERVICE_NAME" >/dev/null 2>&1 || true
  fi

  rm -f "$home/.config/autostart/$AUTOSTART_NAME" \
        "$home/.config/systemd/user/$USER_SERVICE_NAME" \
        "$home/.config/systemd/user/default.target.wants/$USER_SERVICE_NAME"
}

mapfile -t _users < <(getent passwd | awk -F: '$3>=1000 && $7 !~ /(false|nologin)$/ {print $1}' | sort -u || true)
for _user in "${_users[@]}"; do
  [[ -n "${_user:-}" ]] || continue
  [[ "$_user" == "root" ]] && continue
  cleanup_user_session "$_user"
done

pkill -f "vacation-notifier|redos_notifier/notifier.py" >/dev/null 2>&1 || true
systemctl --global disable "$USER_SERVICE_NAME" >/dev/null 2>&1 || true
systemctl disable --now vacation-notifier-updater.timer >/dev/null 2>&1 || true
systemctl stop vacation-notifier-updater.service >/dev/null 2>&1 || true
systemctl daemon-reload >/dev/null 2>&1 || true
rm -f /etc/xdg/autostart/vacation-notifier.desktop >/dev/null 2>&1 || true
rm -f /usr/share/applications/vacation-notifier.desktop >/dev/null 2>&1 || true
update-desktop-database >/dev/null 2>&1 || true
