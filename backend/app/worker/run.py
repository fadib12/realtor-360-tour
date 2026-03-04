"""
RQ Worker Runner

Run with: python -m app.worker.run
"""

import os
import sys

# Add parent directory to path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(__file__))))

from redis import Redis
from rq import Worker, Queue
from app.config import get_settings

settings = get_settings()


def main():
    redis_conn = Redis.from_url(settings.redis_url)
    
    # Create queue
    queues = [Queue('stitch', connection=redis_conn)]
    
    print(f"Starting worker...")
    print(f"Redis: {settings.redis_url}")
    print(f"Listening on queues: {[q.name for q in queues]}")
    
    # Start worker
    worker = Worker(queues, connection=redis_conn)
    worker.work(with_scheduler=True)


if __name__ == '__main__':
    main()
