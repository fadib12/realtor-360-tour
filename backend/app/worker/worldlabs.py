"""
World Labs API client.

Implements the three-step flow:
  1. POST /worlds:generate — start 3D world generation from panorama
  2. GET  /operations/{id} — poll until the operation completes
  3. GET  /worlds/{id}     — fetch world details (URLs, splats, etc.)

API docs: https://docs.worldlabs.ai
"""

import logging
import time
from typing import Any, Callable

import requests

logger = logging.getLogger(__name__)

# Default polling settings
POLL_INTERVAL = 5       # seconds between polls
POLL_TIMEOUT = 600      # 10 minutes max wait


class WorldLabsClient:
    """Synchronous client for the World Labs Marble API."""

    def __init__(self, api_key: str, base_url: str = "https://api.worldlabs.ai/marble/v1"):
        self.api_key = api_key
        self.base_url = base_url.rstrip("/")
        self.session = requests.Session()
        self.session.headers.update({
            "WLT-Api-Key": api_key,
            "Content-Type": "application/json",
        })

    def generate_world(self, panorama_url: str, seed: int | None = None) -> dict:
        """
        Start generating a 3D world from an equirectangular panorama.

        Args:
            panorama_url: Publicly accessible URL to the panorama JPEG.
            seed: Optional generation seed for reproducibility.

        Returns:
            Operation dict with 'name' field (operation ID).
        """
        payload: dict[str, Any] = {
            "input_image_url": panorama_url,
            "world_type": "INTERIOR",  # real estate → interior
        }
        if seed is not None:
            payload["seed"] = seed

        resp = self.session.post(f"{self.base_url}/worlds:generate", json=payload)
        resp.raise_for_status()
        data = resp.json()

        logger.info("World Labs generation started: operation=%s", data.get("name"))
        return data

    def get_operation(self, operation_name: str) -> dict:
        """
        Check the status of an ongoing operation.

        Returns:
            Operation dict with 'done' boolean and optional 'response'.
        """
        resp = self.session.get(f"{self.base_url}/operations/{operation_name}")
        resp.raise_for_status()
        return resp.json()

    def get_world(self, world_id: str) -> dict:
        """
        Fetch the details of a completed world.

        Returns:
            World dict with URLs for viewer, thumbnail, splats, collider mesh.
        """
        resp = self.session.get(f"{self.base_url}/worlds/{world_id}")
        resp.raise_for_status()
        return resp.json()

    def poll_until_done(
        self,
        operation_name: str,
        on_progress: Callable[[float], None] | None = None,
        interval: int = POLL_INTERVAL,
        timeout: int = POLL_TIMEOUT,
    ) -> dict | None:
        """
        Poll an operation until it completes or times out.

        Args:
            operation_name: The operation ID from generate_world().
            on_progress: Optional callback with progress fraction (0.0–1.0).
            interval: Seconds between polls.
            timeout: Maximum seconds to wait.

        Returns:
            World details dict on success, None on timeout.
        """
        start = time.time()
        polls = 0

        while time.time() - start < timeout:
            time.sleep(interval)
            polls += 1

            op = self.get_operation(operation_name)
            elapsed_fraction = min((time.time() - start) / timeout, 1.0)

            if on_progress:
                on_progress(elapsed_fraction)

            if op.get("done"):
                response = op.get("response", {})
                world_id = response.get("world_id") or response.get("worldId")

                if world_id:
                    logger.info("World generation complete: world_id=%s", world_id)
                    world = self.get_world(world_id)
                    return self._extract_world_details(world_id, world)

                logger.warning("Operation done but no world_id found: %s", op)
                return None

            if op.get("error"):
                error = op["error"]
                logger.error("World Labs error: %s", error)
                raise RuntimeError(f"World Labs generation failed: {error.get('message', error)}")

            logger.debug("Poll %d: operation not done yet (%.0fs elapsed)", polls, time.time() - start)

        logger.warning("World Labs operation timed out after %ds", timeout)
        return None

    def _extract_world_details(self, world_id: str, world: dict) -> dict:
        """Normalise World Labs API response into our internal format."""
        # The world viewer URL
        world_url = world.get("viewer_url") or world.get("viewerUrl")
        if not world_url:
            # Construct from world ID
            world_url = f"https://marble.worldlabs.ai/w/{world_id}"

        # Thumbnail
        thumbnail_url = world.get("thumbnail_url") or world.get("thumbnailUrl")

        # Splat point clouds at various resolutions
        splats = {}
        splats_data = world.get("splats", {})
        if isinstance(splats_data, dict):
            splats = {
                "100k": splats_data.get("100k") or splats_data.get("low"),
                "500k": splats_data.get("500k") or splats_data.get("medium"),
                "full_res": splats_data.get("full_res") or splats_data.get("full"),
            }

        # Collider mesh
        collider_mesh_url = world.get("collider_mesh_url") or world.get("colliderMeshUrl")

        return {
            "world_id": world_id,
            "world_url": world_url,
            "thumbnail_url": thumbnail_url,
            "splats": splats,
            "collider_mesh_url": collider_mesh_url,
        }
