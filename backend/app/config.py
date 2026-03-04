from pydantic_settings import BaseSettings
from functools import lru_cache
from typing import Optional


class Settings(BaseSettings):
    # Database
    database_url: str = "postgresql://postgres:password@localhost:5432/realtor360"
    
    # Redis
    redis_url: str = "redis://localhost:6379/0"
    
    # AWS S3 / R2
    s3_bucket: str = "realtor360-tours"
    s3_region: str = "us-east-1"
    s3_endpoint_url: Optional[str] = None
    aws_access_key_id: str = ""
    aws_secret_access_key: str = ""
    
    # JWT
    jwt_secret: str = "change-this-to-a-secure-random-string"
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = 10080  # 7 days
    
    # App URLs
    web_base_url: str = "http://localhost:3000"
    api_base_url: str = "http://localhost:8000"
    ios_app_scheme: str = "realtor360"
    universal_links_domain: str = "realtor360.app"
    
    class Config:
        env_file = ".env"
        case_sensitive = False


@lru_cache()
def get_settings() -> Settings:
    return Settings()
