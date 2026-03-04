# Realtor 360 Backend

FastAPI backend with PostgreSQL, Redis, and S3 storage.

## Quick Start

### Prerequisites

- Python 3.11+
- PostgreSQL 14+
- Redis 7+
- AWS S3 bucket (or Cloudflare R2)

### Setup

1. Create virtual environment:
```bash
python -m venv venv
venv\Scripts\activate  # Windows
# or
source venv/bin/activate  # macOS/Linux
```

2. Install dependencies:
```bash
pip install -r requirements.txt
```

3. Configure environment:
```bash
cp .env.example .env
# Edit .env with your settings
```

4. Set up PostgreSQL database:
```sql
CREATE DATABASE realtor360;
```

5. Run database migrations:
```bash
# Tables are created automatically on first run
```

### Running

**API Server:**
```bash
uvicorn app.main:app --reload --port 8000
```

**Worker (for stitching):**
```bash
python -m app.worker.run
```

## API Endpoints

### Authentication

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/auth/register` | Register new user |
| POST | `/api/auth/login` | Login (returns token) |
| GET | `/api/auth/me` | Get current user |

### Tours

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/tours` | Create new tour |
| GET | `/api/tours` | List user's tours |
| GET | `/api/tours/{id}` | Get tour details |
| DELETE | `/api/tours/{id}` | Delete tour |
| POST | `/api/tours/{id}/uploads` | Get presigned upload URLs |
| POST | `/api/tours/{id}/complete-upload` | Complete upload, start stitching |
| GET | `/api/tours/{id}/download` | Download panorama |

### Public

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/tours/public/{slug}` | Get public tour by slug |

## Environment Variables

```env
# Database
DATABASE_URL=postgresql://user:pass@localhost:5432/realtor360

# Redis
REDIS_URL=redis://localhost:6379/0

# Storage (S3/R2)
S3_BUCKET=realtor360-tours
S3_REGION=us-east-1
S3_ENDPOINT_URL=  # Leave empty for AWS, set for R2
AWS_ACCESS_KEY_ID=xxx
AWS_SECRET_ACCESS_KEY=xxx

# JWT
JWT_SECRET=your-secret-key

# URLs
WEB_BASE_URL=http://localhost:3000
API_BASE_URL=http://localhost:8000
UNIVERSAL_LINKS_DOMAIN=realtor360.app
```

## Architecture

```
app/
├── main.py           # FastAPI entry point
├── config.py         # Configuration settings
├── database.py       # Database connection
├── models.py         # SQLAlchemy models
├── api/
│   ├── auth.py       # Authentication routes
│   ├── tours.py      # Tour management routes
│   └── health.py     # Health check
├── services/
│   ├── storage.py    # S3/R2 storage service
│   └── queue.py      # Redis queue service
└── worker/
    ├── run.py        # Worker entry point
    └── stitch.py     # Panorama stitching
```

## Development

### Running Tests
```bash
pytest
```

### API Documentation
Visit http://localhost:8000/docs for Swagger UI
