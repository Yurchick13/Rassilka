#!/usr/bin/env bash
set -euo pipefail

AUTOSTART_NAME="vacation-notifier.desktop"
USER_SERVICE_NAME="redos-notifier.service"
POLKIT_RULE="/etc/polkit-1/rules.d/49-vacation-notifier-local-power.rules"
POLKIT_PKLA="/etc/polkit-1/localauthority/50-local.d/49-vacation-notifier-local-power.pkla"

# On RPM upgrade the old package postremove is called with argument 1.
# On DEB upgrade postrm may be called with "upgrade". Do not disable global
# services in those cases, otherwise the old package breaks the newly installed
# notifier. Full cleanup is needed only on real erase/remove/purge.
case "${1:-}" in
  1|upgrade|failed-upgrade|abort-upgrade|disappear)
    exit 0
    ;;
esac

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
  local uid home runtime had_legacy_config=0

  uid="$(id -u "$user" 2>/dev/null || true)"
  home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"

  [[ -n "$uid" ]] || return 0
  [[ -n "$home" && -d "$home" ]] || return 0

  if [[ -e "$home/.config/systemd/user/default.target.wants/$USER_SERVICE_NAME" \
        || -e "$home/.config/systemd/user/$USER_SERVICE_NAME" \
        || -e "$home/.config/autostart/$AUTOSTART_NAME" ]]; then
    had_legacy_config=1
  fi

  runtime="/run/user/$uid"
  if [[ -d "$runtime" ]]; then
    run_as_user "$user" env XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" systemctl --user disable --now "$USER_SERVICE_NAME" >/dev/null 2>&1 || true
  fi

  rm -f "$home/.config/autostart/$AUTOSTART_NAME" \
        "$home/.config/systemd/user/$USER_SERVICE_NAME" \
        "$home/.config/systemd/user/default.target.wants/$USER_SERVICE_NAME"

  if [[ "$had_legacy_config" == "1" && -e "/var/lib/systemd/linger/$user" ]] && command -v loginctl >/dev/null 2>&1; then
    loginctl disable-linger "$user" >/dev/null 2>&1 || true
  fi
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
rm -f "$POLKIT_RULE" "$POLKIT_PKLA" >/dev/null 2>&1 || true
systemctl try-reload-or-restart polkit.service >/dev/null 2>&1 || systemctl try-reload-or-restart polkit >/dev/null 2>&1 || true
update-desktop-database >/dev/null 2>&1 || true
