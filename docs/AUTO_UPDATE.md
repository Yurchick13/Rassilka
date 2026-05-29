# Автообновление клиентов

Клиент обновляется по манифесту сервера:

- `GET /api/client-update-manifest?platform=windows`
- `GET /api/client-update-manifest?platform=linux-deb`
- `GET /api/client-update-manifest?platform=linux-rpm`

Если `latest_version` в ответе новее текущей версии клиента, он скачивает файл из `update_url` и запускает обновление.

## Откуда берутся файлы обновлений

Сервер раздает файлы из:

- `http://<server>:8000/static/updates/vacation-notifier-setup.exe`
- `http://<server>:8000/static/updates/vacation-registry-notifier_latest_amd64.deb`
- `http://<server>:8000/static/updates/vacation-registry-notifier-latest.x86_64.rpm`

Если URL-поля в админке пустые, сервер подставляет эти адреса автоматически.

## Подпись обновлений Windows

Клиент поддерживает два режима:

- `NOTIFIER_REQUIRE_SIGNED_UPDATES=1` — подпись обязательна, неподписанные EXE будут отклонены.
- `NOTIFIER_REQUIRE_SIGNED_UPDATES=0` — подпись проверяется, но неподписанные EXE разрешены (для закрытого контура без code-signing).

По умолчанию в шаблоне стоит `0`, чтобы автообновление работало сразу.

## Сборка и публикация

1. Собрать установщики:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build_windows_installers.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\build_linux_packages.ps1
```

2. Залить файлы обновлений на сервер:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\publish_updates_to_server.ps1 -ServerIp 192.168.76.95 -ServerUser root
```

3. В админке (`/admin`) включить автообновления и указать `latest_version`.

## Проверка

```powershell
(Invoke-RestMethod -UseBasicParsing "http://192.168.76.95:8000/api/client-update-manifest?platform=windows") | ConvertTo-Json -Depth 5
```

Проверьте:

- `enabled = true`
- `latest_version` — актуальная версия
- `update_url` не `null`
