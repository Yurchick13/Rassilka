#!/usr/bin/env bash
set -euo pipefail

TARGET_USER="${TARGET_USER:-${SUDO_USER:-$USER}}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
INSTALL_DIR="${INSTALL_DIR:-${TARGET_HOME}/.local/opt/vacation-notifier}"

if [[ -z "$TARGET_HOME" ]]; then
  echo "Cannot determine home directory for user: $TARGET_USER"
  exit 1
fi

USER_UID="$(id -u "$TARGET_USER")"
HAD_LEGACY_CONFIG=0
if [[ -e "$TARGET_HOME/.config/systemd/user/default.target.wants/redos-notifier.service" \
      || -e "$TARGET_HOME/.config/systemd/user/redos-notifier.service" \
      || -e "$TARGET_HOME/.config/autostart/vacation-notifier.desktop" ]]; then
  HAD_LEGACY_CONFIG=1
fi

if [[ -d "/run/user/${USER_UID}" ]]; then
  if [[ "${EUID}" -eq 0 ]]; then
    sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/${USER_UID}" systemctl --user disable --now redos-notifier >/dev/null 2>&1 || true
  else
    systemctl --user disable --now redos-notifier >/dev/null 2>&1 || true
  fi
fi

rm -f \
  "$TARGET_HOME/.local/bin/vacation-notifier" \
  "$TARGET_HOME/.local/share/applications/vacation-notifier.desktop" \
  "$TARGET_HOME/.config/autostart/vacation-notifier.desktop" \
  "$TARGET_HOME/.config/systemd/user/redos-notifier.service"

if [[ "${EUID}" -eq 0 && "$HAD_LEGACY_CONFIG" == "1" && -e "/var/lib/systemd/linger/$TARGET_USER" ]] && command -v loginctl >/dev/null 2>&1; then
  loginctl disable-linger "$TARGET_USER" >/dev/null 2>&1 || true
fi

rm -rf "$INSTALL_DIR"

echo "Notifier uninstalled for user: ${TARGET_USER}"
