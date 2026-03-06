"""
OpenCV panorama stitching pipeline.

Takes a list of JPEG byte arrays and produces a stitched equirectangular panorama.
"""

import logging

import cv2
import numpy as np

logger = logging.getLogger(__name__)


def stitch_images(image_bytes_list: list[bytes]) -> bytes:
    """
    Stitch multiple overlapping images into one panorama.

    Args:
        image_bytes_list: List of JPEG-encoded image bytes.

    Returns:
        JPEG bytes of the stitched panorama.

    Raises:
        RuntimeError: If stitching fails (not enough overlap, etc.).
    """
    # Decode all images
    images = []
    for i, raw in enumerate(image_bytes_list):
        arr = np.frombuffer(raw, dtype=np.uint8)
        img = cv2.imdecode(arr, cv2.IMREAD_COLOR)
        if img is None:
            logger.warning("Could not decode image %d — skipping", i)
            continue
        images.append(img)

    if len(images) < 2:
        if images:
            # Only one valid image — return it as-is
            _, buf = cv2.imencode(".jpg", images[0], [cv2.IMWRITE_JPEG_QUALITY, 92])
            return buf.tobytes()
        raise RuntimeError("No valid images to stitch")

    logger.info("Stitching %d images with OpenCV", len(images))

    # Create stitcher in PANORAMA mode
    stitcher = cv2.Stitcher_create(cv2.Stitcher_PANORAMA)

    # Tune for real-estate 360 captures
    stitcher.setPanoConfidenceThresh(0.6)

    status, pano = stitcher.stitch(images)

    if status == cv2.Stitcher_OK:
        logger.info("Stitch succeeded: %dx%d", pano.shape[1], pano.shape[0])
        _, buf = cv2.imencode(".jpg", pano, [cv2.IMWRITE_JPEG_QUALITY, 92])
        return buf.tobytes()

    # Map error codes to readable messages
    error_map = {
        cv2.Stitcher_ERR_NEED_MORE_IMGS: "Not enough overlapping images",
        cv2.Stitcher_ERR_HOMOGRAPHY_EST_FAIL: "Homography estimation failed",
        cv2.Stitcher_ERR_CAMERA_PARAMS_ADJUST_FAIL: "Camera parameter adjustment failed",
    }
    msg = error_map.get(status, f"Unknown stitcher error (code {status})")

    # Fallback: try with lower confidence threshold
    logger.warning("Primary stitch failed (%s), retrying with lower threshold", msg)
    stitcher.setPanoConfidenceThresh(0.3)
    status2, pano2 = stitcher.stitch(images)

    if status2 == cv2.Stitcher_OK:
        logger.info("Fallback stitch succeeded: %dx%d", pano2.shape[1], pano2.shape[0])
        _, buf = cv2.imencode(".jpg", pano2, [cv2.IMWRITE_JPEG_QUALITY, 92])
        return buf.tobytes()

    raise RuntimeError(f"Panorama stitching failed: {msg}")


def generate_preview(panorama_bytes: bytes, max_width: int = 800) -> bytes:
    """
    Generate a smaller preview/thumbnail from the panorama.

    Args:
        panorama_bytes: JPEG bytes of the full panorama.
        max_width: Maximum width of the preview.

    Returns:
        JPEG bytes of the resized preview.
    """
    arr = np.frombuffer(panorama_bytes, dtype=np.uint8)
    img = cv2.imdecode(arr, cv2.IMREAD_COLOR)

    if img is None:
        raise RuntimeError("Could not decode panorama for preview")

    h, w = img.shape[:2]
    if w > max_width:
        scale = max_width / w
        new_w = max_width
        new_h = int(h * scale)
        img = cv2.resize(img, (new_w, new_h), interpolation=cv2.INTER_AREA)

    _, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 80])
    return buf.tobytes()
