# Realtor 360 Tour Platform

A realtor-focused system for creating immersive 360° virtual tours. Capture guided photos on iOS, stitch on server, view/share on web.

## Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   iOS App       │     │   Web Frontend  │     │   Backend API   │
│   (Capture)     │────▶│   (Next.js)     │────▶│   (FastAPI)     │
│   SwiftUI       │     │   Pannellum     │     │   PostgreSQL    │
└─────────────────┘     └─────────────────┘     └─────────────────┘
                                                        │
                                                        ▼
                                               ┌─────────────────┐
                                               │   Worker        │
                                               │   (OpenCV)      │
                                               │   Stitching     │
                                               └─────────────────┘
```

## User Flow

1. Realtor logs into website dashboard
2. Click "Create Tour" → enter Tour Name, Address
3. Website shows Tour Status page with QR code
4. Scan QR with iPhone → opens iOS app via Universal Link
5. iOS app guides through 16 capture targets (dots)
6. Auto-captures each photo when aligned
7. App uploads frames to server (presigned URLs)
8. Server stitches frames into pano.jpg
9. Website shows 360 viewer with share/embed/download

## Project Structure

```
├── backend/           # FastAPI backend + worker
│   ├── app/
│   │   ├── api/       # API routes
│   │   ├── models/    # SQLAlchemy models
│   │   ├── services/  # Business logic
│   │   └── worker/    # Stitching worker
│   └── requirements.txt
├── web/               # Next.js frontend
│   ├── src/
│   │   ├── app/       # App router pages
│   │   ├── components/
│   │   └── lib/
│   └── package.json
└── ios/               # SwiftUI iOS app
    └── Realtor360/
        ├── Views/
        ├── Services/
        └── Models/
```

## Quick Start

### Backend

```bash
cd backend
python -m venv venv
venv\Scripts\activate  # Windows
pip install -r requirements.txt
cp .env.example .env   # Configure environment
uvicorn app.main:app --reload
```

### Web

```bash
cd web
npm install
cp .env.example .env.local  # Configure environment
npm run dev
```

### iOS

Open `ios/Realtor360.xcodeproj` in Xcode and run on device.

## Environment Variables

### Backend (.env)
```
DATABASE_URL=postgresql://user:pass@localhost/realtor360
REDIS_URL=redis://localhost:6379
S3_BUCKET=realtor360-tours
S3_REGION=us-east-1
AWS_ACCESS_KEY_ID=xxx
AWS_SECRET_ACCESS_KEY=xxx
JWT_SECRET=your-secret-key
```

### Web (.env.local)
```
NEXT_PUBLIC_API_URL=http://localhost:8000
```

## API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/tours` | Create new tour |
| GET | `/api/tours/{id}` | Get tour status |
| POST | `/api/tours/{id}/uploads` | Get presigned upload URLs |
| POST | `/api/tours/{id}/complete-upload` | Trigger stitching |
| GET | `/api/tours/{id}/download` | Download pano.jpg |

## Capture Target Map (16 shots)

- **Row UP** (pitch +35°): yaw 0°, 90°, 180°, 270°
- **Row MID** (pitch 0°): yaw 0°, 45°, 90°, 135°, 180°, 225°, 270°, 315°
- **Row DOWN** (pitch -35°): yaw 0°, 90°, 180°, 270°

Tolerance: yaw ±7°, pitch ±7°, stable 200-400ms

## License

MIT
