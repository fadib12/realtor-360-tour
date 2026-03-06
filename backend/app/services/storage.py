"""
S3 / MinIO storage helpers.

Provides presigned URL generation and object download/upload.
Two clients are maintained:
  • _internal_client — uses s3_endpoint (e.g. http://minio:9000 inside Docker)
    for internal file operations (download/upload by the worker).
  • _public_client — uses s3_public_url (e.g. http://<host-ip>:9000)
    for presigned URL generation so iOS devices can reach MinIO.
"""

import logging
from typing import BinaryIO

import boto3
from botocore.config import Config as BotoConfig

from ..config import get_settings

logger = logging.getLogger(__name__)
settings = get_settings()

_internal_client = None
_public_client = None


def _get_internal_client():
    """S3 client for internal (Docker-to-Docker) operations."""
    global _internal_client
    if _internal_client is None:
        _internal_client = boto3.client(
            "s3",
            endpoint_url=settings.s3_endpoint,
            aws_access_key_id=settings.s3_access_key,
            aws_secret_access_key=settings.s3_secret_key,
            region_name=settings.s3_region,
            config=BotoConfig(signature_version="s3v4"),
        )
        # Ensure bucket exists (MinIO)
        try:
            _internal_client.head_bucket(Bucket=settings.s3_bucket)
        except Exception:
            _internal_client.create_bucket(Bucket=settings.s3_bucket)
    return _internal_client


def _get_public_client():
    """S3 client for presigned URL generation (uses public-facing endpoint)."""
    global _public_client
    if _public_client is None:
        _public_client = boto3.client(
            "s3",
            endpoint_url=settings.s3_public_url,
            aws_access_key_id=settings.s3_access_key,
            aws_secret_access_key=settings.s3_secret_key,
            region_name=settings.s3_region,
            config=BotoConfig(signature_version="s3v4"),
        )
    return _public_client


def generate_presigned_url(key: str, expiry: int = 3600) -> str:
    """Generate a presigned PUT URL for direct upload from the iOS client.
    Uses the public-facing S3 endpoint so the URL is reachable from devices."""
    client = _get_public_client()
    url = client.generate_presigned_url(
        "put_object",
        Params={"Bucket": settings.s3_bucket, "Key": key, "ContentType": "image/jpeg"},
        ExpiresIn=expiry,
    )
    return url


def public_url_for(key: str) -> str:
    """Return a public URL for an S3 object."""
    return f"{settings.s3_public_url}/{settings.s3_bucket}/{key}"


def download_file(key: str) -> bytes:
    """Download a file from S3 and return its bytes."""
    client = _get_internal_client()
    response = client.get_object(Bucket=settings.s3_bucket, Key=key)
    return response["Body"].read()


def upload_file(key: str, data: bytes, content_type: str = "image/jpeg") -> str:
    """Upload bytes to S3, return the public URL."""
    client = _get_internal_client()
    client.put_object(
        Bucket=settings.s3_bucket,
        Key=key,
        Body=data,
        ContentType=content_type,
    )
    return public_url_for(key)


def upload_fileobj(key: str, fileobj: BinaryIO, content_type: str = "image/jpeg") -> str:
    """Upload a file-like object to S3, return the public URL."""
    client = _get_internal_client()
    client.upload_fileobj(
        fileobj,
        settings.s3_bucket,
        key,
        ExtraArgs={"ContentType": content_type},
    )
    return public_url_for(key)
