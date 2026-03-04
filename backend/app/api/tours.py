from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.responses import RedirectResponse
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from pydantic import BaseModel
from typing import Optional, List
from datetime import datetime
import qrcode
import qrcode.image.svg
from io import BytesIO
import base64

from app.database import get_db
from app.models import Tour, TourFrame, TourStatus, User
from app.api.auth import get_current_user_required, get_current_user
from app.config import get_settings
from app.services.storage import StorageService
from app.services.queue import enqueue_stitch_job

router = APIRouter()
settings = get_settings()
storage = StorageService()


# Pydantic schemas
class TourCreate(BaseModel):
    name: str
    address: Optional[str] = None
    notes: Optional[str] = None


class TourResponse(BaseModel):
    id: str
    name: str
    address: Optional[str]
    notes: Optional[str]
    status: TourStatus
    public_slug: str
    pano_url: Optional[str]
    created_at: datetime
    completed_at: Optional[datetime]
    
    # Computed fields
    web_url: str
    public_viewer_url: str
    capture_universal_link: str
    qr_data: str
    qr_svg: Optional[str] = None

    class Config:
        from_attributes = True


class TourListItem(BaseModel):
    id: str
    name: str
    address: Optional[str]
    status: TourStatus
    public_slug: str
    pano_url: Optional[str]
    created_at: datetime
    completed_at: Optional[datetime]

    class Config:
        from_attributes = True


class UploadUrlsRequest(BaseModel):
    count: int = 16


class UploadUrlsResponse(BaseModel):
    upload_urls: List[str]
    frame_keys: List[str]


class FrameMeta(BaseModel):
    index: int
    yaw: Optional[float] = None
    pitch: Optional[float] = None


class CompleteUploadRequest(BaseModel):
    frame_keys: List[str]
    frames_meta: Optional[List[FrameMeta]] = None


class CompleteUploadResponse(BaseModel):
    status: TourStatus


class PublicTourResponse(BaseModel):
    id: str
    name: str
    address: Optional[str]
    status: TourStatus
    pano_url: Optional[str]
    public_slug: str


# Helper functions
def generate_qr_svg(data: str) -> str:
    """Generate QR code as SVG string"""
    qr = qrcode.QRCode(version=1, box_size=10, border=2)
    qr.add_data(data)
    qr.make(fit=True)
    
    factory = qrcode.image.svg.SvgPathImage
    img = qr.make_image(fill_color="black", back_color="white", image_factory=factory)
    
    buffer = BytesIO()
    img.save(buffer)
    svg_str = buffer.getvalue().decode('utf-8')
    return svg_str


def build_tour_response(tour: Tour, include_qr: bool = True) -> TourResponse:
    """Build TourResponse with computed fields"""
    web_url = f"{settings.web_base_url}/tours/{tour.id}"
    public_viewer_url = f"{settings.web_base_url}/p/{tour.public_slug}"
    
    # Universal link for iOS app
    capture_link = f"https://{settings.universal_links_domain}/capture/{tour.id}"
    
    # QR code contains the universal link
    qr_data = capture_link
    qr_svg = generate_qr_svg(qr_data) if include_qr else None
    
    return TourResponse(
        id=tour.id,
        name=tour.name,
        address=tour.address,
        notes=tour.notes,
        status=tour.status,
        public_slug=tour.public_slug,
        pano_url=tour.pano_url,
        created_at=tour.created_at,
        completed_at=tour.completed_at,
        web_url=web_url,
        public_viewer_url=public_viewer_url,
        capture_universal_link=capture_link,
        qr_data=qr_data,
        qr_svg=qr_svg
    )


# Routes
@router.post("", response_model=TourResponse)
async def create_tour(
    tour_data: TourCreate,
    current_user: User = Depends(get_current_user_required),
    db: AsyncSession = Depends(get_db)
):
    """Create a new tour"""
    tour = Tour(
        user_id=current_user.id,
        name=tour_data.name,
        address=tour_data.address,
        notes=tour_data.notes,
        status=TourStatus.WAITING
    )
    db.add(tour)
    await db.commit()
    await db.refresh(tour)
    
    return build_tour_response(tour)


@router.get("", response_model=List[TourListItem])
async def list_tours(
    current_user: User = Depends(get_current_user_required),
    db: AsyncSession = Depends(get_db)
):
    """List all tours for current user"""
    result = await db.execute(
        select(Tour)
        .where(Tour.user_id == current_user.id)
        .order_by(Tour.created_at.desc())
    )
    tours = result.scalars().all()
    return [TourListItem.model_validate(t) for t in tours]


