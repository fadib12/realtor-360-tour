import ARKit
import SceneKit
import SwiftUI
@preconcurrency import AVFoundation
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

    // ── Optical consistency gates ──────────────────────────────────────────
    /// True when ARKit is using a wide-angle format for primary capture.
    @Published private(set) var isWideLensActive: Bool = false
    /// True when zoom factor remains at the required 1.0x.
    @Published private(set) var isZoomValid: Bool = false
    /// True when AR intrinsics/resolution stayed stable since start.
    @Published private(set) var isFormatStable: Bool = false
    /// True when focus/exposure are not currently adjusting.
    @Published private(set) var isAutoFocusExposureSettled: Bool = false
    /// Aggregate quality gate for deterministic spherical capture.
    @Published private(set) var opticsReady: Bool = false
    /// Portrait-mode horizontal FOV in radians, derived from camera intrinsics.
    @Published private(set) var portraitHFOVRadians: Float = Float(70.0 * Double.pi / 180.0)
    /// Portrait-mode vertical FOV in radians, derived from camera intrinsics.
    @Published private(set) var portraitVFOVRadians: Float = Float(87.0 * Double.pi / 180.0)
    /// Human-readable label for the selected camera lens.
    @Published private(set) var selectedLensLabel: String = "—"
    /// ARKit camera (wide) FOV — used for live sphere texture warping.
    @Published private(set) var arkitPortraitHFOV: Float = Float(55.0 * Double.pi / 180.0)
    @Published private(set) var arkitPortraitVFOV: Float = Float(73.0 * Double.pi / 180.0)

    enum TrackingQuality: Equatable {
        case normal
        case limited(reason: String)
        case notAvailable

        var isGoodForCapture: Bool {
            switch self {
            case .normal: return true
            case .limited(let reason): return reason != "Initializing"
            case .notAvailable: return false
            }
        }

        var displayLabel: String {
            switch self {
            case .normal:           return "Tracking: Good"
            case .limited(let r):   return "Tracking: \(r)"
            case .notAvailable:     return "Tracking: Unavailable"
            }
        }
    }

    struct ProjectedWorldPoint {
        let point: CGPoint
        let isInFront: Bool
        let isOnScreen: Bool
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
    /// Whether camera exposure/focus/WB have been locked for consistent captures.
    private(set) var cameraLocked = false
    /// Device type of the AR video format selected when the session starts.
    private var selectedCaptureDeviceType: AVCaptureDevice.DeviceType?
    /// Lens type required for the whole scan once selected at session start.
    private var requiredCaptureDeviceType: AVCaptureDevice.DeviceType?
    /// Baseline camera image resolution for format stability enforcement.
    private var expectedImageResolution: CGSize?
    /// Baseline focal intrinsics for format stability checks.
    private var expectedIntrinsics: simd_float3x3?

    // ── Ultra-wide camera session (parallel to ARKit) ───────────────────────
    /// AVCaptureSession using the ultra-wide camera for preview and capture.
    /// ARKit continues running with the wide camera for pose tracking only.
    private(set) var ultraWideSession: AVCaptureSession?
    private var ultraWidePhotoOutput: AVCapturePhotoOutput?
    private var ultraWideDevice: AVCaptureDevice?
    private let ultraWideQueue = DispatchQueue(label: "com.realtor360.ultrawide")
    private var photoCaptureDelegate: UltraWidePhotoCaptureDelegate?
    /// True when the ultra-wide session is active (use preview layer instead of cameraImage).
    @Published private(set) var hasUltraWideSession: Bool = false

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
        config.worldAlignment = .gravity

        let formats = ARWorldTrackingConfiguration.supportedVideoFormats

        print("[ARTrackingManager] Available ARKit video formats:")
        for (i, f) in formats.enumerated() {
            print("  [\(i)] \(f.captureDeviceType.rawValue) \(f.imageResolution.width)x\(f.imageResolution.height)")
        }

        let ultraWide = formats
            .filter { $0.captureDeviceType == .builtInUltraWideCamera }
            .sorted { $0.imageResolution.width > $1.imageResolution.width }

        let wide = formats
            .filter { $0.captureDeviceType == .builtInWideAngleCamera }
            .sorted { $0.imageResolution.width > $1.imageResolution.width }

        if let selected = ultraWide.first ?? wide.first ?? formats.first {
            config.videoFormat = selected
            selectedCaptureDeviceType = selected.captureDeviceType
            requiredCaptureDeviceType = selected.captureDeviceType
            selectedLensLabel = selected.captureDeviceType == .builtInUltraWideCamera
                ? "Ultra Wide" : "Wide"
            print("[ARTrackingManager] SELECTED: \(selected.captureDeviceType.rawValue) \(selected.imageResolution)")
        } else {
            selectedCaptureDeviceType = nil
            requiredCaptureDeviceType = nil
            selectedLensLabel = "Unknown"
            print("[ARTrackingManager] No video format available")
        }

        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])

        // Cache AVCaptureDevice for HDR exposure bias + focus/WB control
        cameraDevice = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera
        cameraLocked = false
        expectedImageResolution = nil
        expectedIntrinsics = nil

        previousForward = nil
        previousFrameTime = nil

        // Hard pin zoom to 1.0 for consistent optics.
        if let device = cameraDevice {
            do {
                try device.lockForConfiguration()
                let clamped = max(1.0, min(1.0, device.activeFormat.videoMaxZoomFactor))
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
            } catch {
                print("Failed to force zoom factor: \(error)")
            }
        }

        isWideLensActive = true
        isZoomValid = false
        isFormatStable = false
        isAutoFocusExposureSettled = false
        opticsReady = false

        // ── Start the ultra-wide camera session in parallel ─────────────
        setupUltraWideSession()
    }

    /// Sets up a separate AVCaptureSession using the ultra-wide camera.
    /// ARKit keeps the wide camera for tracking; the ultra-wide is free.
    private func setupUltraWideSession() {
        guard let device = AVCaptureDevice.default(
            .builtInUltraWideCamera, for: .video, position: .back
        ) else {
            print("[ARTrackingManager] Ultra-wide camera not available on this device")
            return
        }

        let avSession = AVCaptureSession()
        avSession.sessionPreset = .photo

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard avSession.canAddInput(input) else {
                print("[ARTrackingManager] Cannot add ultra-wide input")
                return
            }
            avSession.addInput(input)

            let photoOutput = AVCapturePhotoOutput()
            guard avSession.canAddOutput(photoOutput) else {
                print("[ARTrackingManager] Cannot add photo output")
                return
            }
            avSession.addOutput(photoOutput)

            self.ultraWideDevice = device
            self.ultraWidePhotoOutput = photoOutput
            self.ultraWideSession = avSession
            self.hasUltraWideSession = true

            // Derive FOV from the ultra-wide camera's active format
            let landscapeHFOVDeg = Double(device.activeFormat.videoFieldOfView)
            let formatDesc = device.activeFormat.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(formatDesc)
            let sensorW = Double(dims.width)
            let sensorH = Double(dims.height)

            if sensorW > 0 && sensorH > 0 && landscapeHFOVDeg > 0 {
                let tanHalfLandH = tan(landscapeHFOVDeg / 2 * .pi / 180)
                let landscapeVFOVRad = 2 * atan(tanHalfLandH * sensorH / sensorW)
                // Portrait: rotate 90° → sensor H becomes screen W, sensor W becomes screen H
                portraitHFOVRadians = Float(landscapeVFOVRad)
                portraitVFOVRadians = Float(landscapeHFOVDeg * .pi / 180)
                print("[ARTrackingManager] Ultra-wide FOV — portrait H: \(portraitHFOVRadians * 180 / .pi)° V: \(portraitVFOVRadians * 180 / .pi)°")
            }

            selectedLensLabel = "Ultra Wide"
            print("[ARTrackingManager] Ultra-wide session configured: \(Int(sensorW))x\(Int(sensorH)) landscapeHFOV=\(landscapeHFOVDeg)°")

            // Start on background thread (startRunning blocks)
            ultraWideQueue.async { [weak avSession] in
                avSession?.startRunning()
            }
        } catch {
            print("[ARTrackingManager] Ultra-wide setup error: \(error)")
        }
    }

    /// Lock exposure, focus, and white balance for consistent captures.
    /// Call after the first successful capture so all subsequent photos
    /// have matching color/brightness.
    func lockCameraSettings() {
        guard let device = cameraDevice, !cameraLocked else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.locked) {
                device.focusMode = .locked
            }
            if device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
            }
            if device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
            }
            device.unlockForConfiguration()
            cameraLocked = true
        } catch {
            print("Failed to lock camera settings: \(error)")
        }
    }

    /// Unlock camera settings (call on stop/reset).
    func unlockCameraSettings() {
        guard let device = cameraDevice, cameraLocked else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
            cameraLocked = false
        } catch {
            print("Failed to unlock camera settings: \(error)")
        }
    }

    func stop() {
        unlockCameraSettings()
        session.pause()

        // Stop ultra-wide session
        if let uwSession = ultraWideSession {
            let q = ultraWideQueue
            q.async { uwSession.stopRunning() }
        }
        ultraWideSession = nil
        ultraWidePhotoOutput = nil
        ultraWideDevice = nil
        hasUltraWideSession = false
        photoCaptureDelegate = nil

        isAvailable = false
        currentFrame = nil
        cameraDevice = nil
        previousForward = nil
        previousFrameTime = nil
        trackingQuality = .notAvailable
        angularVelocity = 0
        selectedCaptureDeviceType = nil
        requiredCaptureDeviceType = nil
        expectedImageResolution = nil
        expectedIntrinsics = nil
        isWideLensActive = false
        isZoomValid = false
        isFormatStable = false
        isAutoFocusExposureSettled = false
        opticsReady = false
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

        // ── Live camera image from ARKit pixel buffer (always needed for sphere texture) ──
        let ci = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        if let cg = ciContext.createCGImage(ci, from: ci.extent) {
            cameraImage = UIImage(cgImage: cg)
        }

        // ── Optical consistency gates ───────────────────────────────────
        let resolution = frame.camera.imageResolution
        let currentSize = CGSize(width: resolution.width, height: resolution.height)
        if expectedImageResolution == nil {
            expectedImageResolution = currentSize
            expectedIntrinsics = frame.camera.intrinsics
            isFormatStable = true

            // Derive portrait FOV from intrinsics.
            // Sensor is landscape (W>H). In portrait orientation:
            //   portrait width  = sensor height → HFOV uses fy and sensor height
            //   portrait height = sensor width  → VFOV uses fx and sensor width
            let fx = frame.camera.intrinsics[0, 0]
            let fy = frame.camera.intrinsics[1, 1]
            let sensorW = Float(resolution.width)
            let sensorH = Float(resolution.height)
            if fy > 0 {
                let hfov = 2 * atan(sensorH / (2 * fy))
                arkitPortraitHFOV = hfov
                if !hasUltraWideSession { portraitHFOVRadians = hfov }
            }
            if fx > 0 {
                let vfov = 2 * atan(sensorW / (2 * fx))
                arkitPortraitVFOV = vfov
                if !hasUltraWideSession { portraitVFOVRadians = vfov }
            }
        } else if let expectedResolution = expectedImageResolution,
                  let expectedIntrinsics = expectedIntrinsics {
            let resolutionStable = abs(currentSize.width - expectedResolution.width) < 0.5
                && abs(currentSize.height - expectedResolution.height) < 0.5

            let intrinsics = frame.camera.intrinsics
            let fxStable = abs(intrinsics[0, 0] - expectedIntrinsics[0, 0]) < 0.5
            let fyStable = abs(intrinsics[1, 1] - expectedIntrinsics[1, 1]) < 0.5

            isFormatStable = resolutionStable && fxStable && fyStable
        } else {
            isFormatStable = false
        }

        if let requiredCaptureDeviceType {
            if let device = cameraDevice {
                isWideLensActive = device.deviceType == requiredCaptureDeviceType
            } else {
                isWideLensActive = selectedCaptureDeviceType == requiredCaptureDeviceType
            }
        } else {
            isWideLensActive = selectedCaptureDeviceType != nil
        }

        if let device = cameraDevice {
            isZoomValid = abs(device.videoZoomFactor - 1.0) <= 0.01
            isAutoFocusExposureSettled = !device.isAdjustingFocus && !device.isAdjustingExposure
            opticsReady = isWideLensActive && isZoomValid && isFormatStable && isAutoFocusExposureSettled
        } else {
            // Some devices/configurations do not expose configurableCaptureDeviceForPrimaryCamera.
            // In that case, enforce only the gates ARKit can reliably provide.
            isZoomValid = true
            isAutoFocusExposureSettled = true
            opticsReady = isWideLensActive && isFormatStable
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
        let worldPoint = cameraPosition + direction * 10.0
        return projectWorldPoint(worldPoint, viewportSize: viewportSize)?.point
    }

    func projectWorldPoint(
        _ worldPoint: simd_float3,
        viewportSize: CGSize,
        orientation: UIInterfaceOrientation = .portrait
    ) -> ProjectedWorldPoint? {
        guard let frame = currentFrame else { return nil }

        let projected = frame.camera.projectPoint(
            worldPoint,
            orientation: orientation,
            viewportSize: viewportSize
        )

        let screenPoint = CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
        let delta = worldPoint - cameraPosition
        let isInFront: Bool
        if simd_length_squared(delta) < 1e-7 {
            isInFront = true
        } else {
            isInFront = simd_dot(cameraForward, simd_normalize(delta)) > 0
        }

        let isOnScreen = screenPoint.x >= 0
            && screenPoint.x <= viewportSize.width
            && screenPoint.y >= 0
            && screenPoint.y <= viewportSize.height

        return ProjectedWorldPoint(
            point: screenPoint,
            isInFront: isInFront,
            isOnScreen: isOnScreen
        )
    }

    // MARK: - Photo Capture

    /// Captures a high-resolution JPEG. Prefers the ultra-wide AVCaptureSession
    /// when available; falls back to ARFrame pixel buffer otherwise.
    func capturePhoto() async throws -> Data {
        if let photoOutput = ultraWidePhotoOutput {
            do {
                return try await captureFromUltraWide(photoOutput)
            } catch {
                print("[ARTrackingManager] Ultra-wide capture failed: \(error), falling back to ARFrame")
            }
        }
        return try captureFromARFrame()
    }

    private func captureFromARFrame() throws -> Data {
        guard let frame = session.currentFrame else {
            throw ARCaptureError.noFrame
        }
        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            throw ARCaptureError.conversionFailed
        }
        guard let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.95) else {
            throw ARCaptureError.encodingFailed
        }
        return data
    }

    private func captureFromUltraWide(_ photoOutput: AVCapturePhotoOutput) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            let settings = AVCapturePhotoSettings()
            settings.flashMode = .off
            let delegate = UltraWidePhotoCaptureDelegate(continuation: continuation)
            self.photoCaptureDelegate = delegate
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
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

// MARK: - Ultra-Wide Camera Preview (AVCaptureVideoPreviewLayer)

/// Hardware-accelerated live preview from the ultra-wide AVCaptureSession.
/// Uses AVCaptureVideoPreviewLayer for zero-copy GPU rendering.
struct UltraWideCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> UltraWidePreviewUIView {
        let view = UltraWidePreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UltraWidePreviewUIView, context: Context) {
        uiView.previewLayer.session = session
    }

    class UltraWidePreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

// MARK: - Fallback Camera Feed (from ARFrame pixel buffer)

struct CameraFeedView: UIViewRepresentable {
    let image: UIImage?

    func makeUIView(context: Context) -> UIImageView {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.clipsToBounds = true
        iv.backgroundColor = .clear
        return iv
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        uiView.image = image
    }
}

// MARK: - Ultra-Wide Photo Capture Delegate

/// Bridges AVCapturePhotoOutput's delegate callback to async/await.
class UltraWidePhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let continuation: CheckedContinuation<Data, Error>

    init(continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
        super.init()
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            continuation.resume(throwing: error)
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            continuation.resume(throwing: ARCaptureError.encodingFailed)
            return
        }
        continuation.resume(returning: data)
    }
}
