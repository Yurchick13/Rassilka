from __future__ import annotations

from datetime import date, datetime

from pydantic import BaseModel, ConfigDict, Field, field_validator

from .models import UserRole, VacationStatus


class DeputyAssignment(BaseModel):
    vacation_position: str = Field(..., min_length=1, description="Должность сотрудника в отпуске")
    deputy_full_name: str = Field(..., min_length=3, description="ФИО заместителя")
    deputy_actual_position: str = Field(..., min_length=2, description="Фактическая должность заместителя")


class VacationBase(BaseModel):
    employee_full_name: str = Field(..., min_length=3, description="ФИО сотрудника, который уходит в отпуск")
    is_special_employee: bool = Field(
        default=False,
        description="Особый сотрудник. Если включено, уведомление выделяется отдельно и содержит ФИО сотрудника.",
    )
    employee_positions: list[str] = Field(..., min_length=1, description="Должность или несколько должностей")
    status: VacationStatus = Field(default=VacationStatus.IN_VACATION)
    service: str = Field(..., min_length=2, description="Услуга")
    deputies: list[DeputyAssignment] = Field(
        ..., min_length=1, description="Один или несколько заместителей с привязкой к должности"
    )
    memo: str | None = Field(
        default=None,
        description="Памятка: что не нужно делать за сотрудника в отпуске",
    )
    start_date: date
    end_date: date

    @field_validator("employee_positions")
    @classmethod
    def normalize_positions(cls, value: list[str]) -> list[str]:
        cleaned = [pos.strip() for pos in value if pos.strip()]
        if not cleaned:
            raise ValueError("Нужно указать хотя бы одну должность.")
        return cleaned

    @field_validator("end_date")
    @classmethod
    def validate_dates(cls, end_date: date, info):
        start_date = info.data.get("start_date")
        if start_date and end_date < start_date:
            raise ValueError("Дата окончания отпуска не может быть раньше даты начала.")
        return end_date


class VacationCreate(VacationBase):
    pass


class VacationUpdate(VacationBase):
    pass


class VacationResponse(VacationBase):
    id: int
    deactivated_at: datetime | None = None
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)


class NotificationEventResponse(BaseModel):
    id: int
    type: str
    message: str
    changed_ids: list[int] = Field(default_factory=list)
    created_at: datetime
    repeat_interval_minutes: int = 0


class BroadcastMessage(BaseModel):
    type: str = "registry_updated"
    message: str
    changed_ids: list[int] = Field(default_factory=list)
    changed_at: datetime
    repeat_interval_minutes: int = 0


class NotificationConfigResponse(BaseModel):
    repeat_interval_minutes: int = Field(
        default=0,
        description="Интервал повтора уведомления в минутах. 0 - без повтора.",
    )


class ClientHeartbeatUpsert(BaseModel):
    client_id: str = Field(..., min_length=8, max_length=128)
    app_version: str = Field(default="unknown", min_length=1, max_length=64)
    app_channel: str = Field(default="stable", min_length=1, max_length=32)
    hostname: str | None = Field(default=None, max_length=255)
    username: str | None = Field(default=None, max_length=128)
    os_name: str | None = Field(default=None, max_length=64)
    os_version: str | None = Field(default=None, max_length=128)
    mac_address: str | None = Field(default=None, max_length=32)
    ip_address: str | None = Field(default=None, max_length=64)
    mode: str | None = Field(default=None, max_length=32)
    last_notification_id: int | None = Field(default=None, ge=0)
    update_supported: bool = False
    update_status: str | None = Field(default=None, max_length=64)
    update_error: str | None = Field(default=None, max_length=2048)

    @field_validator(
        "client_id",
        "app_version",
        "app_channel",
        "hostname",
        "username",
        "os_name",
        "os_version",
        "mac_address",
        "ip_address",
        "mode",
        "update_status",
        "update_error",
        mode="before",
    )
    @classmethod
    def strip_text_values(cls, value):
        if value is None:
            return None
        return str(value).strip()


