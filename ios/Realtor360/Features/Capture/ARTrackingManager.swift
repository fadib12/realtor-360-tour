import ARKit
import SceneKit
import SwiftUI
import AVFoundation
import simd
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// ARKit Tracking Manager — Maximum-Power 360° Panorama Capture Engine.
//
// Single ARSession provides:
//   • 6DOF world tracking (ARWorldTrackingConfiguration, gravity-aligned)
//   • Camera forward vector from ARFrame.camera.transform for alignment
//   • Dot projection via ARCamera.projectPoint for guidance UI
//   • Tracking quality monitoring (normal / limited / not available)
//   • Angular velocity measurement (deg/s) for motion gating
//   • High-resolution photo capture from ARFrame.capturedImage (AVFoundation)
//   • HDR bracket capture with focus + WB lock, exposure bias control,
//     per-frame motion rejection, and configurable settle time
//   • Live camera preview (ARSCNView)
//
// Stack:
//   Tracking   → ARKit (ARSession, camera.transform, trackingState)
//   Alignment  → dot(cameraForward, targetDirection) > cos(10°)
//   Projection → ARCamera.projectPoint(_:orientation:viewportSize:)
//   Camera     → AVFoundation via ARFrame.capturedImage (CVPixelBuffer)
//   HDR        → AVCaptureDevice focus/WB/exposure lock + HDRProcessor fusion
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
class ARTrackingManager: NSObject, ObservableObject {

    // ── Public session ──────────────────────────────────────────────────────
    let session = ARSession()

    // ── Published state ─────────────────────────────────────────────────────
    /// Camera forward direction (unit vector) in world space.
    @Published var cameraForward: simd_float3 = simd_float3(0, 0, -1)
    /// Live camera feed image (updated at 30 fps from ARFrame pixel buffer).
    @Published var cameraImage: UIImage? = nil
    /// Full camera transform for dot projection.
    @Published var cameraTransform: simd_float4x4 = matrix_identity_float4x4
    /// Camera position in world space.
    @Published var cameraPosition: simd_float3 = .zero
    /// Roll in degrees (side tilt). 0 = phone perfectly upright.
    @Published var rollDeg: Double = 0
    /// True once the AR session delivers its first frame.
    @Published var isAvailable = false

    // ── Tracking quality ────────────────────────────────────────────────────
    /// Current ARKit tracking quality state.
    @Published var trackingQuality: TrackingQuality = .notAvailable
    /// Angular velocity (degrees per second). Lower = more stable.
    @Published var angularVelocity: Double = 0

    enum TrackingQuality: Equatable {
        case normal
        case limited(reason: String)
        case notAvailable

        var isGoodForCapture: Bool {
            if case .normal = self { return true }
            return false
        }

        var displayLabel: String {
            switch self {
            case .normal:           return "Tracking: Good"
            case .limited(let r):   return "Tracking: \(r)"
            case .notAvailable:     return "Tracking: Unavailable"
            }
        }
    }

    // ── Current ARFrame (for projection) ────────────────────────────────────
    private(set) var currentFrame: ARFrame?

    // ── Private ─────────────────────────────────────────────────────────────
    /// AVCaptureDevice backing the ARKit camera — allows exposure bias,
    /// focus lock, and white balance lock for HDR bracket capture.
    private var cameraDevice: AVCaptureDevice?
    /// GPU-backed CIContext for photo encoding (reused, thread-safe).
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    /// Previous frame's forward vector for angular velocity calculation.
    private var previousForward: simd_float3?
    /// Previous frame's timestamp for angular velocity calculation.
    private var previousFrameTime: TimeInterval?

    // ── HDR bracket configuration ───────────────────────────────────────────
    /// Settle time (ms) after adjusting exposure bias. Higher = more accurate
    /// exposure but slower. 250ms is a good balance for indoor scenes.
    static let bracketSettleMs: UInt64 = 250
    /// Maximum angular movement (degrees) allowed between bracket frames.
    /// If exceeded, the bracket is retried.
    static let maxBracketMotionDeg: Double = 1.5

    // MARK: - Lifecycle

    override init() { super.init() }

    /// Start world tracking. Requests camera permission if needed.
    func start() async {
        guard ARWorldTrackingConfiguration.isSupported else {
            print("ARKit world tracking not supported on this device")
            isAvailable = false
            return
        }

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else { isAvailable = false; return }
        } else if status != .authorized {
            isAvailable = false
            return
        }

        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity  // Y = up; initial X/Z from device heading

