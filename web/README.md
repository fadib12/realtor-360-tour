# Realtor 360 Web

Next.js frontend for the Realtor 360 Tour Platform.

## Quick Start

### Prerequisites

- Node.js 18+
- npm or yarn

### Setup

1. Install dependencies:
```bash
npm install
```

2. Configure environment:
```bash
cp .env.local.example .env.local
# Edit .env.local with your API URL
```

### Running

**Development:**
```bash
npm run dev
```

**Production build:**
```bash
npm run build
npm start
```

## Features

- **Dashboard** - List and manage tours
- **Tour Creation** - Create new tours with QR codes
- **Tour Viewer** - Interactive 360° panorama viewer (Pannellum)
- **Public Sharing** - Share links and embed codes
- **Responsive** - Works on desktop and mobile

## Pages

| Route | Description |
|-------|-------------|
| `/` | Landing page |
| `/login` | User login |
| `/register` | User registration |
| `/dashboard` | Tour dashboard |
| `/tours/new` | Create new tour |
| `/tours/[id]` | Tour detail & status |
| `/p/[slug]` | Public viewer page |

## Tech Stack

- **Next.js 14** - React framework
- **TypeScript** - Type safety
- **Tailwind CSS** - Styling
- **Pannellum** - 360° viewer
- **qrcode.react** - QR code generation

## Project Structure

```
src/
├── app/
│   ├── layout.tsx      # Root layout
│   ├── page.tsx        # Landing page
│   ├── login/          # Login page
│   ├── register/       # Registration page
│   ├── dashboard/      # Dashboard page
│   ├── tours/
│   │   ├── new/        # Create tour page
│   │   └── [id]/       # Tour detail page
│   └── p/
│       └── [slug]/     # Public viewer
├── components/
│   ├── Navbar.tsx      # Navigation
│   ├── PanoramaViewer.tsx
│   ├── QRCodeDisplay.tsx
│   ├── StatusBadge.tsx
│   └── TourCard.tsx
└── lib/
    ├── api.ts          # API client
    ├── auth-context.tsx
    └── utils.ts        # Utilities
```

## Environment Variables

```env
NEXT_PUBLIC_API_URL=http://localhost:8000
```

## Development

### Adding a new page

1. Create file in `src/app/[route]/page.tsx`
2. Export default function component
3. Use client directive if needed: `'use client'`

### Styling

Uses Tailwind CSS with custom classes defined in `globals.css`:
- `.btn`, `.btn-primary`, `.btn-secondary`
- `.input`
- `.card`
- `.status-*` badges
