from redis import Redis
from rq import Queue
from typing import List
from app.config import get_settings

settings = get_settings()


def get_redis_connection() -> Redis:
    """Get Redis connection"""
    return Redis.from_url(settings.redis_url)


def get_stitch_queue() -> Queue:
    """Get the stitching queue"""
    redis_conn = get_redis_connection()
    return Queue('stitch', connection=redis_conn)


def enqueue_stitch_job(tour_id: str, frame_keys: List[str]) -> str:
    """Enqueue a stitching job"""
    queue = get_stitch_queue()
    
    job = queue.enqueue(
        'app.worker.stitch.stitch_tour',
        tour_id,
        frame_keys,
        job_timeout='10m',  # 10 minute timeout
        result_ttl=86400,   # Keep result for 24 hours
    )
    
    return job.id


def get_job_status(job_id: str) -> dict:
    """Get status of a job"""
    from rq.job import Job
    redis_conn = get_redis_connection()
    
    try:
        job = Job.fetch(job_id, connection=redis_conn)
        return {
            'id': job.id,
            'status': job.get_status(),
            'result': job.result,
            'error': str(job.exc_info) if job.exc_info else None
        }
    except:
        return {'status': 'not_found'}
