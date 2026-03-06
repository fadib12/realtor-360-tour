"""
Capture CRUD + processing endpoints.

POST /v1/captures              → create capture, return presigned upload URLs
POST /v1/captures/{id}/process → enqueue stitching + World Labs worker
GET  /v1/captures/{id}/status  → poll current status
"""

import asyncio
from typing import Literal
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..database import get_db
from ..models import Capture
from ..services.storage import generate_presigned_url
from ..services.queue import enqueue_processing

router = APIRouter(tags=["captures"])


# ── Request / Response schemas ──────────────────────────────────

class CreateCaptureRequest(BaseModel):
    name: str
    captureType: Literal["multiPhoto16", "panorama360"]
    photoCount: int = 16


class CreateCaptureResponse(BaseModel):
    id: str
    uploadUrls: list[str] | None = None
    panoramaUploadUrl: str | None = None
    pollUrl: str


class ProcessResponse(BaseModel):
    status: str


# ── Endpoints ────────────────────────────────────────────────────

@router.post("/captures", response_model=CreateCaptureResponse)
async def create_capture(
    req: CreateCaptureRequest,
    db: AsyncSession = Depends(get_db),
):
    """Create a new capture record and return presigned S3 upload URLs."""
    capture_id = str(uuid4())

    # Generate S3 keys + presigned upload URLs (run in thread to avoid blocking)
    if req.captureType == "multiPhoto16":
        keys = [f"captures/{capture_id}/{str(i).zfill(3)}.jpg" for i in range(req.photoCount)]
        upload_urls = list(await asyncio.gather(
            *[asyncio.to_thread(generate_presigned_url, key) for key in keys]
        ))
        panorama_url = None
    else:
        # panorama360 — single file upload
        keys = [f"captures/{capture_id}/panorama.jpg"]
        upload_urls = None
        panorama_url = await asyncio.to_thread(generate_presigned_url, keys[0])

    capture = Capture(
        id=capture_id,
        name=req.name,
        capture_type=req.captureType,
        photo_count=req.photoCount,
        status="pending",
        photo_keys=keys,
    )
    db.add(capture)
    await db.flush()

    return CreateCaptureResponse(
        id=capture_id,
        uploadUrls=upload_urls,
        panoramaUploadUrl=panorama_url,
        pollUrl=f"/v1/captures/{capture_id}/status",
    )


@router.post("/captures/{capture_id}/process", response_model=ProcessResponse)
async def start_processing(
    capture_id: str,
    db: AsyncSession = Depends(get_db),
):
    """Mark capture as processing and enqueue the Celery worker."""
    result = await db.execute(select(Capture).where(Capture.id == capture_id))
    capture = result.scalar_one_or_none()
    if not capture:
        raise HTTPException(status_code=404, detail="Capture not found")

    capture.status = "stitching"
    capture.progress = 0.0
    await db.flush()

    # Fire-and-forget Celery task
    enqueue_processing(capture_id)

    return ProcessResponse(status="processing")


@router.get("/captures/{capture_id}/status")
async def get_status(
    capture_id: str,
    db: AsyncSession = Depends(get_db),
):
    """Poll the current status of a capture."""
    result = await db.execute(select(Capture).where(Capture.id == capture_id))
    capture = result.scalar_one_or_none()
    if not capture:
        raise HTTPException(status_code=404, detail="Capture not found")

    return capture.to_status_dict()
