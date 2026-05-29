from __future__ import annotations

from datetime import datetime, timezone
from threading import Lock

from fastapi import WebSocket

REGISTRY_UPDATE_TEXT = "Внимание! Обновление реестра отпусков! Необходимо ознакомиться с информацией!"


class WebSocketHub:
    def __init__(self) -> None:
        self._connections: set[WebSocket] = set()
        self._lock = Lock()

    async def connect(self, websocket: WebSocket) -> None:
        await websocket.accept()
        with self._lock:
            self._connections.add(websocket)

    def disconnect(self, websocket: WebSocket) -> None:
        with self._lock:
            self._connections.discard(websocket)

    async def broadcast(self, payload: dict) -> None:
        with self._lock:
            sockets = list(self._connections)

        stale: list[WebSocket] = []
        for socket in sockets:
            try:
                await socket.send_json(payload)
            except Exception:
                stale.append(socket)

        if stale:
            with self._lock:
                for socket in stale:
                    self._connections.discard(socket)


def _format_iso_utc(value: datetime) -> str:
    dt = value
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def build_registry_update_message(
    changed_ids: list[int],
    *,
    notification_id: int | None = None,
    changed_at: datetime | None = None,
    message: str = REGISTRY_UPDATE_TEXT,
    special_employee_names: list[str] | None = None,
    repeat_interval_minutes: int = 0,
) -> dict:
    at = changed_at or datetime.now(timezone.utc)
    special_names = special_employee_names or []
    return {
        "type": "registry_updated",
        "notification_id": notification_id,
        "message": message,
        "changed_ids": changed_ids,
        "is_special_alert": bool(special_names),
        "special_employee_names": special_names,
        "changed_at": _format_iso_utc(at),
        "repeat_interval_minutes": max(0, int(repeat_interval_minutes)),
    }
