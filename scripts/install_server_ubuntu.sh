#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="vacation-registry"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_SRC="$(cd "$SCRIPT_DIR/.." && pwd)"

INSTALL_DIR="${INSTALL_DIR:-/opt/vacation-registry}"
APP_USER="${APP_USER:-vacation-registry}"
APP_GROUP="${APP_GROUP:-$APP_USER}"
BACKUP_BASE_DIR="${BACKUP_BASE_DIR:-/var/backups/vacation-registry}"
BACKUP_TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_BASE_DIR}/${BACKUP_TIMESTAMP}"
APP_TIMEZONE="${APP_TIMEZONE:-Europe/Moscow}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8000}"
DATABASE_URL="${DATABASE_URL:-sqlite:///${INSTALL_DIR}/vacations.db}"
SESSION_SECRET_KEY="${SESSION_SECRET_KEY:-}"
DEFAULT_ADMIN_LOGIN="${DEFAULT_ADMIN_LOGIN:-admin}"
DEFAULT_ADMIN_PASSWORD="${DEFAULT_ADMIN_PASSWORD:-admin12345}"
REWRITE_ENV="${REWRITE_ENV:-0}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/install_server_ubuntu.sh"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y python3 python3-venv python3-pip rsync

if ! getent group "$APP_GROUP" >/dev/null; then
  groupadd --system "$APP_GROUP"
fi

if ! id -u "$APP_USER" >/dev/null 2>&1; then
  useradd --system --gid "$APP_GROUP" --create-home --home-dir "/home/$APP_USER" --shell /usr/sbin/nologin "$APP_USER"
fi

mkdir -p "$INSTALL_DIR"
mkdir -p "$BACKUP_DIR"

if systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
  systemctl stop "${SERVICE_NAME}.service" || true
fi

if [[ -f "$INSTALL_DIR/vacations.db" ]]; then
  cp -a "$INSTALL_DIR/vacations.db" "$BACKUP_DIR/vacations.db"
fi

if [[ -f "$INSTALL_DIR/.env" ]]; then
  cp -a "$INSTALL_DIR/.env" "$BACKUP_DIR/.env"
fi

rsync -a --delete \
  --exclude ".git" \
  --exclude ".venv" \
  --exclude "__pycache__" \
  --exclude "dist" \
  --exclude "build" \
  --exclude ".env" \
  --exclude "app/static/updates" \
  --exclude "vacations.db" \
  "$PROJECT_SRC/" "$INSTALL_DIR/"

mkdir -p "$INSTALL_DIR/app/static/updates"
chown -R "$APP_USER:$APP_GROUP" "$INSTALL_DIR"

if [[ -d "$INSTALL_DIR/.venv" ]]; then
  rm -rf "$INSTALL_DIR/.venv"
fi

sudo -u "$APP_USER" python3 -m venv "$INSTALL_DIR/.venv"
sudo -u "$APP_USER" "$INSTALL_DIR/.venv/bin/pip" install --upgrade pip
sudo -u "$APP_USER" "$INSTALL_DIR/.venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt"

if [[ -z "$SESSION_SECRET_KEY" ]]; then
  SESSION_SECRET_KEY="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(48))
PY
)"
fi

if [[ "$REWRITE_ENV" == "1" || ! -f "$INSTALL_DIR/.env" ]]; then
cat > "$INSTALL_DIR/.env" <<EOF
APP_TIMEZONE=${APP_TIMEZONE}
DATABASE_URL=${DATABASE_URL}
SESSION_SECRET_KEY=${SESSION_SECRET_KEY}
SESSION_COOKIE_NAME=vacation_session
SESSION_HTTPS_ONLY=0
DEFAULT_ADMIN_LOGIN=${DEFAULT_ADMIN_LOGIN}
DEFAULT_ADMIN_PASSWORD=${DEFAULT_ADMIN_PASSWORD}
EOF
fi

chown "$APP_USER:$APP_GROUP" "$INSTALL_DIR/.env"
chmod 640 "$INSTALL_DIR/.env"

cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Vacation Registry API
After=network.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
ExecStart=${INSTALL_DIR}/.venv/bin/uvicorn app.main:app --host ${HOST} --port ${PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}.service"

cat <<EOF

Installed successfully.
Service: ${SERVICE_NAME}
Backup dir: ${BACKUP_DIR}
Check status: sudo systemctl status ${SERVICE_NAME}
Open app: http://<SERVER_IP>:${PORT}/
EOF
