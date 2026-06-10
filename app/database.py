from __future__ import annotations

import os
from sqlalchemy import create_engine
from sqlalchemy.orm import declarative_base, sessionmaker

DATABASE_URL = os.getenv("DATABASE_URL", "sqlite:///./vacations.db")

connect_args = {}
engine_kwargs = {"future": True, "pool_pre_ping": True}
if DATABASE_URL.startswith("sqlite"):
    connect_args = {"check_same_thread": False}
else:
    engine_kwargs.update(
        {
            "pool_size": int(os.getenv("DB_POOL_SIZE", "30")),
            "max_overflow": int(os.getenv("DB_MAX_OVERFLOW", "60")),
            "pool_timeout": int(os.getenv("DB_POOL_TIMEOUT", "5")),
        }
    )

engine = create_engine(DATABASE_URL, connect_args=connect_args, **engine_kwargs)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine, future=True)
Base = declarative_base()


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
