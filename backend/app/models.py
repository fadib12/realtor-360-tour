from sqlalchemy import Column, String, DateTime, Enum, Text, ForeignKey, JSON
from sqlalchemy.orm import relationship
from sqlalchemy.sql import func
from datetime import datetime
import enum
import uuid

from app.database import Base


class TourStatus(str, enum.Enum):
    WAITING = "WAITING"          # Waiting for capture
    UPLOADING = "UPLOADING"      # Photos being uploaded
    PROCESSING = "PROCESSING"    # Stitching in progress
    READY = "READY"              # Pano ready for viewing
    FAILED = "FAILED"            # Stitching failed


def generate_uuid():
    return str(uuid.uuid4())


def generate_slug():
    return uuid.uuid4().hex[:8]


class User(Base):
    __tablename__ = "users"
    
    id = Column(String(36), primary_key=True, default=generate_uuid)
    email = Column(String(255), unique=True, nullable=False, index=True)
    hashed_password = Column(String(255), nullable=False)
    name = Column(String(255), nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), onupdate=func.now())
    
    tours = relationship("Tour", back_populates="user")


class Tour(Base):
    __tablename__ = "tours"
    
    id = Column(String(36), primary_key=True, default=generate_uuid)
    user_id = Column(String(36), ForeignKey("users.id"), nullable=False)
    
    # Tour info
    name = Column(String(255), nullable=False)
    address = Column(String(500), nullable=True)
    notes = Column(Text, nullable=True)
    
    # Status
    status = Column(Enum(TourStatus), default=TourStatus.WAITING, nullable=False)
    
    # Public access
    public_slug = Column(String(16), unique=True, default=generate_slug, index=True)
    
    # Stitching result
    pano_url = Column(String(1000), nullable=True)
    pano_key = Column(String(500), nullable=True)
    
    # Frame metadata (stored after upload)
    frames_meta = Column(JSON, nullable=True)
    
    # Error info (if failed)
    error_message = Column(Text, nullable=True)
    
    # Timestamps
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), onupdate=func.now())
    completed_at = Column(DateTime(timezone=True), nullable=True)
    
    user = relationship("User", back_populates="tours")
    frames = relationship("TourFrame", back_populates="tour", cascade="all, delete-orphan")


class TourFrame(Base):
    __tablename__ = "tour_frames"
    
    id = Column(String(36), primary_key=True, default=generate_uuid)
    tour_id = Column(String(36), ForeignKey("tours.id"), nullable=False)
    
    # Frame info
    frame_index = Column(String(10), nullable=False)  # 0-15
    frame_key = Column(String(500), nullable=False)   # S3 key
    
    # Capture metadata
    yaw = Column(String(20), nullable=True)
    pitch = Column(String(20), nullable=True)
    
    # Upload status
    uploaded = Column(String(10), default="false")
    
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    
    tour = relationship("Tour", back_populates="frames")
