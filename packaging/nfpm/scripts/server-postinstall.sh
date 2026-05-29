#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/vacation-registry"
APP_USER="vacation-registry"
APP_GROUP="vacation-registry"
SERVICE_NAME="vacation-registry"

if ! getent group "$APP_GROUP" >/dev/null; then
  groupadd --system "$APP_GROUP"
fi

if ! id -u "$APP_USER" >/dev/null 2>&1; then
  useradd --system --gid "$APP_GROUP" --create-home --home-dir "/home/$APP_USER" --shell /usr/sbin/nologin "$APP_USER" || \
  useradd --system --gid "$APP_GROUP" --create-home --home-dir "/home/$APP_USER" --shell /sbin/nologin "$APP_USER"
fi

python3 -m venv "$APP_DIR/.venv"
"$APP_DIR/.venv/bin/pip" install --upgrade pip
"$APP_DIR/.venv/bin/pip" install -r "$APP_DIR/requirements.txt"

if [[ ! -f "$APP_DIR/.env" ]]; then
  cp "$APP_DIR/.env.example" "$APP_DIR/.env"
  sed -i "s|^DATABASE_URL=.*|DATABASE_URL=sqlite:///$APP_DIR/vacations.db|" "$APP_DIR/.env" || true
  if grep -q "^SESSION_SECRET_KEY=change-this-very-long-random-key" "$APP_DIR/.env"; then
    SECRET="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(48))
PY
)"
    sed -i "s|^SESSION_SECRET_KEY=.*|SESSION_SECRET_KEY=${SECRET}|" "$APP_DIR/.env" || true
  fi
fi

chown -R "$APP_USER:$APP_GROUP" "$APP_DIR"
chmod 640 "$APP_DIR/.env" || true

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