@router.get("/{tour_id}", response_model=TourResponse)
async def get_tour(
    tour_id: str,
    current_user: Optional[User] = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    """Get tour by ID"""
    result = await db.execute(select(Tour).where(Tour.id == tour_id))
    tour = result.scalar_one_or_none()
    
    if not tour:
        raise HTTPException(status_code=404, detail="Tour not found")
    
    # Allow access if user owns the tour or if it's ready (public)
    if tour.user_id != (current_user.id if current_user else None):
        if tour.status != TourStatus.READY:
            raise HTTPException(status_code=403, detail="Access denied")
    
    return build_tour_response(tour)


@router.get("/public/{slug}", response_model=PublicTourResponse)
async def get_public_tour(
    slug: str,
    db: AsyncSession = Depends(get_db)
):
    """Get public tour by slug (for public viewer)"""
    result = await db.execute(select(Tour).where(Tour.public_slug == slug))
    tour = result.scalar_one_or_none()
    
    if not tour:
        raise HTTPException(status_code=404, detail="Tour not found")
    
    if tour.status != TourStatus.READY:
        raise HTTPException(status_code=404, detail="Tour not ready")
    
    return PublicTourResponse(
        id=tour.id,
        name=tour.name,
        address=tour.address,
        status=tour.status,
        pano_url=tour.pano_url,
        public_slug=tour.public_slug
    )


@router.post("/{tour_id}/uploads", response_model=UploadUrlsResponse)
async def get_upload_urls(
    tour_id: str,
    request: UploadUrlsRequest,
    db: AsyncSession = Depends(get_db)
):
    """Get presigned upload URLs for frames"""
    result = await db.execute(select(Tour).where(Tour.id == tour_id))
    tour = result.scalar_one_or_none()
    
    if not tour:
        raise HTTPException(status_code=404, detail="Tour not found")
    
    if tour.status not in [TourStatus.WAITING, TourStatus.UPLOADING]:
        raise HTTPException(status_code=400, detail="Tour cannot accept uploads")
    
    # Generate presigned URLs for each frame
    upload_urls = []
    frame_keys = []
    
    for i in range(request.count):
        key = f"tours/{tour_id}/frames/frame_{i:02d}.jpg"
        url = storage.generate_presigned_upload_url(key)
        upload_urls.append(url)
        frame_keys.append(key)
    
    # Update tour status
    tour.status = TourStatus.UPLOADING
    await db.commit()
    
    return UploadUrlsResponse(
        upload_urls=upload_urls,
        frame_keys=frame_keys
    )


@router.post("/{tour_id}/complete-upload", response_model=CompleteUploadResponse)
async def complete_upload(
    tour_id: str,
    request: CompleteUploadRequest,
    db: AsyncSession = Depends(get_db)
):
    """Mark upload as complete and start stitching"""
    result = await db.execute(select(Tour).where(Tour.id == tour_id))
    tour = result.scalar_one_or_none()
    
    if not tour:
        raise HTTPException(status_code=404, detail="Tour not found")
    
    if tour.status not in [TourStatus.WAITING, TourStatus.UPLOADING]:
        raise HTTPException(status_code=400, detail="Tour cannot be processed")
    
    # Save frame metadata
    if request.frames_meta:
        tour.frames_meta = [
            {"index": f.index, "yaw": f.yaw, "pitch": f.pitch}
            for f in request.frames_meta
        ]
    
    # Create frame records
    for i, key in enumerate(request.frame_keys):
        meta = next((f for f in (request.frames_meta or []) if f.index == i), None)
        frame = TourFrame(
            tour_id=tour_id,
            frame_index=str(i),
            frame_key=key,
            yaw=str(meta.yaw) if meta and meta.yaw else None,
            pitch=str(meta.pitch) if meta and meta.pitch else None,
            uploaded="true"
        )
        db.add(frame)
    
    # Update status and enqueue stitch job
    tour.status = TourStatus.PROCESSING
    await db.commit()
    
    # Enqueue stitching job
    try:
        enqueue_stitch_job(tour_id, request.frame_keys)
    except Exception as e:
        print(f"Warning: Could not enqueue stitch job: {e}")
        # Don't fail the request - job can be retried
    
    return CompleteUploadResponse(status=tour.status)


@router.get("/{tour_id}/download")
async def download_pano(
    tour_id: str,
    db: AsyncSession = Depends(get_db)
):
    """Download the stitched panorama"""
    result = await db.execute(select(Tour).where(Tour.id == tour_id))
    tour = result.scalar_one_or_none()
    
    if not tour:
        raise HTTPException(status_code=404, detail="Tour not found")
    
    if tour.status != TourStatus.READY or not tour.pano_url:
        raise HTTPException(status_code=404, detail="Panorama not ready")
    
    # Generate presigned download URL and redirect
    if tour.pano_key:
        download_url = storage.generate_presigned_download_url(
            tour.pano_key,
            filename=f"{tour.name.replace(' ', '_')}_pano.jpg"
        )
        return RedirectResponse(url=download_url)
    
    return RedirectResponse(url=tour.pano_url)


@router.delete("/{tour_id}")
async def delete_tour(
    tour_id: str,
    current_user: User = Depends(get_current_user_required),
    db: AsyncSession = Depends(get_db)
):
    """Delete a tour"""
    result = await db.execute(select(Tour).where(Tour.id == tour_id))
    tour = result.scalar_one_or_none()
    
    if not tour:
        raise HTTPException(status_code=404, detail="Tour not found")
    
    if tour.user_id != current_user.id:
        raise HTTPException(status_code=403, detail="Access denied")
    
    # Delete from storage
    try:
        storage.delete_tour_files(tour_id)
    except Exception as e:
        print(f"Warning: Could not delete tour files: {e}")
    
    await db.delete(tour)
    await db.commit()
    
    return {"status": "deleted"}
