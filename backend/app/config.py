"""
Application configuration — loaded from environment variables.
"""

import os
from functools import lru_cache
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")

    # ── Database ────────────────────────────────────────────
    database_url: str = "postgresql+asyncpg://realtor:realtor@localhost:5432/realtor360"

    # ── Redis / Celery ──────────────────────────────────────
    redis_url: str = "redis://localhost:6379/0"
    celery_broker_url: str = "redis://localhost:6379/0"
    celery_result_backend: str = "redis://localhost:6379/1"

    # ── S3 / MinIO ──────────────────────────────────────────
    s3_endpoint: str = "http://localhost:9000"
    s3_bucket: str = "captures"
    s3_access_key: str = "minioadmin"
    s3_secret_key: str = "minioadmin"
    s3_region: str = "us-east-1"
    s3_public_url: str = "http://localhost:9000"  # for constructing public URLs

    # ── World Labs ──────────────────────────────────────────
    worldlabs_api_key: str = ""
    worldlabs_base_url: str = "https://api.worldlabs.ai/marble/v1"

    # ── Server ──────────────────────────────────────────────
    cors_origins: str = "*"
    debug: bool = True


@lru_cache()
def get_settings() -> Settings:
    return Settings()