        // Highest resolution video format for quality captures
        if let best = ARWorldTrackingConfiguration.supportedVideoFormats
            .sorted(by: { $0.imageResolution.width > $1.imageResolution.width })
            .first {
            config.videoFormat = best
        }

        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])

        // Cache AVCaptureDevice for HDR exposure bias + focus/WB control
        cameraDevice = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera

        previousForward = nil
        previousFrameTime = nil
    }

    func stop() {
        session.pause()
        isAvailable = false
        currentFrame = nil
        cameraDevice = nil
        previousForward = nil
        previousFrameTime = nil
        trackingQuality = .notAvailable
        angularVelocity = 0
    }

    // MARK: - Per-frame update (called at 30 fps by CaptureViewModel)

    /// Reads the latest ARFrame and extracts camera vectors, tracking quality,
    /// and angular velocity for motion gating.
    ///
    /// From `camera.transform` (simd_float4x4):
    ///   col 0 = right axis in world space
    ///   col 1 = up axis in world space
    ///   col 2 = backward axis in world space (camera looks in −Z)
    ///   col 3 = position in world space
    ///
    /// cameraForward = −normalize(col2)
    func processCurrentFrame() {
        guard let frame = session.currentFrame else { return }
        currentFrame = frame

        let t = frame.camera.transform

        // Camera forward = −Z column of the transform (normalised)
        let rawZ = simd_make_float3(t.columns.2)
        let forward = simd_normalize(-rawZ)
        cameraForward = forward

        // Position
        cameraPosition = simd_make_float3(t.columns.3)

        // Full transform (for projection)
        cameraTransform = t

        // Roll: tilt of right-axis Y component relative to world up
        let right = simd_make_float3(t.columns.0)
        let up = simd_make_float3(t.columns.1)
        rollDeg = Double(atan2(right.y, up.y)) * 180.0 / .pi

        // ── Tracking quality ────────────────────────────────────────────
        switch frame.camera.trackingState {
        case .normal:
            trackingQuality = .normal
        case .limited(let reason):
            let reasonStr: String
            switch reason {
            case .excessiveMotion:     reasonStr = "Too fast"
            case .insufficientFeatures: reasonStr = "Low detail"
            case .initializing:        reasonStr = "Initializing"
            case .relocalizing:        reasonStr = "Relocalizing"
            @unknown default:          reasonStr = "Limited"
            }
            trackingQuality = .limited(reason: reasonStr)
        case .notAvailable:
            trackingQuality = .notAvailable
        }

        // ── Angular velocity (deg/sec) ──────────────────────────────────
        let now = frame.timestamp
        if let prevFwd = previousForward, let prevTime = previousFrameTime {
            let dt = now - prevTime
            if dt > 0.001 {
                // Angle between consecutive forward vectors
                let dot = simd_clamp(simd_dot(forward, prevFwd), -1, 1)
                let angleDeg = Double(acos(dot)) * 180.0 / .pi
                let velocity = angleDeg / dt
                // Smooth with exponential moving average
                angularVelocity = angularVelocity * 0.7 + velocity * 0.3
            }
        }
        previousForward = forward
        previousFrameTime = now

        // ── Live camera image from pixel buffer ─────────────────────────
        let ci = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        if let cg = ciContext.createCGImage(ci, from: ci.extent) {
            cameraImage = UIImage(cgImage: cg)
        }

        if !isAvailable { isAvailable = true }
    }

    // MARK: - Dot Projection (3D direction → 2D screen point)

    /// Project a world-space direction vector to screen coordinates.
    ///
    /// Uses ARCamera.projectPoint to handle all coordinate transforms,
    /// lens distortion, and orientation rotation automatically.
    ///
    /// - Parameters:
    ///   - direction: Unit vector pointing at the capture target.
    ///   - viewportSize: Screen size in points (portrait).
    /// - Returns: Screen CGPoint, or nil if the direction is behind the camera.
    func projectToScreen(direction: simd_float3, viewportSize: CGSize) -> CGPoint? {
        guard let frame = currentFrame else { return nil }

        // Check if direction is in front of the camera (forward hemisphere)
        let alignment = simd_dot(cameraForward, direction)
        guard alignment > 0.0 else { return nil }

        // Place a virtual point 10m away in the target direction from camera position
        let worldPoint = cameraPosition + direction * 10.0

        // ARCamera.projectPoint handles intrinsics + lens model + orientation
        let screenPoint = frame.camera.projectPoint(
            worldPoint,
            orientation: .portrait,
            viewportSize: viewportSize
        )

        // No margin filtering — return raw position; the view model clamps to edges
        return screenPoint
    }

    // MARK: - Photo Capture from ARFrame

    /// Captures a high-resolution JPEG from the current ARFrame pixel buffer.
    func capturePhoto() async throws -> Data {
        guard let frame = session.currentFrame else {
            throw ARCaptureError.noFrame
        }

        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            throw ARCaptureError.conversionFailed
        }

        // High quality JPEG — this is source material for stitching
        guard let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.95) else {
            throw ARCaptureError.encodingFailed
        }
        return data
    }

    // MARK: - HDR Bracket Capture (Professional-Grade)

    /// Captures multiple frames at different exposure bias values for HDR merge.
    ///
    /// Professional bracket capture sequence:
    ///   1. Lock auto-focus and white balance to prevent shifts between frames
    ///   2. For each EV stop: set exposure bias → wait for settle → capture
    ///   3. Verify minimal camera motion between frames (< 1.5° angular change)
    ///   4. Reset exposure bias and unlock focus/WB
    ///
    /// - Parameter evStops: Exposure bias values (default: −2 / 0 / +2 EV).
    /// - Returns: Array of `BracketFrame` for `HDRProcessor.merge()`.
    func captureHDRBracket(evStops: [Float] = [-2.0, 0.0, 2.0]) async throws -> [BracketFrame] {
        guard let device = cameraDevice else {
            throw ARCaptureError.noFrame
        }

        // ── Lock focus + white balance for consistent brackets ──────────
        try device.lockForConfiguration()
        if device.isFocusModeSupported(.locked) {
            device.focusMode = .locked
        }
        if device.isWhiteBalanceModeSupported(.locked) {
            device.whiteBalanceMode = .locked
        }
        device.unlockForConfiguration()

        // Brief settle after locking
        try await Task.sleep(for: .milliseconds(80))

        var frames: [BracketFrame] = []
        var previousCaptureForward: simd_float3?

        for ev in evStops {
            let clamped = max(device.minExposureTargetBias,
                              min(ev, device.maxExposureTargetBias))
            try device.lockForConfiguration()
            await device.setExposureTargetBias(clamped)
            device.unlockForConfiguration()

            // Wait for auto-exposure to settle at the new bias
            try await Task.sleep(for: .milliseconds(Self.bracketSettleMs))

            guard let frame = session.currentFrame else { continue }

            // ── Motion check between bracket frames ─────────────────────
            let currentFwd = simd_normalize(-simd_make_float3(frame.camera.transform.columns.2))
            if let prevFwd = previousCaptureForward {
                let dot = simd_clamp(simd_dot(currentFwd, prevFwd), -1, 1)
                let motionDeg = Double(acos(dot)) * 180.0 / .pi
                if motionDeg > Self.maxBracketMotionDeg {
                    // Too much motion — abort this bracket
                    try? device.lockForConfiguration()
                    await device.setExposureTargetBias(0)
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                        device.whiteBalanceMode = .continuousAutoWhiteBalance
                    }
                    device.unlockForConfiguration()
                    throw ARCaptureError.excessiveMotion
                }
            }
            previousCaptureForward = currentFwd

            let ci = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
            frames.append(BracketFrame(ciImage: ci, ev: ev))
        }

        // ── Reset exposure bias + unlock focus/WB ───────────────────────
        try? device.lockForConfiguration()
        await device.setExposureTargetBias(0)
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        device.unlockForConfiguration()

        return frames
    }
}