class ClientHeartbeatResponse(BaseModel):
    status: str = "ok"
    client_id: str
    server_time: datetime


class ClientHeartbeatMonitorResponse(BaseModel):
    client_id: str
    hostname: str | None = None
    username: str | None = None
    os_name: str | None = None
    os_version: str | None = None
    mac_address: str | None = None
    app_version: str | None = None
    app_channel: str | None = None
    ip_address: str | None = None
    mode: str | None = None
    last_notification_id: int | None = None
    update_supported: bool = False
    update_status: str | None = None
    update_error: str | None = None
    last_seen_at: datetime
    is_online: bool
    is_outdated: bool
    latest_version: str | None = None


class ClientUpdateConfigResponse(BaseModel):
    enabled: bool
    latest_version: str
    windows_installer_url: str | None = None
    linux_deb_url: str | None = None
    linux_rpm_url: str | None = None
    check_interval_minutes: int = Field(default=60, ge=5, le=1440)


class ClientUpdateConfigUpdate(BaseModel):
    enabled: bool = True
    latest_version: str = Field(..., min_length=1, max_length=64)
    windows_installer_url: str | None = Field(default=None, max_length=2048)
    linux_deb_url: str | None = Field(default=None, max_length=2048)
    linux_rpm_url: str | None = Field(default=None, max_length=2048)
    check_interval_minutes: int = Field(default=60, ge=5, le=1440)

    @field_validator(
        "latest_version",
        "windows_installer_url",
        "linux_deb_url",
        "linux_rpm_url",
        mode="before",
    )
    @classmethod
    def normalize_optional_text(cls, value):
        if value is None:
            return None
        cleaned = str(value).strip()
        return cleaned or None


class ClientUpdateManifestResponse(BaseModel):
    enabled: bool
    latest_version: str
    check_interval_minutes: int
    update_url: str | None = None
    windows_installer_url: str | None = None
    linux_deb_url: str | None = None
    linux_rpm_url: str | None = None
    generated_at: datetime


class UserCreate(BaseModel):
    username: str = Field(..., min_length=3, max_length=64)
    password: str = Field(..., min_length=8, max_length=128)
    role: UserRole = Field(default=UserRole.CLIENT)

    @field_validator("username")
    @classmethod
    def normalize_username(cls, value: str) -> str:
        cleaned = value.strip().lower()
        if not cleaned:
            raise ValueError("Логин не может быть пустым.")
        return cleaned

    @field_validator("role", mode="before")
    @classmethod
    def normalize_role(cls, value):
        if isinstance(value, str) and value.strip().lower() == UserRole.VIEWER.value:
            return UserRole.CLIENT
        if isinstance(value, UserRole) and value == UserRole.VIEWER:
            return UserRole.CLIENT
        return value


class UserResponse(BaseModel):
    id: int
    username: str
    role: UserRole
    is_active: bool
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


FIELD_HELP: dict[str, str] = {
    "employee_full_name": "ФИО сотрудника, который уходит в отпуск. Указывайте полностью, как в кадровых документах.",
    "is_special_employee": "Особый сотрудник. Для таких сотрудников уведомление выделяется отдельно и содержит ФИО.",
    "employee_positions": "Должность/должности сотрудника. Если должностей несколько, добавьте каждую отдельной строкой.",
    "status": "Текущий статус. Для активной записи используйте 'В отпуске' или 'Больничный лист'. По завершении система переведет в 'Завершен'.",
    "service": "Услуга или направление работ, за которое отвечает сотрудник.",
    "deputies": "Заместитель/и (ФИО). Для каждой должности можно назначить отдельного заместителя.",
    "deputy_actual_position": "Фактическая должность сотрудника, который замещает.",
    "start_date": "Дата начала отпуска (включительно).",
    "end_date": "Дата окончания отпуска (включительно). В 00:00 следующего дня запись автоматически снимается с активного реестра.",
    "memo": "Памятка для коллег: что не нужно делать за сотрудника в период отпуска и важные комментарии.",
}
