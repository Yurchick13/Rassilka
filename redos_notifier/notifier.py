from __future__ import annotations

import json
import logging
import os
import platform
import queue
import socket
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import webbrowser
from datetime import datetime, timezone
from pathlib import Path

import websocket

DEFAULT_HTTP_URL = "http://192.168.76.95:8000"
DEFAULT_WS_URL = "ws://192.168.76.95:8000/ws/registry"

TOAST_WIDTH = 470
TOAST_HEIGHT = 185
TOAST_MARGIN = 14
TOAST_AUTO_CLOSE_MS = 12000

TOAST_BG = "#F2F8FC"
TOAST_BORDER = "#BFD7E7"
TOAST_ACCENT = "#0E7490"
TOAST_TITLE = "#0F2940"
TOAST_TEXT = "#13344D"
TOAST_SUBTEXT = "#3B6B8A"
TOAST_BODY_BG = "#FFFFFF"
TOAST_BODY_BORDER = "#D9E7F2"
TOAST_BTN_PRIMARY_BG = "#0F766E"
TOAST_BTN_PRIMARY_FG = "#FFFFFF"
TOAST_BTN_SECONDARY_BG = "#E7F0F8"
TOAST_BTN_SECONDARY_FG = "#1E4764"
TOAST_SPECIAL_ACCENT = "#B91C1C"
TOAST_SPECIAL_BTN_BG = "#9F1239"
TOAST_ICON_BG = "#DFF0FB"
TOAST_ICON_FG = "#0B5A7A"
TOAST_SPECIAL_ICON_BG = "#FEE2E2"
TOAST_SPECIAL_ICON_FG = "#991B1B"

TITLE_TEXT = "\u0412\u043d\u0438\u043c\u0430\u043d\u0438\u0435! \u041e\u0431\u043d\u043e\u0432\u043b\u0435\u043d\u0438\u0435 \u0440\u0435\u0435\u0441\u0442\u0440\u0430 \u043e\u0442\u043f\u0443\u0441\u043a\u043e\u0432"
SUBTITLE_TEXT = ""
SPECIAL_SUBTITLE_TEXT = "\u041e\u0441\u043e\u0431\u044b\u0439 \u0441\u043e\u0442\u0440\u0443\u0434\u043d\u0438\u043a \u0432 \u043e\u0442\u043f\u0443\u0441\u043a\u0435"
DEFAULT_NOTIFICATION_TEXT = (
    "\u0412\u043d\u0438\u043c\u0430\u043d\u0438\u0435! \u041e\u0431\u043d\u043e\u0432\u043b\u0435\u043d\u0438\u0435 "
    "\u0440\u0435\u0435\u0441\u0442\u0440\u0430 \u043e\u0442\u043f\u0443\u0441\u043a\u043e\u0432! "
    "\u041d\u0435\u043e\u0431\u0445\u043e\u0434\u0438\u043c\u043e \u043e\u0437\u043d\u0430\u043a\u043e\u043c\u0438\u0442\u044c\u0441\u044f \u0441 \u0438\u043d\u0444\u043e\u0440\u043c\u0430\u0446\u0438\u0435\u0439!"
)
STARTUP_NOTIFICATION_TEXT = (
    "\u041a\u043b\u0438\u0435\u043d\u0442 \u0443\u0432\u0435\u0434\u043e\u043c\u043b\u0435\u043d\u0438\u0439 \u0437\u0430\u043f\u0443\u0449\u0435\u043d. "
    "\u041e\u0436\u0438\u0434\u0430\u0435\u043c \u043e\u0431\u043d\u043e\u0432\u043b\u0435\u043d\u0438\u044f \u0440\u0435\u0435\u0441\u0442\u0440\u0430 \u043e\u0442\u043f\u0443\u0441\u043a\u043e\u0432."
)
SPECIAL_ALERT_TOKEN = "\u043e\u0441\u043e\u0431\u044b\u0439 \u0441\u043e\u0442\u0440\u0443\u0434\u043d\u0438\u043a"
MIN_REPEAT_INTERVAL_MINUTES = 0
MAX_REPEAT_INTERVAL_MINUTES = 1440


def _configure_logging() -> logging.Logger:
    if os.name == "nt":
        base = Path(os.getenv("LOCALAPPDATA", str(Path.home())))
    else:
        base = Path(os.getenv("XDG_STATE_HOME", str(Path.home() / ".local" / "state")))
    log_dir = base / "vacation-notifier"
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / "notifier.log"

    logger = logging.getLogger("vacation_notifier")
    if logger.handlers:
        return logger

    logger.setLevel(logging.INFO)
    formatter = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")

    file_handler = logging.FileHandler(log_file, encoding="utf-8")
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)
    return logger


LOGGER = _configure_logging()


def _import_tkinter():
    try:
        import tkinter as tk_module
    except Exception as exc:
        LOGGER.warning("Tkinter is not available: %s", exc)
        return None
    return tk_module


tk = _import_tkinter()


def _read_env_file() -> dict[str, str]:
    candidates: list[Path] = []

    env_file = os.getenv("NOTIFIER_ENV_FILE", "").strip()
    if env_file:
        candidates.append(Path(env_file))

    cwd = Path.cwd()
    candidates.append(cwd / ".env")

    script_root = Path(__file__).resolve().parent
    candidates.append(script_root / ".env")
    candidates.append(script_root.parent / ".env")

    if getattr(sys, "frozen", False):
        exe_root = Path(sys.executable).resolve().parent
        candidates.append(exe_root / ".env")
        candidates.append(exe_root.parent / ".env")

    for path in candidates:
        if not path.exists() or not path.is_file():
            continue

        parsed: dict[str, str] = {}
        try:
            for line in path.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                parsed[key.strip()] = value.strip().strip('"').strip("'")
            return parsed
        except Exception:
            continue

    return {}


_FILE_ENV = _read_env_file()


def _read_server_urls() -> tuple[str, str]:
    base_url = os.getenv("SERVER_URL", _FILE_ENV.get("SERVER_URL", "")).strip()
    http_url = os.getenv("SERVER_HTTP_URL", _FILE_ENV.get("SERVER_HTTP_URL", "")).strip()
    ws_url = os.getenv("SERVER_WS_URL", _FILE_ENV.get("SERVER_WS_URL", "")).strip()

    if base_url and not http_url:
        http_url = base_url
    if http_url and not ws_url:
        ws_url = http_url.replace("https://", "wss://").replace("http://", "ws://") + "/ws/registry"

    if not http_url:
        http_url = DEFAULT_HTTP_URL
    if not ws_url:
        ws_url = DEFAULT_WS_URL

    return http_url.rstrip("/"), ws_url


SERVER_HTTP_URL, SERVER_WS_URL = _read_server_urls()


def _read_poll_interval() -> int:
    try:
        raw = int(os.getenv("POLL_INTERVAL_SECONDS", _FILE_ENV.get("POLL_INTERVAL_SECONDS", "20")))
    except ValueError:
        raw = 20
    return max(5, raw)


POLL_INTERVAL_SECONDS = _read_poll_interval()


def _read_int_env(name: str, default: int) -> int:
    raw = os.getenv(name, _FILE_ENV.get(name, str(default))).strip()
    try:
        value = int(raw)
    except ValueError:
        value = default
    return value


def _read_bool_env(name: str, default: bool) -> bool:
    raw = os.getenv(name, _FILE_ENV.get(name, str(int(default)))).strip().lower()
    if raw in {"1", "true", "yes", "on"}:
        return True
    if raw in {"0", "false", "no", "off"}:
        return False
    return default


def _read_notifier_version() -> str:
    env_value = os.getenv("NOTIFIER_APP_VERSION", _FILE_ENV.get("NOTIFIER_APP_VERSION", "")).strip()
    if env_value:
        return env_value

    candidates: list[Path] = []
    root = Path(__file__).resolve().parent
    candidates.append(root / "VERSION")
    candidates.append(root.parent / "VERSION")
    if getattr(sys, "frozen", False):
        exe_root = Path(sys.executable).resolve().parent
        candidates.append(exe_root / "VERSION")
        candidates.append(exe_root.parent / "VERSION")

    for path in candidates:
        try:
            value = path.read_text(encoding="utf-8").strip()
        except Exception:
            continue
        if value:
            return value

    return "0.0.0"


def _split_version_parts(value: str) -> tuple:
    token = str(value or "").strip().lower().lstrip("v")
    if not token:
        return (0,)
    parts: list[tuple[int, str]] = []
    for chunk in token.replace("-", ".").split("."):
        piece = chunk.strip()
        if not piece:
            continue
        digits = "".join(ch for ch in piece if ch.isdigit())
        letters = "".join(ch for ch in piece if ch.isalpha())
        if digits:
            parts.append((int(digits), letters))
        else:
            parts.append((0, letters))
    return tuple(parts) if parts else (0,)


def _version_is_newer(candidate: str, current: str) -> bool:
    return _split_version_parts(candidate) > _split_version_parts(current)


def _detect_linux_update_platform() -> str:
    os_release = Path("/etc/os-release")
    if not os_release.exists():
        return "linux"
    try:
        text = os_release.read_text(encoding="utf-8", errors="ignore").lower()
    except Exception:
        return "linux"
    if any(key in text for key in ("rhel", "fedora", "centos", "redos", "altlinux", "alt")):
        return "linux-rpm"
    if any(key in text for key in ("debian", "ubuntu", "astra")):
        return "linux-deb"
    return "linux"


APP_VERSION = _read_notifier_version()
CLIENT_HOSTNAME = socket.gethostname() or "unknown-host"
CLIENT_USERNAME = os.getenv("USERNAME") or os.getenv("USER") or os.getenv("LOGNAME") or "unknown-user"
CLIENT_OS_NAME = platform.system() or "unknown"
CLIENT_OS_VERSION = platform.version() or platform.release() or "unknown"
CLIENT_PLATFORM = (
    "windows"
    if os.name == "nt"
    else _detect_linux_update_platform()
)
HEARTBEAT_INTERVAL_SECONDS = max(20, _read_int_env("HEARTBEAT_INTERVAL_SECONDS", 60))
AUTO_UPDATE_ENABLED = _read_bool_env("NOTIFIER_AUTO_UPDATE_ENABLED", True)
CLIENT_HEARTBEAT_TOKEN = os.getenv("CLIENT_HEARTBEAT_TOKEN", _FILE_ENV.get("CLIENT_HEARTBEAT_TOKEN", "")).strip()
REQUIRE_SIGNED_UPDATES = _read_bool_env("NOTIFIER_REQUIRE_SIGNED_UPDATES", False)
UPDATE_SIGNER_THUMBPRINT = os.getenv(
    "NOTIFIER_UPDATE_SIGNER_THUMBPRINT",
    _FILE_ENV.get("NOTIFIER_UPDATE_SIGNER_THUMBPRINT", ""),
).strip().replace(" ", "").upper()
UPDATE_SIGNER_SUBJECT = os.getenv(
    "NOTIFIER_UPDATE_SIGNER_SUBJECT",
    _FILE_ENV.get("NOTIFIER_UPDATE_SIGNER_SUBJECT", ""),
).strip().lower()


def _normalize_repeat_interval_minutes(value: object, default: int = 0) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        parsed = int(default)
    return max(MIN_REPEAT_INTERVAL_MINUTES, min(MAX_REPEAT_INTERVAL_MINUTES, parsed))


_SINGLE_INSTANCE_LOCK = None


def _state_file_path() -> Path:
    if os.name == "nt":
        base = Path(os.getenv("LOCALAPPDATA", str(Path.home())))
    else:
        base = Path(os.getenv("XDG_STATE_HOME", str(Path.home() / ".local" / "state")))
    return base / "vacation-notifier" / "state.json"


def _read_windows_machine_guid() -> str:
    if os.name != "nt":
        return ""
    try:
        import winreg
    except Exception:
        return ""

    views = [0]
    wow64_64 = getattr(winreg, "KEY_WOW64_64KEY", 0)
    if wow64_64:
        views.insert(0, wow64_64)

    for view in views:
        try:
            with winreg.OpenKey(
                winreg.HKEY_LOCAL_MACHINE,
                r"SOFTWARE\Microsoft\Cryptography",
                0,
                winreg.KEY_READ | view,
            ) as key:
                value, _ = winreg.QueryValueEx(key, "MachineGuid")
                machine_guid = str(value or "").strip().lower()
                if machine_guid:
                    return machine_guid
        except Exception:
            continue
    return ""


def _read_linux_machine_id() -> str:
    for candidate in ("/etc/machine-id", "/var/lib/dbus/machine-id"):
        path = Path(candidate)
        if not path.exists():
            continue
        try:
            machine_id = path.read_text(encoding="utf-8", errors="ignore").strip().lower()
        except Exception:
            continue
        if machine_id:
            return machine_id
    return ""


def _normalize_mac_address(value: object) -> str:
    raw = "".join(ch for ch in str(value or "").lower() if ch in "0123456789abcdef")
    if len(raw) != 12:
        return ""
    if raw == "000000000000" or raw == "ffffffffffff":
        return ""
    try:
        first_octet = int(raw[:2], 16)
    except ValueError:
        return ""
    if first_octet & 1:
        return ""
    return ":".join(raw[index : index + 2] for index in range(0, 12, 2))


def _read_primary_mac_address() -> str:
    if os.name != "nt":
        sys_class_net = Path("/sys/class/net")
        if sys_class_net.exists():
            preferred: list[str] = []
            fallback: list[str] = []
            for iface in sorted(sys_class_net.iterdir(), key=lambda item: item.name):
                name = iface.name.lower()
                if name == "lo" or name.startswith(("docker", "veth", "br-", "virbr", "tun", "tap")):
                    continue
                try:
                    mac = _normalize_mac_address((iface / "address").read_text(encoding="utf-8", errors="ignore"))
                except Exception:
                    continue
                if not mac:
                    continue
                try:
                    operstate = (iface / "operstate").read_text(encoding="utf-8", errors="ignore").strip().lower()
                except Exception:
                    operstate = ""
                if operstate in {"up", "unknown"}:
                    preferred.append(mac)
                else:
                    fallback.append(mac)
            if preferred or fallback:
                return (preferred or fallback)[0]

    node = uuid.getnode()
    if (node >> 40) & 1:
        return ""
    return _normalize_mac_address(f"{node:012x}")


