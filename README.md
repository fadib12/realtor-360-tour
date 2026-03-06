# Realtor 360° Tour — iOS App

Capture 360° virtual tours directly from your iPhone. Guided multi-shot capture with quality checks, motion tracking, and a result viewer.

## Architecture

- **SwiftUI + MVVM** — iOS 17.0+, Swift 5.9+
- **AVFoundation** — Camera capture
- **CoreMotion** — Yaw/pitch guided rotation
- **CoreImage** — Blur & brightness quality analysis
- **SceneKit** — Equirectangular panorama viewer
- **RealityKit** — 3D USDZ model viewer
- **No external dependencies** — all native Apple frameworks

## Project Structure

```
ios/Realtor360/
  App/               → App entry, TabView
  Core/
    Models/          → CaptureSession, CaptureStep
    Helpers/         → FileHelper, HapticManager, QualityChecker
    Networking/      → APIClient protocol, MockBackend
  Features/
    Capture/
      Managers/      → CameraManager, MotionManager
      ViewModels/    → CaptureViewModel, UploadViewModel
      Views/         → CaptureHomeView, GuidedCaptureView, CaptureResultView, etc.
    Explore/         → ExploreView (completed captures list)
    Profile/         → ProfileView (future sign-in)
  Viewers/           → PanoramaViewer, ModelViewer
```

## Getting Started

1. Open `ios/Realtor360.xcodeproj` in Xcode 15+
2. Select your Development Team in Signing & Capabilities
3. Build & run on a physical iPhone (camera required)

## Backend (future)

The app uses `MockBackend` for offline testing. When ready, swap to a real API by implementing `APIClientProtocol` with your Railway/Supabase backend.
