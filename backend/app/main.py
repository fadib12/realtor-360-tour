from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from contextlib import asynccontextmanager

from app.config import get_settings
from app.database import engine, Base
from app.api import tours, auth, health


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup: Create tables
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield
    # Shutdown
    await engine.dispose()


app = FastAPI(
    title="Realtor 360 Tour Platform API",
    description="API for creating and managing 360° virtual tours",
    version="1.0.0",
    lifespan=lifespan
)

settings = get_settings()

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        settings.web_base_url,
        "http://localhost:3000",
        "http://localhost:3001",
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include routers
app.include_router(health.router, prefix="/api", tags=["Health"])
app.include_router(auth.router, prefix="/api/auth", tags=["Authentication"])
app.include_router(tours.router, prefix="/api/tours", tags=["Tours"])


@app.get("/")
async def root():
    return {
        "name": "Realtor 360 Tour Platform API",
        "version": "1.0.0",
        "docs": "/docs"
    }
