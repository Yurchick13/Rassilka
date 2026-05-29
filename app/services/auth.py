from __future__ import annotations

import hashlib
import hmac
import os
from typing import Final

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..models import UserAccount, UserRole

PBKDF2_ALG: Final[str] = "sha256"
PBKDF2_ITERATIONS: Final[int] = 390_000


def normalize_username(value: str) -> str:
    return value.strip().lower()


def hash_password(password: str) -> str:
    salt = os.urandom(16)
    derived = hashlib.pbkdf2_hmac(
        PBKDF2_ALG,
        password.encode("utf-8"),
        salt,
        PBKDF2_ITERATIONS,
    )
    return f"pbkdf2_{PBKDF2_ALG}${PBKDF2_ITERATIONS}${salt.hex()}${derived.hex()}"


def verify_password(password: str, password_hash: str) -> bool:
    try:
        algo_part, iter_part, salt_hex, hash_hex = password_hash.split("$", 3)
        algo = algo_part.replace("pbkdf2_", "", 1)
        iterations = int(iter_part)
        salt = bytes.fromhex(salt_hex)
        expected = bytes.fromhex(hash_hex)
    except Exception:
        return False

    candidate = hashlib.pbkdf2_hmac(
        algo,
        password.encode("utf-8"),
        salt,
        iterations,
    )
    return hmac.compare_digest(candidate, expected)


def authenticate_user(db: Session, username: str, password: str) -> UserAccount | None:
    normalized = normalize_username(username)
    stmt = select(UserAccount).where(UserAccount.username == normalized, UserAccount.is_active.is_(True))
    user = db.scalar(stmt)
    if not user:
        return None
    if not verify_password(password, user.password_hash):
        return None
    return user


def ensure_default_admin(db: Session) -> None:
    has_user = db.scalar(select(UserAccount.id).limit(1))
    if has_user:
        return

    login = normalize_username(os.getenv("DEFAULT_ADMIN_LOGIN", "admin"))
    password = os.getenv("DEFAULT_ADMIN_PASSWORD", "admin12345")
    if len(password) < 8:
        password = "admin12345"

    admin = UserAccount(
        username=login,
        password_hash=hash_password(password),
        role=UserRole.ADMIN,
        is_active=True,
    )
    db.add(admin)
    db.commit()
