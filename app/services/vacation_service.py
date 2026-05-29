from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..models import VacationRecord, VacationStatus


@dataclass
class RegistryMaintenanceResult:
    activated_ids: list[int]
    finalized_ids: list[int]
    deleted_ids: list[int]

    @property
    def changed_ids(self) -> list[int]:
        return sorted(set(self.activated_ids + self.finalized_ids))


def run_registry_maintenance(
    db: Session,
    today: date,
    *,
    retention_days: int = 365,
    include_activations: bool = True,
) -> RegistryMaintenanceResult:
    active_statuses = (
        VacationStatus.IN_VACATION,
        VacationStatus.SICK_LEAVE,
        VacationStatus.IN_VACATION.value,
        VacationStatus.SICK_LEAVE.value,
        VacationStatus.IN_VACATION.name,
        VacationStatus.SICK_LEAVE.name,
    )

    activated_ids: list[int] = []
    if include_activations:
        # Vacation starts today become visible for clients from 00:00.
        activated_ids = db.scalars(
            select(VacationRecord.id).where(
                VacationRecord.status.in_(active_statuses),
                VacationRecord.start_date == today,
                VacationRecord.end_date >= today,
            )
        ).all()

    stmt = select(VacationRecord).where(
        VacationRecord.status.in_(active_statuses),
        VacationRecord.end_date < today,
    )
    expired = db.scalars(stmt).all()

    finalized_ids: list[int] = []
    for record in expired:
        record.status = VacationStatus.FINISHED
        record.deactivated_at = datetime.now(timezone.utc)
        finalized_ids.append(record.id)

    cutoff = today - timedelta(days=max(1, retention_days))
    old_records = db.scalars(select(VacationRecord).where(VacationRecord.end_date < cutoff)).all()
    deleted_ids: list[int] = []
    for record in old_records:
        deleted_ids.append(record.id)
        db.delete(record)

    if expired or old_records:
        db.commit()

    return RegistryMaintenanceResult(
        activated_ids=activated_ids,
        finalized_ids=finalized_ids,
        deleted_ids=deleted_ids,
    )
