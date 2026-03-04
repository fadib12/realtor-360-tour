import SwiftUI

struct GuidedCaptureView: View {
    let tourId: String
    let tourName: String
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cameraService = CameraService()
    @StateObject private var motionService = MotionService()
    @StateObject private var captureController: GuidedCaptureController
    
    @State private var showUpload = false
    
    init(tourId: String, tourName: String) {
        self.tourId = tourId
        self.tourName = tourName
        
        let camera = CameraService()
        let motion = MotionService()
        _cameraService = StateObject(wrappedValue: camera)
        _motionService = StateObject(wrappedValue: motion)
        _captureController = StateObject(wrappedValue: GuidedCaptureController(cameraService: camera, motionService: motion))
    }
    
    var body: some View {
        ZStack {
            // Camera preview
            CameraPreviewView(session: cameraService.session)
                .ignoresSafeArea()
            
            // Overlay
            VStack {
                // Top bar
                TopBar(
                    progress: captureController.progressText,
                    onClose: { dismiss() }
                )
                
                Spacer()
                
                // Target dot overlay
                if let target = captureController.currentTarget {
                    TargetDotView(
                        targetYaw: target.yaw,
                        targetPitch: target.pitch,
                        currentYaw: motionService.yaw,
                        currentPitch: motionService.pitch,
                        isAligned: captureController.isAligned
                    )
                }
                
                Spacer()
                
                // Bottom info
                BottomInfo(
                    target: captureController.currentTarget,
                    isAligned: captureController.isAligned,
                    isCapturing: captureController.isCapturing
                )
            }
            
            // Progress ring
            if captureController.isCapturing {
                CapturingOverlay()
            }
            
            // Error overlay
            if let error = captureController.error {
                ErrorOverlay(error: error) {
                    captureController.retryCapture()
                }
            }
        }
        .onAppear {
            captureController.start()
        }
        .onDisappear {
            captureController.stop()
        }
        .onChange(of: captureController.captureComplete) { _, complete in
            if complete {
                showUpload = true
            }
        }
        .fullScreenCover(isPresented: $showUpload) {
            UploadingView(
                tourId: tourId,
                captureController: captureController
            )
        }
    }
}

// MARK: - Top Bar

struct TopBar: View {
    let progress: String
    let onClose: () -> Void
    
    var body: some View {
        HStack {
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3)
                    .foregroundColor(.white)
                    .padding(12)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
            }
            
            Spacer()
            
            Text(progress)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.5))
                .cornerRadius(20)
            
            Spacer()
            
            // Placeholder for symmetry
            Color.clear
                .frame(width: 44, height: 44)
        }
        .padding()
    }
}

// MARK: - Bottom Info

struct BottomInfo: View {
    let target: CaptureTarget?
    let isAligned: Bool
    let isCapturing: Bool
    
    var body: some View {
        VStack(spacing: 8) {
            if let target = target {
                Text(directionText(for: target))
                    .font(.headline)
                    .foregroundColor(.white)
                
                Text(isAligned ? "Hold steady..." : "Point camera at the dot")
                    .font(.subheadline)
                    .foregroundColor(isAligned ? .green : .white.opacity(0.8))
            }
            
            if isCapturing {
                Text("Capturing...")
                    .font(.caption)
                    .foregroundColor(.yellow)
            }
        }
        .padding()
        .background(Color.black.opacity(0.5))
        .cornerRadius(12)
        .padding(.bottom, 40)
    }
    
    private func directionText(for target: CaptureTarget) -> String {
        var parts: [String] = []
        
        // Vertical direction
        if target.pitch > 20 {
            parts.append("UP")
        } else if target.pitch < -20 {
            parts.append("DOWN")
        }
        
        // Horizontal direction
        let yaw = target.yaw
        if yaw >= 337.5 || yaw < 22.5 {
            parts.append("FRONT")
        } else if yaw >= 22.5 && yaw < 67.5 {
            parts.append("FRONT-RIGHT")
        } else if yaw >= 67.5 && yaw < 112.5 {
            parts.append("RIGHT")
        } else if yaw >= 112.5 && yaw < 157.5 {
            parts.append("BACK-RIGHT")
        } else if yaw >= 157.5 && yaw < 202.5 {
            parts.append("BACK")
        } else if yaw >= 202.5 && yaw < 247.5 {
            parts.append("BACK-LEFT")
        } else if yaw >= 247.5 && yaw < 292.5 {
            parts.append("LEFT")
        } else {
            parts.append("FRONT-LEFT")
        }
        
        return parts.joined(separator: " • ")
    }
}

// MARK: - Capturing Overlay

struct CapturingOverlay: View {
    var body: some View {
        ZStack {
            Color.white.opacity(0.3)
                .ignoresSafeArea()
            
            Circle()
                .stroke(Color.white, lineWidth: 4)
                .frame(width: 80, height: 80)
                .overlay(
                    Circle()
                        .trim(from: 0, to: 0.7)
                        .stroke(Color.green, lineWidth: 4)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.3).repeatForever(autoreverses: false), value: UUID())
                )
        }
        .transition(.opacity)
    }
}

// MARK: - Error Overlay

struct ErrorOverlay: View {
    let error: Error
    let onRetry: () -> Void
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.orange)
                
                Text("Capture Error")
                    .font(.headline)
                    .foregroundColor(.white)
                
                Text(error.localizedDescription)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                Button("Retry") {
                    onRetry()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }
}

#Preview {
    GuidedCaptureView(tourId: "test", tourName: "Test Tour")
}