def _build_stable_client_id() -> str:
    explicit_client_id = os.getenv("NOTIFIER_CLIENT_ID", _FILE_ENV.get("NOTIFIER_CLIENT_ID", "")).strip()
    if explicit_client_id:
        return explicit_client_id[:120]

    mac_address = _read_primary_mac_address()
    if mac_address:
        return f"mac-{mac_address.replace(':', '')}"

    machine_identity = _read_windows_machine_guid() or _read_linux_machine_id() or CLIENT_HOSTNAME
    seed = f"vacation-notifier|{machine_identity}"
    return f"vn-{uuid.uuid5(uuid.NAMESPACE_DNS, seed)}"


def _resolve_client_id(existing_client_id: str | None) -> str:
    preferred = _build_stable_client_id()
    current = str(existing_client_id or "").strip()
    return preferred


def _acquire_single_instance_lock() -> bool:
    global _SINGLE_INSTANCE_LOCK

    lock_path = _state_file_path().with_name("notifier.lock")
    lock_path.parent.mkdir(parents=True, exist_ok=True)

    lock_file = lock_path.open("a+", encoding="utf-8")
    try:
        if os.name == "nt":
            # Windows lock is best-effort; keep file handle open for lifetime.
            try:
                import msvcrt

                msvcrt.locking(lock_file.fileno(), msvcrt.LK_NBLCK, 1)
            except Exception:
                lock_file.close()
                return False
        else:
            import fcntl

            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except Exception:
        lock_file.close()
        return False

    _SINGLE_INSTANCE_LOCK = lock_file
    return True


def _is_special_alert_message(message: str) -> bool:
    return SPECIAL_ALERT_TOKEN in str(message or "").lower()


