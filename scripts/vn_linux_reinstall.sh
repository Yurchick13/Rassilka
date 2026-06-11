#!/usr/bin/env bash
set -euo pipefail

SERVER_HTTP_URL="${SERVER_HTTP_URL:-http://192.168.76.95:8000}"
STATUS_FILE="${STATUS_FILE:-/tmp/vn_reinstall.status}"
LOG_FILE="${LOG_FILE:-/var/log/vn_reinstall.log}"
USER_SERVICE_NAME="redos-notifier.service"
AUTOSTART_NAME="vacation-notifier.desktop"
LAUNCHER="/usr/bin/vacation-notifier"

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

write_status() {
  local status="$1"
  local message="${2:-}"
  printf '%s|%s|%s\n' "$(date -Is)" "$status" "$message" > "$STATUS_FILE"
}

fail() {
  write_status "failed" "$*"
  echo "ERROR: $*" >&2
  exit 1
}

download_file() {
  local url="$1"
  local out_file="$2"

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$url" "$out_file" <<'PY'
import sys
from urllib.request import Request, urlopen

url = sys.argv[1]
out_file = sys.argv[2]
req = Request(url, headers={"User-Agent": "vn-linux-reinstall"})
with urlopen(req, timeout=180) as response:
    data = response.read()
with open(out_file, "wb") as fh:
    fh.write(data)
PY
    return
  fi

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out_file"
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -qO "$out_file" "$url"
    return
  fi

  fail "No downloader found: python3, curl or wget is required."
}

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

cleanup_legacy_user_state() {
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
    run_as_user "$user" env XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" systemctl --user stop "$USER_SERVICE_NAME" >/dev/null 2>&1 || true
  fi

  rm -f "$home/.config/systemd/user/default.target.wants/$USER_SERVICE_NAME" \
        "$home/.config/systemd/user/$USER_SERVICE_NAME" \
        "$home/.config/autostart/$AUTOSTART_NAME"

  if [[ "$had_legacy_config" == "1" && -e "/var/lib/systemd/linger/$user" ]] && command -v loginctl >/dev/null 2>&1; then
    loginctl disable-linger "$user" >/dev/null 2>&1 || true
  fi
}

restart_active_user_service() {
  local user="$1"
  local uid runtime

  uid="$(id -u "$user" 2>/dev/null || true)"
  [[ -n "$uid" ]] || return 0
  runtime="/run/user/$uid"
  [[ -d "$runtime" ]] || return 0

  run_as_user "$user" env XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" systemctl --user daemon-reload >/dev/null 2>&1 || true
  if run_as_user "$user" env XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" systemctl --user restart "$USER_SERVICE_NAME" >/dev/null 2>&1; then
    return 0
  fi

  run_as_user "$user" pkill -f '/opt/vacation-notifier/redos_notifier/notifier.py' >/dev/null 2>&1 || true
  run_as_user "$user" bash -lc "nohup $LAUNCHER >/dev/null 2>&1 &" >/dev/null 2>&1 || true
}

if [[ "${EUID}" -ne 0 ]]; then
  fail "Run this script as root or through sudo."
fi

write_status "running" "started"
echo "=== vn reinstall started: $(date -Is) ==="

mapfile -t all_users < <(getent passwd | awk -F: '$3>=1000 && $7 !~ /(false|nologin)$/ {print $1}' | sort -u || true)
for user in "${all_users[@]}"; do
  [[ -n "${user:-}" && "$user" != "root" ]] || continue
  cleanup_legacy_user_state "$user"
done

systemctl stop vacation-notifier-updater.timer vacation-notifier-updater.service >/dev/null 2>&1 || true
systemctl daemon-reload >/dev/null 2>&1 || true

tmp_pkg="$(mktemp /tmp/vn_pkg.XXXXXX)"
cleanup_tmp() {
  rm -f "$tmp_pkg" >/dev/null 2>&1 || true
}
trap cleanup_tmp EXIT

if command -v rpm >/dev/null 2>&1; then
  pkg_url="${SERVER_HTTP_URL%/}/static/updates/vacation-registry-notifier-latest.x86_64.rpm"
  download_file "$pkg_url" "$tmp_pkg"
  target_version="$(rpm -qp --qf '%{VERSION}' "$tmp_pkg" 2>/dev/null || true)"
  rpm -Uvh --replacepkgs --replacefiles "$tmp_pkg"

  if [[ -n "$target_version" ]]; then
    while IFS= read -r installed_pkg; do
      [[ -n "$installed_pkg" ]] || continue
      if [[ "$installed_pkg" != "vacation-registry-notifier-${target_version}-"* ]]; then
        rpm -e --noscripts --nodeps "$installed_pkg" >/dev/null 2>&1 || true
      fi
    done < <(rpm -qa | grep '^vacation-registry-notifier-' | sort || true)
  fi
elif command -v dpkg >/dev/null 2>&1; then
  pkg_url="${SERVER_HTTP_URL%/}/static/updates/vacation-registry-notifier_latest_amd64.deb"
  download_file "$pkg_url" "$tmp_pkg"
  dpkg -i "$tmp_pkg" || apt-get -f install -y
else
  fail "No supported package manager found: rpm or dpkg is required."
fi

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl try-reload-or-restart polkit.service >/dev/null 2>&1 || systemctl try-reload-or-restart polkit >/dev/null 2>&1 || true
systemctl --global enable "$USER_SERVICE_NAME" >/dev/null 2>&1 || true
systemctl enable --now vacation-notifier-updater.timer >/dev/null 2>&1 || true

for user in "${all_users[@]}"; do
  [[ -n "${user:-}" && "$user" != "root" ]] || continue
  cleanup_legacy_user_state "$user"
  restart_active_user_service "$user"
done

installed_version=""
if [[ -f /opt/vacation-notifier/redos_notifier/VERSION ]]; then
  installed_version="$(tr -d '\r\n' < /opt/vacation-notifier/redos_notifier/VERSION || true)"
fi

write_status "ok" "version=${installed_version:-unknown}"
echo "=== vn reinstall completed: version=${installed_version:-unknown} ==="
