# Реестр отпусков: клиент-серверное приложение

Проект включает:
- веб-сервер реестра отпусков (FastAPI + БД + Excel export + WebSocket рассылка);
- клиент уведомлений (desktop), открывающий список отпусков по клику.

## Логика доставки уведомлений

- если компьютер включен и клиент запущен, уведомление приходит сразу через WebSocket;
- если компьютер был выключен, после включения клиент автоматически забирает пропущенные уведомления через `GET /api/notifications`;
- клиент запоминает последний полученный `notification_id`, поэтому пропущенные события не теряются.

## Сборка пакетов (deb/rpm/exe)

### deb + rpm

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build_linux_packages.ps1 -Version 1.0.0
```

Результат:
- `dist\packages\vacation-registry-server_<version>_amd64.deb`
- `dist\packages\vacation-registry-server-<version>-1.x86_64.rpm`
- `dist\packages\vacation-registry-notifier_<version>_amd64.deb`
- `dist\packages\vacation-registry-notifier-<version>-1.x86_64.rpm`

### exe (Windows installer)

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build_windows_installers.ps1
```

Результат:
- `dist\windows\vacation-server-setup.exe`
- `dist\windows\vacation-notifier-setup.exe`

## Инсталляторы по ОС

### Ubuntu Server

Из `.deb` пакета:

```bash
sudo dpkg -i vacation-registry-server_<version>_amd64.deb
sudo apt-get -f install -y
```

Или скриптом:

```bash
cd /path/to/vacation-registry
chmod +x scripts/install_server_ubuntu.sh
sudo bash scripts/install_server_ubuntu.sh
```

### Astra Linux

Из `.deb` пакета:

```bash
sudo dpkg -i vacation-registry-server_<version>_amd64.deb
sudo apt-get -f install -y
```

```bash
cd /path/to/vacation-registry
chmod +x scripts/install_server_astra.sh scripts/install_notifier_astra.sh
sudo bash scripts/install_server_astra.sh
sudo TARGET_USER=<user> SERVER_HTTP_URL=http://192.168.76.95:8000 SERVER_WS_URL=ws://192.168.76.95:8000/ws/registry bash scripts/install_notifier_astra.sh
```

### ALT Linux

Из `.rpm` пакета:

```bash
sudo rpm -Uvh vacation-registry-server-<version>-1.x86_64.rpm
```

```bash
cd /path/to/vacation-registry
chmod +x scripts/install_server_alt.sh scripts/install_notifier_alt.sh
sudo bash scripts/install_server_alt.sh
sudo TARGET_USER=<user> SERVER_HTTP_URL=http://192.168.76.95:8000 SERVER_WS_URL=ws://192.168.76.95:8000/ws/registry bash scripts/install_notifier_alt.sh
```

### RED OS / Linux desktop (клиент уведомлений)

Из пакетов:

```bash
# DEB
sudo dpkg -i vacation-registry-notifier_<version>_amd64.deb
sudo apt-get -f install -y

# RPM
sudo rpm -Uvh vacation-registry-notifier-<version>-1.x86_64.rpm
```

```bash
cd /path/to/vacation-registry
chmod +x scripts/install_notifier_redos.sh
sudo TARGET_USER=<user> SERVER_HTTP_URL=http://192.168.76.95:8000 SERVER_WS_URL=ws://192.168.76.95:8000/ws/registry bash scripts/install_notifier_redos.sh
```
Автозапуск настраивается автоматически при установке.

### Windows 10 / Windows 7

Есть 2 варианта:

1. Прямые PowerShell-инсталляторы:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install_server_windows.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\install_notifier_windows.ps1 -ServerHttpUrl "http://192.168.76.95:8000" -ServerWsUrl "ws://192.168.76.95:8000/ws/registry"
```

2. Сборка `.exe` installer (Inno Setup):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build_windows_installers.ps1
```

Готовые `.exe` появятся в `dist\windows`.

Важно для Windows 7:
- используйте Python 3.8 (новые версии Python не поддерживают Windows 7).

## Перенос проекта на Ubuntu

### Вариант 1: архив

```bash
chmod +x scripts/create_release_archive.sh
bash scripts/create_release_archive.sh
```

Передайте архив из `dist/` на Ubuntu и распакуйте:

```bash
sudo mkdir -p /opt/vacation-registry
sudo tar -xzf vacation-registry-<version>.tar.gz -C /opt/vacation-registry
cd /opt/vacation-registry
sudo bash scripts/install_server_ubuntu.sh
```

### Вариант 2: через scp/rsync

```bash
scp -r vacation-registry user@192.168.76.95:/tmp/
ssh user@192.168.76.95
sudo mkdir -p /opt/vacation-registry
sudo rsync -a /tmp/vacation-registry/ /opt/vacation-registry/
cd /opt/vacation-registry
sudo bash scripts/install_server_ubuntu.sh
```

## Что делают установщики

### Серверные (`install_server_*.sh`, `install_server_windows.ps1`)
- устанавливают Python и зависимости;
- разворачивают проект в целевую директорию;
- создают виртуальное окружение и ставят `requirements.txt`;
- создают конфиг `.env`;
- регистрируют автозапуск (systemd на Linux, scheduled task на Windows).

### Клиентские (`install_notifier_*.sh`, `install_notifier_windows.ps1`)
- устанавливают клиент уведомлений;
- настраивают URL сервера (`SERVER_HTTP_URL`, `SERVER_WS_URL`);
- создают launcher и автозапуск.

## Основные URL/API

- Веб-форма: `http://192.168.76.95:8000/`
- Активные отпуска: `http://192.168.76.95:8000/active`
- Excel: `http://192.168.76.95:8000/api/vacations/active/export`
- WebSocket: `ws://192.168.76.95:8000/ws/registry`
- Пропущенные уведомления: `http://192.168.76.95:8000/api/notifications?after_id=<id>`

## Поля реестра

1. ФИО сотрудника
2. Должность/должности
3. Статус
4. Услуга
5. Заместитель/и (ФИО)
6. Фактическая должность сотрудника (замещающего)
7. Дата начала отпуска
8. Дата окончания отпуска
9. Памятка

## Авторизация и роли

- В веб-интерфейсе включена авторизация по логину и паролю (`/login`).
- Роли:
  - `admin`: может создавать/изменять записи отпусков и создавать пользователей.
  - `viewer`: может только просматривать таблицу отпусков и выгружать Excel.
- Админ-панель пользователей: `/admin` (доступ только для `admin`).
- Смена собственного пароля: `/account` (доступна всем авторизованным пользователям).
- Администратор может сбросить пароль любого пользователя в `/admin`.
- По умолчанию при первом запуске создается администратор из переменных:
  - `DEFAULT_ADMIN_LOGIN` (по умолчанию `admin`)
  - `DEFAULT_ADMIN_PASSWORD` (по умолчанию `admin12345`)
- Обязательно смените пароль администратора после первого входа.
