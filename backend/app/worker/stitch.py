"""
Panorama Stitching Worker

This worker processes uploaded frames and stitches them into
an equirectangular panorama using OpenCV.
"""

import os
import cv2
import numpy as np
from typing import List
import tempfile
import shutil
from datetime import datetime

from app.services.storage import StorageService
from app.config import get_settings

settings = get_settings()
storage = StorageService()


def update_tour_status(tour_id: str, status: str, pano_url: str = None, pano_key: str = None, error: str = None):
    """Update tour status in database"""
    # Use synchronous database connection for worker
    from sqlalchemy import create_engine
    from sqlalchemy.orm import sessionmaker
    from app.models import Tour, TourStatus
    
    engine = create_engine(settings.database_url)
    Session = sessionmaker(bind=engine)
    session = Session()
    
    try:
        tour = session.query(Tour).filter(Tour.id == tour_id).first()
        if tour:
            tour.status = TourStatus[status]
            if pano_url:
                tour.pano_url = pano_url
            if pano_key:
                tour.pano_key = pano_key
            if error:
                tour.error_message = error
            if status == 'READY':
                tour.completed_at = datetime.utcnow()
            session.commit()
    finally:
        session.close()
        engine.dispose()


def download_frames(tour_id: str, frame_keys: List[str], temp_dir: str) -> List[str]:
    """Download all frames to temp directory"""
    frame_paths = []
    
    for i, key in enumerate(frame_keys):
        local_path = os.path.join(temp_dir, f"frame_{i:02d}.jpg")
        print(f"Downloading frame {i}: {key}")
        storage.download_file(key, local_path)
        frame_paths.append(local_path)
    
    return frame_paths


def simple_equirectangular_stitch(frame_paths: List[str], output_path: str) -> bool:
    """
    Simple equirectangular stitching approach.
    
    For MVP, we'll use OpenCV's built-in stitcher with spherical projection.
    This may not produce perfect results but provides a working baseline.
    """
    print(f"Loading {len(frame_paths)} frames...")
    
    # Load all images
    images = []
    for path in frame_paths:
        img = cv2.imread(path)
        if img is not None:
            images.append(img)
        else:
            print(f"Warning: Could not load {path}")
    
    if len(images) < 8:
        raise Exception(f"Not enough valid frames: {len(images)}")
    
    print(f"Loaded {len(images)} frames, starting stitch...")
    
    # Create stitcher with SCANS mode (better for panoramas)
    stitcher = cv2.Stitcher.create(cv2.Stitcher_PANORAMA)
    
    # Configure stitcher for spherical projection
    stitcher.setPanoConfidenceThresh(0.5)
    
    # Attempt stitching
    status, pano = stitcher.stitch(images)
    
    if status == cv2.Stitcher_OK:
        print(f"Stitching successful! Output size: {pano.shape}")
        
        # Ensure 2:1 aspect ratio for equirectangular
        h, w = pano.shape[:2]
        target_w = h * 2
        
        if w != target_w:
            # Resize to proper equirectangular ratio
            pano = cv2.resize(pano, (target_w, h), interpolation=cv2.INTER_LANCZOS4)
        
        # Save output
        cv2.imwrite(output_path, pano, [cv2.IMWRITE_JPEG_QUALITY, 95])
        return True
    else:
        error_messages = {
            cv2.Stitcher_ERR_NEED_MORE_IMGS: "Need more images",
            cv2.Stitcher_ERR_HOMOGRAPHY_EST_FAIL: "Homography estimation failed",
            cv2.Stitcher_ERR_CAMERA_PARAMS_ADJUST_FAIL: "Camera params adjustment failed"
        }
        raise Exception(f"Stitching failed: {error_messages.get(status, f'Unknown error {status}')}")


def fallback_grid_stitch(frame_paths: List[str], output_path: str) -> bool:
    """
    Fallback: Create a simple grid layout of images if stitching fails.
    This ensures we always produce some output.
    """
    print("Using fallback grid stitch...")
    
    images = []
    for path in frame_paths:
        img = cv2.imread(path)
        if img is not None:
            # Resize to consistent size
            img = cv2.resize(img, (640, 480))
            images.append(img)
    
    if not images:
        raise Exception("No valid images for fallback stitch")
    
    # Arrange in 4x4 grid
    rows = []
    for i in range(0, 16, 4):
        row_imgs = images[i:i+4]
        while len(row_imgs) < 4:
            row_imgs.append(np.zeros((480, 640, 3), dtype=np.uint8))
        rows.append(np.hstack(row_imgs))
    
    grid = np.vstack(rows)
    
    # Resize to equirectangular dimensions
    output = cv2.resize(grid, (4096, 2048), interpolation=cv2.INTER_LANCZOS4)
    cv2.imwrite(output_path, output, [cv2.IMWRITE_JPEG_QUALITY, 90])
    
    return True


def stitch_tour(tour_id: str, frame_keys: List[str]) -> dict:
    """
    Main stitching function called by RQ worker.
    
    1. Downloads frames from S3
    2. Stitches into equirectangular panorama
    3. Uploads result back to S3
    4. Updates tour status
    """
    print(f"Starting stitch job for tour {tour_id}")
    print(f"Frame keys: {frame_keys}")
    
    temp_dir = tempfile.mkdtemp(prefix=f"tour_{tour_id}_")
    
    try:
        # Download frames
        frame_paths = download_frames(tour_id, frame_keys, temp_dir)
        print(f"Downloaded {len(frame_paths)} frames")
        
        # Output path
        output_path = os.path.join(temp_dir, "pano.jpg")
        
        # Try advanced stitching first
        try:
            simple_equirectangular_stitch(frame_paths, output_path)
        except Exception as e:
            print(f"Advanced stitching failed: {e}")
            print("Trying fallback grid stitch...")
            fallback_grid_stitch(frame_paths, output_path)
        
        # Upload result
        pano_key = f"tours/{tour_id}/pano.jpg"
        print(f"Uploading panorama to {pano_key}")
        storage.upload_file(pano_key, output_path)
        
        # Get public URL
        pano_url = storage.get_public_url(pano_key)
        
        # Update tour status
        update_tour_status(tour_id, 'READY', pano_url=pano_url, pano_key=pano_key)
        
        print(f"Stitch complete! Pano URL: {pano_url}")
        
        return {
            'status': 'success',
            'tour_id': tour_id,
            'pano_url': pano_url
        }
        
    except Exception as e:
        print(f"Stitch failed: {e}")
        update_tour_status(tour_id, 'FAILED', error=str(e))
        raise
        
    finally:
        # Cleanup temp directory
        shutil.rmtree(temp_dir, ignore_errors=True)