class NotifierApp:
    def __init__(self) -> None:
        self._gui_enabled = False
        self.root = None
        if tk is not None:
            try:
                self.root = tk.Tk()
                # The app runs headless in background: no permanent main window.
                self.root.withdraw()
                self._gui_enabled = True
            except Exception as exc:
                LOGGER.warning("GUI mode is unavailable, switching to system notifications: %s", exc)

        self.messages: queue.Queue[dict] = queue.Queue()
        self.ws_app: websocket.WebSocketApp | None = None
        self._ws_connected = False
        self._state_lock = threading.Lock()
        self._pending_lock = threading.Lock()
        self._repeat_lock = threading.Lock()
        self._repeat_timer: threading.Timer | None = None
        self._repeat_payload: dict | None = None
        self._notification_repeat_interval_minutes = 0
        self._state_file = _state_file_path()
        self._state = self._load_state()
        self._toasts: list[tk.Toplevel] = []
        self._pending_event_keys: set[str] = set()
        self._update_lock = threading.Lock()
        self._update_status = "idle"
        self._update_error = ""
        self._update_check_interval_seconds = 3600
        self._last_update_check_monotonic = 0.0
        self._last_heartbeat_monotonic = 0.0

        LOGGER.info(
            "Notifier started. HTTP=%s WS=%s State=%s Version=%s Platform=%s",
            SERVER_HTTP_URL,
            SERVER_WS_URL,
            self._state_file,
            APP_VERSION,
            CLIENT_PLATFORM,
        )
        self._refresh_notification_config()
        self._prime_repeat_from_latest_notification()
        self._trigger_heartbeat(reason="startup")

        self._fetch_missed_notifications_async()
        self._start_periodic_polling()
        self._start_ws_listener()
        if self._gui_enabled and self.root is not None:
            self.root.after(400, self._drain_queue)
        else:
            thread = threading.Thread(target=self._headless_drain_loop, daemon=True)
            thread.start()
        self._enqueue_startup_notification()

    def _default_state(self) -> dict:
        return {
            "client_id": _resolve_client_id(None),
            "last_notification_id": 0,
            "last_notification_created_at": "",
            "last_update_target_version": "",
        }

    def _load_state(self) -> dict:
        self._state_file.parent.mkdir(parents=True, exist_ok=True)
        if not self._state_file.exists():
            state = self._default_state()
            self._save_state(state)
            return state

        try:
            raw = json.loads(self._state_file.read_text(encoding="utf-8"))
            if "client_id" not in raw:
                raise ValueError("invalid state")
            raw_client_id = str(raw.get("client_id", "") or "")
            resolved_client_id = _resolve_client_id(raw_client_id)
            if resolved_client_id != raw_client_id:
                raw["client_id"] = resolved_client_id
            raw["last_notification_id"] = max(0, int(raw.get("last_notification_id", 0)))
            raw["last_notification_created_at"] = str(raw.get("last_notification_created_at", "") or "")
            raw["last_update_target_version"] = str(raw.get("last_update_target_version", "") or "")
            self._save_state(raw)
            return raw
        except Exception:
            state = self._default_state()
            self._save_state(state)
            return state

    def _save_state(self, state: dict) -> None:
        self._state_file.parent.mkdir(parents=True, exist_ok=True)
        self._state_file.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")

    def _get_last_notification_id(self) -> int:
        with self._state_lock:
            return int(self._state.get("last_notification_id", 0))

    @staticmethod
    def _parse_event_datetime(value: object) -> datetime | None:
        if value is None:
            return None
        text = str(value).strip()
        if not text:
            return None
        try:
            if text.endswith("Z"):
                text = text[:-1] + "+00:00"
            dt = datetime.fromisoformat(text)
        except ValueError:
            return None
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)

    @staticmethod
    def _format_event_datetime(value: datetime | None) -> str:
        if value is None:
            return ""
        return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")

    def _notification_key(self, notification_id: int | None, notification_created_at: datetime | None) -> str:
        parts: list[str] = []
        if isinstance(notification_id, int) and notification_id > 0:
            parts.append(f"id:{notification_id}")
        if notification_created_at:
            parts.append(f"at:{self._format_event_datetime(notification_created_at)}")
        if not parts:
            parts.append(f"ephemeral:{time.time_ns()}")
        return "|".join(parts)

    def _is_new_notification(self, notification_id: int | None, notification_created_at: datetime | None) -> bool:
        with self._state_lock:
            current_id = int(self._state.get("last_notification_id", 0))
            current_created_at = self._parse_event_datetime(self._state.get("last_notification_created_at"))

        if notification_created_at and current_created_at:
            if notification_created_at > current_created_at:
                return True
            if notification_created_at < current_created_at:
                return False
            if isinstance(notification_id, int) and notification_id > current_id:
                return True
            return False

        if notification_created_at and not current_created_at:
            return True

        if isinstance(notification_id, int) and notification_id > current_id:
            return True

        return False

    def _mark_notification_seen(
        self,
        notification_id: int | None,
        notification_created_at: datetime | None = None,
    ) -> None:
        with self._state_lock:
            current_id = int(self._state.get("last_notification_id", 0))
            current_created_at = self._parse_event_datetime(self._state.get("last_notification_created_at"))

            should_update = False
            if notification_created_at and current_created_at:
                if notification_created_at > current_created_at:
                    should_update = True
                elif notification_created_at == current_created_at:
                    if isinstance(notification_id, int) and notification_id > current_id:
                        should_update = True
            elif notification_created_at and not current_created_at:
                should_update = True
            elif isinstance(notification_id, int) and notification_id > current_id:
                should_update = True

            if not should_update:
                return

            if isinstance(notification_id, int) and notification_id > 0:
                self._state["last_notification_id"] = notification_id
            if notification_created_at:
                self._state["last_notification_created_at"] = self._format_event_datetime(notification_created_at)
            self._save_state(self._state)

    def _set_repeat_interval_minutes(self, value: object) -> None:
        normalized = _normalize_repeat_interval_minutes(value, self._notification_repeat_interval_minutes)
        with self._repeat_lock:
            self._notification_repeat_interval_minutes = normalized
            payload_exists = self._repeat_payload is not None
        if not payload_exists:
            return
        if normalized <= 0:
            self._cancel_repeat_timer()
        else:
            self._restart_repeat_timer()

    def _request_notification_config(self) -> dict | None:
        url = f"{SERVER_HTTP_URL.rstrip('/')}/api/notification-config"
        try:
            with urllib.request.urlopen(url, timeout=8) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
            LOGGER.warning("Notification config request failed: %s", exc)
            return None
        if isinstance(payload, dict):
            return payload
        return None

    def _refresh_notification_config(self) -> None:
        payload = self._request_notification_config()
        if not payload:
            return
        self._set_repeat_interval_minutes(payload.get("repeat_interval_minutes", 0))
        with self._repeat_lock:
            has_payload = self._repeat_payload is not None
            interval_minutes = self._notification_repeat_interval_minutes
        if interval_minutes > 0 and not has_payload:
            self._prime_repeat_from_latest_notification()

    def _client_headers(self) -> dict[str, str]:
        headers = {
            "Accept": "application/json",
            "User-Agent": f"vacation-notifier/{APP_VERSION}",
        }
        if CLIENT_HEARTBEAT_TOKEN:
            headers["X-Client-Token"] = CLIENT_HEARTBEAT_TOKEN
        return headers

    def _set_update_state(self, status: str, error: str = "") -> None:
        with self._update_lock:
            self._update_status = status
            self._update_error = str(error or "")[:2000]

    def _request_json(self, url: str, *, timeout: int = 10) -> dict | list | None:
        req = urllib.request.Request(url, headers=self._client_headers(), method="GET")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
            LOGGER.warning("Request failed (%s): %s", url, exc)
            return None
        return payload

    def _request_update_manifest(self) -> dict | None:
        platform_query = urllib.parse.urlencode({"platform": CLIENT_PLATFORM})
        url = f"{SERVER_HTTP_URL.rstrip('/')}/api/client-update-manifest?{platform_query}"
        payload = self._request_json(url, timeout=10)
        if not isinstance(payload, dict):
            return None

        interval_minutes = payload.get("check_interval_minutes", 60)
        try:
            interval_seconds = max(300, int(interval_minutes) * 60)
        except (TypeError, ValueError):
            interval_seconds = 3600
        self._update_check_interval_seconds = interval_seconds
        return payload

    def _build_heartbeat_payload(self) -> dict:
        with self._state_lock:
            client_id = str(self._state.get("client_id", ""))
            last_notification_id = int(self._state.get("last_notification_id", 0))
        with self._update_lock:
            update_status = self._update_status
            update_error = self._update_error

        return {
            "client_id": client_id,
            "app_version": APP_VERSION,
            "app_channel": "stable",
            "hostname": CLIENT_HOSTNAME,
            "username": CLIENT_USERNAME,
            "os_name": CLIENT_OS_NAME,
            "os_version": CLIENT_OS_VERSION,
            "mac_address": _read_primary_mac_address(),
            "mode": "gui" if self._gui_enabled else "headless",
            "last_notification_id": max(0, last_notification_id),
            "update_supported": True,
            "update_status": update_status,
            "update_error": update_error,
        }

    def _post_heartbeat(self) -> None:
        url = f"{SERVER_HTTP_URL.rstrip('/')}/api/client-heartbeat"
        payload = self._build_heartbeat_payload()
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers = self._client_headers()
        headers["Content-Type"] = "application/json; charset=utf-8"
        req = urllib.request.Request(url, data=body, headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=8) as response:
            response.read()

    def _trigger_heartbeat(self, *, reason: str) -> None:
        try:
            self._post_heartbeat()
            self._last_heartbeat_monotonic = time.monotonic()
            LOGGER.info("Heartbeat sent (%s).", reason)
        except Exception as exc:
            LOGGER.warning("Heartbeat failed (%s): %s", reason, exc)

    @staticmethod
    def _download_to_temp_file(url: str, *, suffix: str) -> Path:
        request = urllib.request.Request(url, headers={"User-Agent": f"vacation-notifier/{APP_VERSION}"})
        with urllib.request.urlopen(request, timeout=60) as response:
            data = response.read()
        fd, temp_path = tempfile.mkstemp(prefix="vacation-notifier-update-", suffix=suffix)
        os.close(fd)
        output = Path(temp_path)
        output.write_bytes(data)
        return output

    @staticmethod
    def _verify_windows_installer_signature(installer_path: Path) -> None:
        if os.name != "nt":
            return
        installer_path = Path(installer_path)
        if not installer_path.exists():
            raise RuntimeError(f"Файл обновления не найден: {installer_path}")

        powershell_bin = shutil.which("powershell.exe") or shutil.which("powershell")
        if not powershell_bin:
            raise RuntimeError("PowerShell не найден для проверки подписи обновления.")

        # Use inline -Command with explicit scriptblock invocation and named
        # parameter binding. This avoids both:
        # 1) occasional empty FilePath binding issues
        # 2) execution-policy blocks for temporary unsigned .ps1 files.
        escaped_file_path = str(installer_path).replace("'", "''")
        command = (
            "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); "
            "$ErrorActionPreference = 'Stop'; "
            "& { "
            "param([string]$FilePath) "
            "if ([string]::IsNullOrWhiteSpace($FilePath)) { throw 'Empty FilePath argument.' } "
            "$sig = Get-AuthenticodeSignature -FilePath $FilePath; "
            "if ($null -eq $sig) { throw 'Signature info unavailable.' } "
            "$subject = ''; "
            "$thumbprint = ''; "
            "if ($sig.SignerCertificate) { "
            "  $subject = [string]$sig.SignerCertificate.Subject; "
            "  $thumbprint = [string]$sig.SignerCertificate.Thumbprint; "
            "} "
            "[PSCustomObject]@{"
            "Status=[string]$sig.Status;"
            "StatusMessage=[string]$sig.StatusMessage;"
            "Subject=$subject;"
            "Thumbprint=$thumbprint"
            "} | ConvertTo-Json -Compress -Depth 3 "
            f"}} -FilePath '{escaped_file_path}'"
        )
        cmd = [
            powershell_bin,
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            command,
        ]
        run_kwargs = {
            "capture_output": True,
            "text": True,
            "encoding": "utf-8",
            "errors": "replace",
            "check": False,
        }
        if os.name == "nt":
            startupinfo = subprocess.STARTUPINFO()
            startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startupinfo.wShowWindow = 0
            run_kwargs["startupinfo"] = startupinfo
            run_kwargs["creationflags"] = getattr(subprocess, "CREATE_NO_WINDOW", 0)

        result = subprocess.run(cmd, **run_kwargs)

        signature_expected = REQUIRE_SIGNED_UPDATES or bool(UPDATE_SIGNER_THUMBPRINT) or bool(UPDATE_SIGNER_SUBJECT)

        if result.returncode != 0:
            stderr = (result.stderr or "").strip()
            stdout = (result.stdout or "").strip()
            reason = stderr or stdout or f"powershell exit code {result.returncode}"
            if signature_expected:
                raise RuntimeError(f"Не удалось проверить подпись обновления: {reason}")
            LOGGER.warning("Signature verification skipped (strict mode is off): %s", reason)
            return

        raw = (result.stdout or "").strip()
        if not raw:
            if signature_expected:
                raise RuntimeError("Проверка подписи вернула пустой ответ.")
            LOGGER.warning("Signature verification returned empty output; skipped because strict mode is off.")
            return
        json_line = raw.splitlines()[-1].strip()
        try:
            payload = json.loads(json_line)
        except json.JSONDecodeError as exc:
            if signature_expected:
                raise RuntimeError(f"Некорректный ответ проверки подписи: {json_line}") from exc
            LOGGER.warning(
                "Signature verification returned non-JSON output; skipped because strict mode is off: %s",
                json_line,
            )
            return

        status = str(payload.get("Status", "")).strip()
        status_message = str(payload.get("StatusMessage", "")).strip()
        subject = str(payload.get("Subject", "")).strip()
        thumbprint = str(payload.get("Thumbprint", "")).strip().replace(" ", "").upper()

        if status != "Valid":
            reason = status_message or status or "Unknown signature status"
            if signature_expected:
                raise RuntimeError(f"Подпись обновления недействительна: {reason}")
            LOGGER.warning(
                "Unsigned/untrusted installer accepted because strict signature validation is off. "
                "Status=%s Message=%s",
                status or "unknown",
                status_message or "n/a",
            )
            return

        if UPDATE_SIGNER_THUMBPRINT and thumbprint != UPDATE_SIGNER_THUMBPRINT:
            raise RuntimeError("Сертификат обновления не совпадает с ожидаемым thumbprint.")

        if UPDATE_SIGNER_SUBJECT and UPDATE_SIGNER_SUBJECT not in subject.lower():
            raise RuntimeError("Сертификат обновления не совпадает с ожидаемым владельцем.")

    def _apply_windows_update(self, target_version: str, update_url: str) -> None:
        self._set_update_state("downloading")
        installer_path = self._download_to_temp_file(update_url, suffix=".exe")
        self._set_update_state("validating_signature")
        self._verify_windows_installer_signature(installer_path)
        self._set_update_state("installing")
        with self._state_lock:
            self._state["last_update_target_version"] = target_version
            self._save_state(self._state)

        args = [
            str(installer_path),
            "/VERYSILENT",
            "/SUPPRESSMSGBOXES",
            "/NORESTART",
            "/SP-",
        ]
        popen_kwargs = {"close_fds": True}
        if os.name == "nt":
            startupinfo = subprocess.STARTUPINFO()
            startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startupinfo.wShowWindow = 0
            popen_kwargs["startupinfo"] = startupinfo
            popen_kwargs["creationflags"] = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        subprocess.Popen(args, **popen_kwargs)
        LOGGER.info("Update installer started: %s (target=%s)", installer_path, target_version)
        time.sleep(1)
        os._exit(0)

    def _apply_linux_update(self, target_version: str, update_url: str) -> None:
        if os.geteuid() != 0:
            self._set_update_state("update_available_manual", "Нужны права root для обновления Linux-пакета.")
            LOGGER.info("Linux update available but root privileges are required: %s", update_url)
            return

        if update_url.endswith(".deb"):
            suffix = ".deb"
            install_cmd = ["dpkg", "-i"]
        elif update_url.endswith(".rpm"):
            suffix = ".rpm"
            install_cmd = ["rpm", "-Uvh", "--replacepkgs", "--replacefiles"]
        else:
            self._set_update_state("update_failed", "Неподдерживаемый формат Linux-пакета.")
            return

        self._set_update_state("downloading")
        pkg_path = self._download_to_temp_file(update_url, suffix=suffix)
        self._set_update_state("installing")
        try:
            subprocess.run(install_cmd + [str(pkg_path)], check=True)
            if suffix == ".rpm":
                self._cleanup_old_linux_rpm_versions(target_version)
        finally:
            try:
                pkg_path.unlink(missing_ok=True)
            except Exception:
                pass

        with self._state_lock:
            self._state["last_update_target_version"] = target_version
            self._save_state(self._state)
        LOGGER.info("Linux package updated to %s", target_version)

    def _cleanup_old_linux_rpm_versions(self, target_version: str) -> None:
        target_version = str(target_version or "").strip()
        if not target_version:
            return
        try:
            result = subprocess.run(
                ["rpm", "-qa"],
                check=True,
                capture_output=True,
                text=True,
            )
        except Exception as exc:
            LOGGER.debug("Cannot list RPM packages for cleanup: %s", exc)
            return

        for raw_name in (result.stdout or "").splitlines():
            package_name = raw_name.strip()
            if not package_name.startswith("vacation-registry-notifier-"):
                continue
            if package_name.startswith(f"vacation-registry-notifier-{target_version}-"):
                continue
            try:
                subprocess.run(
                    ["rpm", "-e", "--noscripts", "--nodeps", package_name],
                    check=False,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            except Exception as exc:
                LOGGER.debug("Cannot remove old RPM package %s: %s", package_name, exc)

    def _check_for_updates(self) -> None:
        if not AUTO_UPDATE_ENABLED:
            return

        now_mono = time.monotonic()
        if self._last_update_check_monotonic > 0 and (
            now_mono - self._last_update_check_monotonic < self._update_check_interval_seconds
        ):
            return
        self._last_update_check_monotonic = now_mono

        manifest = self._request_update_manifest()
        if not manifest:
            return

        enabled = bool(manifest.get("enabled", False))
        latest_version = str(manifest.get("latest_version", "")).strip()
        update_url = str(manifest.get("update_url", "")).strip()

        if not enabled:
            self._set_update_state("disabled")
            return

        if not latest_version:
            self._set_update_state("up_to_date")
            return

        if not _version_is_newer(latest_version, APP_VERSION):
            self._set_update_state("up_to_date")
            return

        if not update_url:
            self._set_update_state("update_available_no_url", "Не указан URL обновления.")
            return

        self._set_update_state("update_available")
        try:
            if os.name == "nt":
                self._apply_windows_update(latest_version, update_url)
            else:
                self._apply_linux_update(latest_version, update_url)
        except Exception as exc:
            self._set_update_state("update_failed", str(exc))
            LOGGER.exception("Auto-update failed")

    def _prime_repeat_from_latest_notification(self) -> None:
        payload = self._request_notifications(after_id=0, limit=1)
        if payload is None or not payload:
            return
        latest = payload[-1]
        message = str(latest.get("message", DEFAULT_NOTIFICATION_TEXT))
        repeat_interval_minutes = _normalize_repeat_interval_minutes(
            latest.get("repeat_interval_minutes", self._notification_repeat_interval_minutes),
            self._notification_repeat_interval_minutes,
        )
        self._update_repeat_source(
            message=message,
            is_special_alert=_is_special_alert_message(message),
            special_employee_names=[],
            repeat_interval_minutes=repeat_interval_minutes,
        )

    def _schedule_repeat_tick(self) -> None:
        with self._repeat_lock:
            payload = dict(self._repeat_payload or {})
            interval_minutes = self._notification_repeat_interval_minutes
        if not payload or interval_minutes <= 0:
            return

        self.messages.put(
            {
                "kind": "reminder",
                "text": payload.get("text", DEFAULT_NOTIFICATION_TEXT),
                "is_special_alert": bool(payload.get("is_special_alert")),
                "special_employee_names": payload.get("special_employee_names", []),
            }
        )
        self._restart_repeat_timer()

    def _cancel_repeat_timer(self) -> None:
        with self._repeat_lock:
            timer = self._repeat_timer
            self._repeat_timer = None
        if timer is not None:
            timer.cancel()

    def _restart_repeat_timer(self) -> None:
        with self._repeat_lock:
            payload_exists = self._repeat_payload is not None
            interval_minutes = self._notification_repeat_interval_minutes
            old_timer = self._repeat_timer
            self._repeat_timer = None
        if old_timer is not None:
            old_timer.cancel()
        if not payload_exists or interval_minutes <= 0:
            return
        timer = threading.Timer(interval_minutes * 60, self._schedule_repeat_tick)
        timer.daemon = True
        with self._repeat_lock:
            self._repeat_timer = timer
        timer.start()

    def _update_repeat_source(
        self,
        *,
        message: str,
        is_special_alert: bool,
        special_employee_names: list[str],
        repeat_interval_minutes: int | None = None,
    ) -> None:
        with self._repeat_lock:
            self._repeat_payload = {
                "text": message,
                "is_special_alert": bool(is_special_alert),
                "special_employee_names": list(special_employee_names),
            }
        if repeat_interval_minutes is not None:
            self._set_repeat_interval_minutes(repeat_interval_minutes)
        self._restart_repeat_timer()

    def _enqueue_startup_notification(self) -> None:
        self.messages.put(
            {
                "kind": "startup",
                "text": STARTUP_NOTIFICATION_TEXT,
                "is_special_alert": False,
                "special_employee_names": [],
            }
        )

    def _enqueue_notification(
        self,
        message: str,
        notification_id: int | None,
        *,
        notification_created_at: datetime | None = None,
        is_special_alert: bool = False,
        special_employee_names: list[str] | None = None,
        repeat_interval_minutes: int | None = None,
    ) -> None:
        if not self._is_new_notification(notification_id, notification_created_at):
            return

        event_key = self._notification_key(notification_id, notification_created_at)
        with self._pending_lock:
            if event_key in self._pending_event_keys:
                return
            self._pending_event_keys.add(event_key)

        self.messages.put(
            {
                "kind": "notification",
                "text": message,
                "notification_id": notification_id,
                "notification_created_at": notification_created_at,
                "event_key": event_key,
                "is_special_alert": is_special_alert,
                "special_employee_names": special_employee_names or [],
                "repeat_interval_minutes": _normalize_repeat_interval_minutes(
                    repeat_interval_minutes if repeat_interval_minutes is not None else self._notification_repeat_interval_minutes,
                    0,
                ),
            }
        )

    def _request_notifications(self, *, after_id: int, limit: int = 500) -> list[dict] | None:
        query = urllib.parse.urlencode({"after_id": max(0, int(after_id)), "limit": max(1, int(limit))})
        url = f"{SERVER_HTTP_URL.rstrip('/')}/api/notifications?{query}"
        try:
            with urllib.request.urlopen(url, timeout=8) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
            LOGGER.warning("Polling failed: %s", exc)
            return None

        if isinstance(payload, list):
            return payload
        return []

    def _detect_and_reset_cursor_if_server_restarted(self, current_after_id: int) -> bool:
        if current_after_id <= 0:
            return False

        latest_payload = self._request_notifications(after_id=0, limit=1)
        if latest_payload is None or not latest_payload:
            return False

        latest_id = int(latest_payload[-1].get("id", 0))
        if latest_id <= 0 or latest_id >= current_after_id:
            return False

        LOGGER.warning(
            "Notification ID sequence reset detected: local_after_id=%s, server_latest_id=%s. Resetting local cursor.",
            current_after_id,
            latest_id,
        )
        with self._state_lock:
            self._state["last_notification_id"] = 0
            self._state["last_notification_created_at"] = ""
            self._save_state(self._state)
        with self._pending_lock:
            self._pending_event_keys.clear()
        return True

    def _fetch_missed_notifications(self) -> None:
        after_id = self._get_last_notification_id()
        payload = self._request_notifications(after_id=after_id, limit=500)
        if payload is None:
            return
        if not payload:
            if not self._detect_and_reset_cursor_if_server_restarted(after_id):
                return
            payload = self._request_notifications(after_id=self._get_last_notification_id(), limit=500)
            if payload is None or not payload:
                return

        latest = payload[-1]
        latest_id = int(latest.get("id", 0))
        latest_created_at = self._parse_event_datetime(latest.get("created_at"))
        latest_notification_id = latest_id if latest_id > 0 else None
        repeat_interval_minutes = _normalize_repeat_interval_minutes(
            latest.get("repeat_interval_minutes", self._notification_repeat_interval_minutes),
            self._notification_repeat_interval_minutes,
        )
        if not self._is_new_notification(latest_notification_id, latest_created_at):
            return

        message = str(latest.get("message", DEFAULT_NOTIFICATION_TEXT))
        missed_count = len(payload)
        if missed_count > 1:
            message = (
                f"{message} "
                f"(\u041f\u0440\u043e\u043f\u0443\u0449\u0435\u043d\u043e \u043e\u0431\u043d\u043e\u0432\u043b\u0435\u043d\u0438\u0439: {missed_count})"
            )

        self._enqueue_notification(
            message,
            latest_notification_id,
            notification_created_at=latest_created_at,
            is_special_alert=_is_special_alert_message(message),
            special_employee_names=[],
            repeat_interval_minutes=repeat_interval_minutes,
        )

    def _fetch_missed_notifications_async(self) -> None:
        thread = threading.Thread(target=self._fetch_missed_notifications, daemon=True)
        thread.start()

    def _start_periodic_polling(self) -> None:
        def run_polling() -> None:
            next_config_sync_at = 0.0
            while True:
                now_ts = time.time()
                if now_ts >= next_config_sync_at:
                    self._refresh_notification_config()
                    next_config_sync_at = now_ts + 300
                now_mono = time.monotonic()
                if self._last_heartbeat_monotonic <= 0 or (now_mono - self._last_heartbeat_monotonic) >= HEARTBEAT_INTERVAL_SECONDS:
                    self._trigger_heartbeat(reason="periodic")
                self._check_for_updates()
                # WebSocket is the primary channel. Polling is fallback for connection loss/offline gaps.
                if not self._ws_connected:
                    self._fetch_missed_notifications()
                threading.Event().wait(POLL_INTERVAL_SECONDS)

        thread = threading.Thread(target=run_polling, daemon=True)
        thread.start()

    def _start_ws_listener(self) -> None:
        def on_message(_: websocket.WebSocketApp, message: str) -> None:
            try:
                payload = json.loads(message)
            except json.JSONDecodeError:
                return

            if payload.get("type") == "registry_updated":
                notification_id = payload.get("notification_id")
                if isinstance(notification_id, str) and notification_id.isdigit():
                    notification_id = int(notification_id)
                changed_at = self._parse_event_datetime(payload.get("changed_at"))
                repeat_interval_minutes = _normalize_repeat_interval_minutes(
                    payload.get("repeat_interval_minutes", self._notification_repeat_interval_minutes),
                    self._notification_repeat_interval_minutes,
                )
                special_names = payload.get("special_employee_names")
                if not isinstance(special_names, list):
                    special_names = []
                is_special_alert = bool(payload.get("is_special_alert")) or bool(special_names)
                LOGGER.info("WS event received. notification_id=%s", notification_id)
                self._enqueue_notification(
                    str(payload.get("message", DEFAULT_NOTIFICATION_TEXT)),
                    notification_id if isinstance(notification_id, int) else None,
                    notification_created_at=changed_at,
                    is_special_alert=is_special_alert,
                    special_employee_names=[str(name) for name in special_names if str(name).strip()],
                    repeat_interval_minutes=repeat_interval_minutes,
                )

        def on_open(_: websocket.WebSocketApp) -> None:
            self._ws_connected = True
            LOGGER.info("WebSocket connected")
            self._refresh_notification_config()
            self._trigger_heartbeat(reason="ws_connected")
            self._check_for_updates()
            self._fetch_missed_notifications_async()

        def on_error(_: websocket.WebSocketApp, _error: Exception) -> None:
            self._ws_connected = False
            LOGGER.warning("WebSocket error: %s", _error)

        def on_close(_: websocket.WebSocketApp, _code: int, _reason: str) -> None:
            self._ws_connected = False
            LOGGER.warning("WebSocket closed. code=%s reason=%s", _code, _reason)

        self.ws_app = websocket.WebSocketApp(
            SERVER_WS_URL,
            on_open=on_open,
            on_message=on_message,
            on_error=on_error,
            on_close=on_close,
        )

        def run_forever() -> None:
            while True:
                try:
                    self.ws_app.run_forever(ping_interval=20, ping_timeout=10)
                except Exception:
                    LOGGER.exception("WebSocket run_forever crashed")
                time.sleep(3)

        thread = threading.Thread(target=run_forever, daemon=True)
        thread.start()

    def _remove_toast(self, toast: tk.Toplevel) -> None:
        if toast in self._toasts:
            self._toasts.remove(toast)
        try:
            toast.destroy()
        except Exception:
            pass
        self._reposition_toasts()

    def _reposition_toasts(self) -> None:
        self.root.update_idletasks()
        screen_w = self.root.winfo_screenwidth()
        x = max(TOAST_MARGIN, screen_w - TOAST_WIDTH - TOAST_MARGIN)

        for index, toast in enumerate(self._toasts):
            y = TOAST_MARGIN + index * (TOAST_HEIGHT + TOAST_MARGIN)
            toast.geometry(f"{TOAST_WIDTH}x{TOAST_HEIGHT}+{x}+{y}")

    def _show_toast(self, message: str, *, is_special_alert: bool = False, special_employee_names: list[str] | None = None) -> None:
        special_names = special_employee_names or []
        special_mode = bool(is_special_alert or special_names or _is_special_alert_message(message))

        accent_color = TOAST_SPECIAL_ACCENT if special_mode else TOAST_ACCENT
        primary_btn_bg = TOAST_SPECIAL_BTN_BG if special_mode else TOAST_BTN_PRIMARY_BG
        icon_bg = TOAST_SPECIAL_ICON_BG if special_mode else TOAST_ICON_BG
        icon_fg = TOAST_SPECIAL_ICON_FG if special_mode else TOAST_ICON_FG
        subtitle_text = SUBTITLE_TEXT
        if special_mode:
            if special_names:
                subtitle_text = f"{SPECIAL_SUBTITLE_TEXT}: {', '.join(special_names[:3])}"
            else:
                subtitle_text = SPECIAL_SUBTITLE_TEXT
        stamp_text = datetime.now().strftime("%H:%M")

        toast = tk.Toplevel(self.root)
        try:
            toast.overrideredirect(True)
        except Exception:
            pass
        try:
            toast.attributes("-topmost", True)
        except Exception:
            pass
        if os.name == "nt":
            try:
                toast.attributes("-toolwindow", True)
            except Exception:
                pass

        toast.resizable(False, False)
        toast.geometry(f"{TOAST_WIDTH}x{TOAST_HEIGHT}+0+0")

        outer = tk.Frame(toast, bg=TOAST_BORDER, bd=0, highlightthickness=0)
        outer.pack(fill="both", expand=True)

        content = tk.Frame(outer, bg=TOAST_BG, padx=10, pady=9)
        content.pack(fill="both", expand=True, padx=1, pady=1)

        accent = tk.Frame(content, bg=accent_color, width=6)
        accent.pack(side="left", fill="y")

        panel = tk.Frame(content, bg=TOAST_BG)
        panel.pack(side="left", fill="both", expand=True, padx=(11, 0))

        header = tk.Frame(panel, bg=TOAST_BG)
        header.pack(fill="x")

        icon = tk.Label(
            header,
            text="MED",
            bg=icon_bg,
            fg=icon_fg,
            font=("Segoe UI", 8, "bold"),
            width=4,
            padx=3,
            pady=2,
        )
        icon.pack(side="left", padx=(0, 8))

        heading = tk.Frame(header, bg=TOAST_BG)
        heading.pack(side="left", fill="x", expand=True)

        title = tk.Label(
            heading,
            text=TITLE_TEXT,
            bg=TOAST_BG,
            fg=TOAST_TITLE,
            font=("Segoe UI", 10, "bold"),
            anchor="w",
        )
        title.pack(fill="x")

        subtitle = tk.Label(
            heading,
            text=subtitle_text,
            bg=TOAST_BG,
            fg=TOAST_SUBTEXT,
            font=("Segoe UI", 8),
            anchor="w",
        )
        subtitle.pack(fill="x", pady=(1, 0))

        stamp = tk.Label(
            header,
            text=stamp_text,
            bg=TOAST_BG,
            fg=TOAST_SUBTEXT,
            font=("Segoe UI", 8, "bold"),
            anchor="e",
        )
        stamp.pack(side="right")

        body_card = tk.Frame(
            panel,
            bg=TOAST_BODY_BG,
            bd=0,
            highlightthickness=1,
            highlightbackground=TOAST_BODY_BORDER,
        )
        body_card.pack(fill="both", expand=True, pady=(7, 8))

        body = tk.Label(
            body_card,
            text=message,
            bg=TOAST_BODY_BG,
            fg=TOAST_TEXT,
            font=("Segoe UI", 9),
            anchor="w",
            justify="left",
            wraplength=TOAST_WIDTH - 92,
            padx=9,
            pady=7,
        )
        body.pack(fill="both", expand=True)

        buttons = tk.Frame(panel, bg=TOAST_BG)
        buttons.pack(fill="x")

        open_btn = tk.Button(
            buttons,
            text="\u041e\u0442\u043a\u0440\u044b\u0442\u044c \u0442\u0430\u0431\u043b\u0438\u0446\u0443",
            bg=primary_btn_bg,
            fg=TOAST_BTN_PRIMARY_FG,
            activebackground=primary_btn_bg,
            activeforeground=TOAST_BTN_PRIMARY_FG,
            relief="flat",
            bd=0,
            highlightthickness=0,
            cursor="hand2",
            padx=11,
            pady=4,
            command=self._open_registry,
        )
        open_btn.pack(side="left")

        close_btn = tk.Button(
            buttons,
            text="\u0417\u0430\u043a\u0440\u044b\u0442\u044c",
            bg=TOAST_BTN_SECONDARY_BG,
            fg=TOAST_BTN_SECONDARY_FG,
            activebackground=TOAST_BTN_SECONDARY_BG,
            activeforeground=TOAST_BTN_SECONDARY_FG,
            relief="flat",
            bd=0,
            highlightthickness=0,
            cursor="hand2",
            padx=11,
            pady=4,
            command=lambda: self._remove_toast(toast),
        )
        close_btn.pack(side="left", padx=(8, 0))

        # Click on toast body opens active list.
        for widget in (content, accent, panel, header, heading, title, subtitle, body_card, body):
            widget.bind("<Button-1>", lambda _event: self._open_registry())

        self._toasts.insert(0, toast)
        self._reposition_toasts()
        toast.after(TOAST_AUTO_CLOSE_MS, lambda: self._remove_toast(toast))

    def _show_system_notification(
        self, message: str, *, is_special_alert: bool = False, special_employee_names: list[str] | None = None
    ) -> None:
        notify_send = shutil.which("notify-send")
        if not notify_send:
            LOGGER.warning("notify-send is not available. Notification text: %s", message)
            return

        subtitle = SUBTITLE_TEXT
        special_names = special_employee_names or []
        if is_special_alert or special_names:
            subtitle = SPECIAL_SUBTITLE_TEXT
            if special_names:
                subtitle = f"{subtitle}: {', '.join(special_names[:3])}"

        text_lines = [message, f"{SERVER_HTTP_URL}/public"]
        if subtitle.strip():
            text_lines.insert(0, subtitle)
        text = "\n".join(text_lines)
        args = [
            notify_send,
            TITLE_TEXT,
            text,
            "-a",
            "Vacation Notifier",
            "-t",
            str(TOAST_AUTO_CLOSE_MS),
            "-u",
            "normal",
        ]
        try:
            subprocess.run(args, check=False)
        except Exception as exc:
            LOGGER.warning("notify-send failed: %s", exc)

    def _mark_event_processed(self, item: dict) -> None:
        notification_id = item.get("notification_id")
        notification_created_at = item.get("notification_created_at")
        if isinstance(notification_created_at, str):
            notification_created_at = self._parse_event_datetime(notification_created_at)
        event_key = item.get("event_key")

        if isinstance(notification_id, int) or isinstance(notification_created_at, datetime):
            self._mark_notification_seen(
                notification_id if isinstance(notification_id, int) else None,
                notification_created_at if isinstance(notification_created_at, datetime) else None,
            )
            self._last_heartbeat_monotonic = 0.0
        if isinstance(event_key, str):
            with self._pending_lock:
                self._pending_event_keys.discard(event_key)

    def _handle_notification_item(self, item: dict) -> None:
        kind = str(item.get("kind", "notification"))
        message = str(item.get("text", ""))
        is_special_alert = bool(item.get("is_special_alert"))
        special_names = item.get("special_employee_names")
        if not isinstance(special_names, list):
            special_names = []
        normalized_names = [str(name) for name in special_names if str(name).strip()]

        if kind == "notification":
            # Mark as processed first, so transient UI/display issues do not cause endless repeats.
            self._mark_event_processed(item)
            repeat_interval_minutes = _normalize_repeat_interval_minutes(
                item.get("repeat_interval_minutes", self._notification_repeat_interval_minutes),
                self._notification_repeat_interval_minutes,
            )
            self._update_repeat_source(
                message=message,
                is_special_alert=is_special_alert,
                special_employee_names=normalized_names,
                repeat_interval_minutes=repeat_interval_minutes,
            )

        if self._gui_enabled:
            self._show_toast(message, is_special_alert=is_special_alert, special_employee_names=normalized_names)
        else:
            self._show_system_notification(message, is_special_alert=is_special_alert, special_employee_names=normalized_names)

    def _headless_drain_loop(self) -> None:
        while True:
            item = self.messages.get()
            kind = item.get("kind")
            if kind in {"notification", "reminder", "startup"}:
                self._handle_notification_item(item)

    def _drain_queue(self) -> None:
        while not self.messages.empty():
            item = self.messages.get_nowait()
            kind = item.get("kind")

            if kind in {"notification", "reminder", "startup"}:
                self._handle_notification_item(item)

        if self.root is not None:
            self.root.after(500, self._drain_queue)

    def _open_registry(self) -> None:
        webbrowser.open(f"{SERVER_HTTP_URL}/public")

    def run(self) -> None:
        if self._gui_enabled and self.root is not None:
            self.root.mainloop()
            return
        while True:
            time.sleep(3600)


if __name__ == "__main__":
    try:
        if not _acquire_single_instance_lock():
            LOGGER.warning("Another notifier instance is already running. Exit.")
            raise SystemExit(0)
        NotifierApp().run()
    except Exception:
        LOGGER.exception("Notifier crashed")
        raise
