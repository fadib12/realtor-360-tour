# Realtor 360 iOS App

SwiftUI app for capturing guided 360° photos.

## Requirements

- iOS 17.0+
- Xcode 15+
- Physical iPhone (camera required)

## Setup

1. Open `Realtor360.xcodeproj` in Xcode
2. Select your development team in Signing & Capabilities
3. Configure the API URL in `Services/APIService.swift`:
   ```swift
   private let baseURL = "http://localhost:8000"  // or your server URL
   ```
4. Run on physical device

## Features

- **Universal Links** - Opens directly from QR code scan
- **Guided Capture** - Visual targets for 16 shots
- **Auto Capture** - Captures automatically when aligned
- **Motion Tracking** - CoreMotion for device orientation
- **Haptic Feedback** - Tactile feedback on capture
- **Background Upload** - Progress tracking during upload

## Capture Process

The app guides users through 16 shots:
- **4 shots UP** (pitch +35°): yaw 0°, 90°, 180°, 270°
- **8 shots MID** (pitch 0°): yaw 0°, 45°, 90°, 135°, 180°, 225°, 270°, 315°
- **4 shots DOWN** (pitch -35°): yaw 0°, 90°, 180°, 270°

Tolerance: ±7° for both yaw and pitch
Stability: Must hold for 250ms before auto-capture

## Project Structure

```
Realtor360/
├── Realtor360App.swift    # App entry, Universal Links handler
├── ContentView.swift       # Main content view
├── Views/
│   ├── CaptureStartView.swift
│   ├── GuidedCaptureView.swift
│   ├── UploadingView.swift
│   ├── CameraPreviewView.swift
│   └── TargetDotView.swift
├── Services/
│   ├── CameraService.swift
│   ├── MotionService.swift
│   ├── GuidedCaptureController.swift
│   ├── UploadService.swift
│   └── APIService.swift
├── Models/
│   └── Models.swift
├── Assets.xcassets/
├── Info.plist
└── Realtor360.entitlements
```

## Universal Links Setup

For Universal Links to work in production:

1. Host an `apple-app-site-association` file at:
   `https://realtor360.app/.well-known/apple-app-site-association`

2. File contents:
   ```json
   {
     "applinks": {
       "apps": [],
       "details": [
         {
           "appID": "TEAMID.com.realtor360.app",
           "paths": ["/capture/*"]
         }
       ]
     }
   }
   ```

3. Update the entitlements file with your domain

## Permissions

The app requires:
- **Camera** - To capture photos
- **Motion** - To track device orientation

These are configured in Info.plist with usage descriptions.

## Development Notes

### Testing Without Server

For development without a backend:
1. Mock the API responses in `APIService.swift`
2. Use the simulator's Debug > Location menu to simulate motion

### Debugging Motion

The `MotionService` logs orientation data. Watch the console for:
- Current yaw/pitch values
- Alignment status
- Calibration events

### Photo Quality

The camera is configured for:
- Wide-angle lens (ultra-wide preferred)
- Auto exposure lock after initial reading
- Maximum quality JPEG output
