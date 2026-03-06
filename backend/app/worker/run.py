"""
Celery worker entry-point and main processing task.

Pipeline:
  1. Download uploaded photos from S3
  2. Stitch panorama with OpenCV
  3. Generate preview thumbnail
  4. Upload panorama + preview to S3
  5. Call World Labs API to generate 3D world
  6. Poll World Labs until complete
  7. Store all URLs in database
"""

import logging
from datetime import datetime, timezone
from urllib.parse import urlparse

from sqlalchemy import select
from sqlalchemy.orm import Session
from sqlalchemy import create_engine

from ..config import get_settings
from ..services.queue import celery_app
from ..services.storage import download_file, upload_file, public_url_for
from .stitch import stitch_images, generate_preview
from .worldlabs import WorldLabsClient

logger = logging.getLogger(__name__)
settings = get_settings()

# Synchronous engine for the Celery worker (Celery is sync)
_sync_url = settings.database_url.replace("+asyncpg", "")
sync_engine = create_engine(_sync_url, echo=settings.debug)


def _get_sync_session() -> Session:
    return Session(sync_engine)


def _is_publicly_reachable_url(url: str) -> bool:
    """Heuristic check for URLs that cloud services can fetch."""
    try:
        parsed = urlparse(url)
        host = (parsed.hostname or "").lower()
    except Exception:
        return False

    if not host:
        return False
    if host in {"localhost", "127.0.0.1", "::1"}:
        return False
    if host.endswith(".local"):
        return False
    if host.startswith("192.168.") or host.startswith("10."):
        return False
    if host.startswith("172."):
        parts = host.split(".")
        if len(parts) >= 2 and parts[1].isdigit():
            second = int(parts[1])
            if 16 <= second <= 31:
                return False
    return True


@celery_app.task(name="worker.process_capture", bind=True, max_retries=2)
def process_capture(self, capture_id: str):
    """Main Celery task: stitch → upload → World Labs → complete."""
    logger.info("Processing capture %s", capture_id)

    with _get_sync_session() as db:
        from ..models import Capture

        capture = db.execute(
            select(Capture).where(Capture.id == capture_id)
        ).scalar_one_or_none()

        if not capture:
            logger.error("Capture %s not found", capture_id)
            return

        try:
            # ── Step 1: Download photos ──────────────────────
            capture.status = "stitching"
            capture.progress = 0.1
            db.commit()

            image_bytes_list = []
            for i, key in enumerate(capture.photo_keys or []):
                logger.info("Downloading %s (%d/%d)", key, i + 1, len(capture.photo_keys))
                data = download_file(key)
                image_bytes_list.append(data)
                capture.progress = 0.1 + 0.2 * ((i + 1) / max(len(capture.photo_keys), 1))
                db.commit()

            # ── Step 2: Stitch panorama ──────────────────────
            if capture.capture_type == "multiPhoto16" and len(image_bytes_list) > 1:
                logger.info("Stitching %d images", len(image_bytes_list))
                panorama_bytes = stitch_images(image_bytes_list)
            elif image_bytes_list:
                # Single panorama upload — no stitching needed
                panorama_bytes = image_bytes_list[0]
            else:
                raise ValueError("No images to process")

            capture.progress = 0.5
            db.commit()

            # ── Step 3: Generate preview thumbnail ───────────
            preview_bytes = generate_preview(panorama_bytes, max_width=800)

            # ── Step 4: Upload to S3 ─────────────────────────
            panorama_key = f"captures/{capture_id}/panorama.jpg"
            preview_key = f"captures/{capture_id}/preview.jpg"

            panorama_url = upload_file(panorama_key, panorama_bytes)
            preview_url = upload_file(preview_key, preview_bytes)

            capture.panorama_key = panorama_key
            capture.preview_key = preview_key
            capture.panorama_url = panorama_url
            capture.preview_url = preview_url
            capture.progress = 0.6
            db.commit()

            logger.info("Panorama uploaded: %s", panorama_url)

            # ── Step 5: World Labs 3D generation ─────────────
            if settings.worldlabs_api_key:
                if not _is_publicly_reachable_url(panorama_url):
                    logger.warning(
                        "Skipping World Labs for capture %s: panorama URL is not publicly reachable: %s",
                        capture_id,
                        panorama_url,
                    )
                    capture.error_message = (
                        "3D generation skipped: panorama URL is local/private. "
                        "Set S3_PUBLIC_URL to a public HTTPS endpoint (for example, Cloudflare R2/S3)."
                    )
                else:
                    capture.status = "generating_world"
                    capture.progress = 0.65
                    db.commit()

                    wl = WorldLabsClient(
                        api_key=settings.worldlabs_api_key,
                        base_url=settings.worldlabs_base_url,
                    )

                    # Start generation
                    operation = wl.generate_world(panorama_url)
                    capture.world_operation_id = operation["name"]
                    capture.progress = 0.7
                    db.commit()

                    # Poll until complete
                    world_result = wl.poll_until_done(
                        operation["name"],
                        on_progress=lambda p: _update_progress(db, capture, 0.7 + 0.25 * p),
                    )

                    # Extract world details
                    if world_result:
                        capture.world_id = world_result.get("world_id")
                        capture.world_url = world_result.get("world_url")
                        capture.thumbnail_url = world_result.get("thumbnail_url")
                        capture.collider_mesh_url = world_result.get("collider_mesh_url")

                        splats = world_result.get("splats", {})
                        capture.splats_100k_url = splats.get("100k")
                        capture.splats_500k_url = splats.get("500k")
                        capture.splats_full_url = splats.get("full_res")
                    else:
                        logger.warning("World Labs timed out for capture %s — completing without 3D world", capture_id)
                        capture.error_message = "3D world generation timed out. Panorama is still available."
            else:
                logger.warning("WORLDLABS_API_KEY not set — skipping 3D world generation")

            # ── Step 6: Mark complete ────────────────────────
            capture.status = "complete"
            capture.progress = 1.0
            capture.completed_at = datetime.now(timezone.utc)
            db.commit()

            logger.info("Capture %s completed successfully", capture_id)

        except Exception as exc:
            logger.exception("Failed to process capture %s", capture_id)
            capture.error_message = str(exc)[:500]

            if self.request.retries < self.max_retries:
                # Still have retries left — don't mark as failed
                capture.status = "retrying"
                db.commit()
                raise self.retry(exc=exc, countdown=30 * (self.request.retries + 1))
            else:
                # All retries exhausted — mark as permanently failed
                capture.status = "failed"
                db.commit()


def _update_progress(db: Session, capture, progress: float):
    """Helper to update progress during World Labs polling."""
    capture.progress = min(progress, 0.99)
    db.commit()
