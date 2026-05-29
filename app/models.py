from __future__ import annotations

import enum
from datetime import date, datetime

from sqlalchemy import Boolean, Date, DateTime, Enum, Integer, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column
from sqlalchemy.types import JSON

from .database import Base


class VacationStatus(str, enum.Enum):
    IN_VACATION = "В отпуске"
    SICK_LEAVE = "Больничный лист"
    FINISHED = "Завершен"


class VacationRecord(Base):
    __tablename__ = "vacation_records"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, index=True)
    employee_full_name: Mapped[str] = mapped_column(String(255), nullable=False, index=True)
    is_special_employee: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False, server_default="0", index=True)
    employee_positions: Mapped[list[str]] = mapped_column(JSON, nullable=False)
    status: Mapped[VacationStatus] = mapped_column(
        Enum(VacationStatus, name="vacation_status"),
        default=VacationStatus.IN_VACATION,
        nullable=False,
        index=True,
    )
    service: Mapped[str] = mapped_column(String(255), nullable=False)
    deputies: Mapped[list[dict]] = mapped_column(JSON, nullable=False)
    memo: Mapped[str | None] = mapped_column(Text, nullable=True)
    start_date: Mapped[date] = mapped_column(Date, nullable=False)
    end_date: Mapped[date] = mapped_column(Date, nullable=False, index=True)
    deactivated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=func.now(),
    )


class NotificationEvent(Base):
    __tablename__ = "notification_events"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, index=True)
    event_type: Mapped[str] = mapped_column(String(64), nullable=False, default="registry_updated", index=True)
    message: Mapped[str] = mapped_column(Text, nullable=False)
    changed_ids: Mapped[list[int]] = mapped_column(JSON, nullable=False, default=list)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        index=True,
    )


class RegistrySyncLog(Base):
    __tablename__ = "registry_sync_logs"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, index=True)
    action_type: Mapped[str] = mapped_column(String(64), nullable=False, index=True)
    source_name: Mapped[str | None] = mapped_column(String(255), nullable=True)
    actor_username: Mapped[str | None] = mapped_column(String(64), nullable=True, index=True)
    payload: Mapped[dict] = mapped_column(JSON, nullable=False, default=dict)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        index=True,
    )


class NotificationConfig(Base):
    __tablename__ = "notification_config"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, default=1)
    repeat_interval_minutes: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        default=0,
        server_default="0",
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=func.now(),
    )


class ClientUpdateConfig(Base):
    __tablename__ = "client_update_config"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, default=1)
    enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True, server_default="1")
    latest_version: Mapped[str] = mapped_column(String(64), nullable=False, default="1.1.0", server_default="1.1.0")
    windows_installer_url: Mapped[str | None] = mapped_column(Text, nullable=True)
    linux_deb_url: Mapped[str | None] = mapped_column(Text, nullable=True)
    linux_rpm_url: Mapped[str | None] = mapped_column(Text, nullable=True)
    check_interval_minutes: Mapped[int] = mapped_column(Integer, nullable=False, default=60, server_default="60")
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=func.now(),
    )


class ClientHeartbeat(Base):
    __tablename__ = "client_heartbeats"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, index=True)
    client_id: Mapped[str] = mapped_column(String(128), nullable=False, unique=True, index=True)
    hostname: Mapped[str | None] = mapped_column(String(255), nullable=True, index=True)
    username: Mapped[str | None] = mapped_column(String(128), nullable=True)
    os_name: Mapped[str | None] = mapped_column(String(64), nullable=True)
    os_version: Mapped[str | None] = mapped_column(String(128), nullable=True)
    app_version: Mapped[str | None] = mapped_column(String(64), nullable=True, index=True)
    app_channel: Mapped[str | None] = mapped_column(String(32), nullable=True)
    ip_address: Mapped[str | None] = mapped_column(String(64), nullable=True)
    mode: Mapped[str | None] = mapped_column(String(32), nullable=True)
    last_notification_id: Mapped[int | None] = mapped_column(Integer, nullable=True)
    update_supported: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False, server_default="0")
    update_status: Mapped[str | None] = mapped_column(String(64), nullable=True)
    update_error: Mapped[str | None] = mapped_column(Text, nullable=True)
    last_seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now(), index=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=func.now(),
    )


class UserRole(str, enum.Enum):
    ADMIN = "admin"
    EDITOR = "editor"
    CLIENT = "client"
    # Legacy role for compatibility with existing databases.
    VIEWER = "viewer"


class UserAccount(Base):
    __tablename__ = "user_accounts"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, index=True)
    username: Mapped[str] = mapped_column(String(64), nullable=False, unique=True, index=True)
    password_hash: Mapped[str] = mapped_column(String(255), nullable=False)
    role: Mapped[UserRole] = mapped_column(
        Enum(UserRole, name="user_role"),
        nullable=False,
        default=UserRole.CLIENT,
        index=True,
    )
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True, server_default="1")
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )
