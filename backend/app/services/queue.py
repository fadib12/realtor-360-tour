"""
Celery task dispatch.

This module provides a thin wrapper around the Celery app to enqueue
the stitching + World Labs processing task.
"""

from celery import Celery

from ..config import get_settings

settings = get_settings()

celery_app = Celery(
    "realtor360",
    broker=settings.celery_broker_url,
    backend=settings.celery_result_backend,
    include=["app.worker.run"],  # ensures task modules are imported by the worker
)

celery_app.conf.update(
    task_serializer="json",
    accept_content=["json"],
    result_serializer="json",
    timezone="UTC",
    enable_utc=True,
    task_track_started=True,
    task_acks_late=True,
    worker_prefetch_multiplier=1,
)


def enqueue_processing(capture_id: str) -> str:
    """Send the processing task to the Celery worker. Returns the task ID."""
    result = celery_app.send_task(
        "worker.process_capture",
        args=[capture_id],
        queue="default",
    )
    return result.id