// MARK: - ARSessionDelegate

extension ARTrackingManager: ARSessionDelegate {
    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in isAvailable = false }
    }
    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in isAvailable = true }
    }
    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        print("ARSession error: \(error.localizedDescription)")
        Task { @MainActor in isAvailable = false }
    }
}

// MARK: - Errors

enum ARCaptureError: LocalizedError {
    case noFrame, conversionFailed, encodingFailed, excessiveMotion
    var errorDescription: String? {
        switch self {
        case .noFrame:          return "No AR frame available"
        case .conversionFailed: return "Image conversion failed"
        case .encodingFailed:   return "JPEG encoding failed"
        case .excessiveMotion:  return "Too much movement during HDR capture"
        }
    }
}

// MARK: - Live Camera Image (from ARFrame pixel buffer)

/// Displays the live camera feed as a UIImage inside a UIImageView.
/// Unlike ARSCNView, this is **transparent** — the SceneKit globe behind
/// it remains fully visible. The image is extracted from the current
/// ARFrame's capturedImage pixel buffer at 30 fps.
struct CameraFeedView: UIViewRepresentable {
    let image: UIImage?

    func makeUIView(context: Context) -> UIImageView {
        let iv = UIImageView()
        // Fill the framed guide area like the reference capture flow.
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.backgroundColor = .black
        return iv
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        uiView.image = image
    }
}
