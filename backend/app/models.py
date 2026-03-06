"""
SQLAlchemy models for the Realtor 360 backend.
"""

from datetime import datetime
from uuid import uuid4

from sqlalchemy import Column, DateTime, Float, Integer, JSON, String, func

from .database import Base


class Capture(Base):
    __tablename__ = "captures"

    id = Column(String, primary_key=True, default=lambda: str(uuid4()))
    name = Column(String, nullable=False)
    capture_type = Column(String, nullable=False)  # "multiPhoto16" | "panorama360"
    photo_count = Column(Integer, default=0)
    status = Column(String, default="pending")
    # status flow: pending → uploading → stitching → generating_world → complete | failed
    progress = Column(Float, default=0.0)
    error_message = Column(String, nullable=True)

    # S3 object keys
    photo_keys = Column(JSON, default=list)     # ["captures/{id}/001.jpg", ...]
    panorama_key = Column(String, nullable=True)  # "captures/{id}/panorama.jpg"
    preview_key = Column(String, nullable=True)   # "captures/{id}/preview.jpg"

    # Public URLs (set after stitching / World Labs)
    panorama_url = Column(String, nullable=True)
    preview_url = Column(String, nullable=True)

    # World Labs fields
    world_operation_id = Column(String, nullable=True)
    world_id = Column(String, nullable=True)
    world_url = Column(String, nullable=True)
    thumbnail_url = Column(String, nullable=True)
    splats_100k_url = Column(String, nullable=True)
    splats_500k_url = Column(String, nullable=True)
    splats_full_url = Column(String, nullable=True)
    collider_mesh_url = Column(String, nullable=True)

    # Timestamps
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    completed_at = Column(DateTime(timezone=True), nullable=True)

    def to_status_dict(self) -> dict:
        """Return the status response dict for the iOS client."""
        result: dict = {
            "status": self.status,
            "progress": self.progress,
            "errorMessage": self.error_message,
            "previewUrl": self.preview_url,
            "panoramaUrl": self.panorama_url,
            "worldUrl": self.world_url,
            "thumbnailUrl": self.thumbnail_url,
            "colliderMeshUrl": self.collider_mesh_url,
            "generatedAt": self.completed_at.isoformat() if self.completed_at else None,
        }
        # Only include splats if at least one URL exists
        if any([self.splats_100k_url, self.splats_500k_url, self.splats_full_url]):
            result["splats"] = {
                "100k": self.splats_100k_url,
                "500k": self.splats_500k_url,
                "full_res": self.splats_full_url,
            }
        else:
            result["splats"] = None
        return result
