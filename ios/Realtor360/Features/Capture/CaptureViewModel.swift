import SwiftUI
import ARKit
import UIKit
import simd

// ─────────────────────────────────────────────────────────────────────────────
// 360° PANORAMA CAPTURE — 16-SHOT METHOD (MAXIMUM POWER)
//
// 16 capture directions covering a full sphere:
//   8 Horizon  (pitch =  0°, yaw = 0°, 45°, 90°, 135°, 180°, 225°, 270°, 315°)
//   4 Upper    (pitch = +35°, yaw = 0°, 90°, 180°, 270°)
//   4 Lower    (pitch = −35°, yaw = 0°, 90°, 180°, 270°)
//
// Camera: iPhone Wide (~70° HFOV, ~55° VFOV) → 30-45% overlap.
//
// Alignment detection:
//   dot(cameraForward, targetDirection) > cos(10°) ≈ 0.9848
//   Lock time: 0.25 s  |  Cooldown: 0.5 s
//
// Enhanced capture gates:
//   • ARKit tracking quality must be .normal
//   • Angular velocity must be < 15°/s (phone nearly still)
//   • Consecutive stable frames required before auto-capture
//   • HDR bracket failure is warned (not silently eaten)
//   • Retry counter per target for quality rejections
//
// Target direction (ARKit world space, −Z = initial forward):
//   x = cos(pitch) × sin(yaw)
//   y = sin(pitch)
//   z = −cos(pitch) × cos(yaw)
//
// Capture pipeline:
//   ARKit tracking → stability gate → alignment → HDR bracket
//   → quality check → preview + float → live globe → stitch → EXR
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - SphereGrid (16 targets, 8 + 4 + 4)

/// 16-target spherical capture grid per specification.
/// Shared by CaptureViewModel, PanoramaStitcher, and UploadViewModel.
enum SphereGrid {
    struct Target {
        let yawDeg: Double          // horizontal rotation 0°–360°
        let pitchDeg: Double        // vertical: +up / −down (0° = horizon)
        let direction: simd_float3  // unit vector in ARKit world space
    }

    /// Unit direction vector from (yaw, pitch) in degrees.
    ///
    /// ARKit world: +Y = up, initial camera forward = −Z.
    ///   x =  cos(pitch) × sin(yaw)
    ///   y =  sin(pitch)
    ///   z = −cos(pitch) × cos(yaw)
    static func unitVector(yawDeg: Double, pitchDeg: Double) -> simd_float3 {
        let y = yawDeg   * .pi / 180.0
        let p = pitchDeg * .pi / 180.0
        return simd_float3(
            Float( cos(p) * sin(y)),
            Float( sin(p)),
            Float(-cos(p) * cos(y))
        )
    }

    static let targets: [Target] = {
        var t: [Target] = []

        // Band 0: 8 Horizon shots — pitch = 0°, yaw = 0° to 315° (45° step)
        for i in 0..<8 {
            let yaw = Double(i) * 45.0
            t.append(Target(yawDeg: yaw, pitchDeg: 0,
                            direction: unitVector(yawDeg: yaw, pitchDeg: 0)))
        }
        // Band 1: 4 Upper shots — pitch = +35°, yaw = 0°, 90°, 180°, 270°
        for i in 0..<4 {
            let yaw = Double(i) * 90.0
            t.append(Target(yawDeg: yaw, pitchDeg: 35,
                            direction: unitVector(yawDeg: yaw, pitchDeg: 35)))
        }
        // Band 2: 4 Lower shots — pitch = −35°, yaw = 0°, 90°, 180°, 270°
        for i in 0..<4 {
            let yaw = Double(i) * 90.0
            t.append(Target(yawDeg: yaw, pitchDeg: -35,
                            direction: unitVector(yawDeg: yaw, pitchDeg: -35)))
        }

        return t
    }()

    static var count: Int { targets.count }  // 16
}

// MARK: - CaptureTarget (mutable per-dot state)

struct CaptureTarget: Identifiable {
    let id: Int
    let yawDeg: Double
    let pitchDeg: Double
    let direction: simd_float3
    var isCaptured: Bool = false
    var retryCount: Int = 0  // track quality rejections
}

struct GuideDot: Identifiable {
    let id: Int
    let screenPoint: CGPoint
    let isActive: Bool
    let isCaptured: Bool
}

struct GuidePointer {
    let screenPoint: CGPoint
    let angleDeg: Double
}

// MARK: - CaptureViewModel

@MainActor
class CaptureViewModel: ObservableObject {

    // ── Spec constants ──────────────────────────────────────────────────────
    /// Slightly wider cone for practical hand-held capture.
    static let alignmentThreshold: Float = cos(14.0 * .pi / 180.0)
    /// Seconds the user must hold alignment before auto-capture fires.
    static let holdDuration: Double = 0.35
    /// Seconds to wait after a capture before allowing the next.
    static let cooldownDuration: Double = 0.2
    /// Maximum quality retries before accepting a lower-quality capture.
    static let maxRetries: Int = 3
    /// Require stable motion before hold starts.
    static let requiredStableFrames: Int = 1
    /// Max angular velocity during alignment/hold.
    static let maxAngularVelocityDegPerSec: Double = 25.0
    static let firstShotEyeLevelToleranceDeg: Double = 10.0
    static let maxPositionDriftMeters: Float = 0.22
    static let captureSequence: [Int] = [0, 2, 8, 6, 12, 1, 3, 4, 5, 7, 9, 10, 11, 13, 14, 15]
    static let firstRingIDs: Set<Int> = [2, 8, 6, 12]
    static let projectedGuideSpread: CGFloat = 1.10
    static let instantCaptureMode: Bool = true

    let nrPhotos: Int = SphereGrid.count  // 16

    // ── Published: targets ──────────────────────────────────────────────────
    @Published var captureTargets: [CaptureTarget] = []
    @Published var capturedThumbnails: [Int: UIImage] = [:]
    @Published var nrPhotosTaken: Int = 0
    @Published var isComplete = false
    @Published private(set) var currentSequenceIndex: Int = 0
    @Published private(set) var positionDriftMeters: Float = 0

    // ── Published: alignment + hold ─────────────────────────────────────────
    @Published var alignedDotId: Int? = nil
    @Published var isWaitingToCapture = false
    @Published var holdProgress: Double = 0
    @Published var takingPicture = false
    @Published var qualityWarning: String? = nil

    // ── Published: tracking ────────────────────────────────────────────────
    @Published var trackingQuality: ARTrackingManager.TrackingQuality = .notAvailable

    // ── ARKit tracking ──────────────────────────────────────────────────────
    let arManager = ARTrackingManager()

    /// HDR mode: true = 3-exposure bracket, false = single JPEG.
    @Published var hdrEnabled = false

    // ── Live Globe ──────────────────────────────────────────────────────────
    let globe = GlobeSceneController()

    // ── Capture data ────────────────────────────────────────────────────────
    var sessionId = UUID().uuidString
    private var capturedImages: [Int: Data] = [:]
    private var capturedHDR: [Int: HDRBracketResult] = [:]

    /// Ordered JPEG previews for upload.
    var capturedImageData: [Data] {
        (0..<nrPhotos).compactMap { capturedImages[$0] }
    }
    /// Ordered HDR float buffers for EXR stitching.
    var capturedHDRData: [HDRBracketResult] {
        (0..<nrPhotos).compactMap { capturedHDR[$0] }
    }

    // ── Hold tracking ───────────────────────────────────────────────────────
    private var holdStartTime: Date?
    private var lastCaptureTime: Date?
    private var stableFrameCount: Int = 0
    private var captureRequestPending = false
    private var firstShotArmed = false
    private var initialForwardDirection: simd_float3?
    private var captureOriginPosition: simd_float3?
    private var captureReferenceYawDeg: Double?

    // MARK: - Lifecycle

    init() { buildTargets() }

    func startCapture() async {
        sessionId = UUID().uuidString
        capturedImages = [:]
        capturedHDR = [:]
        capturedThumbnails = [:]
        nrPhotosTaken = 0
        isComplete = false
        globe.reset()
        buildTargets()
        clearHold()
        stableFrameCount = 0
        captureRequestPending = false
        firstShotArmed = false
        initialForwardDirection = nil
        currentSequenceIndex = 0
        captureOriginPosition = nil
        captureReferenceYawDeg = nil
        positionDriftMeters = 0

        // Place green dots on the 3D globe at each target position
        let dotPositions = captureTargets.map { (id: $0.id, yawDeg: $0.yawDeg, pitchDeg: $0.pitchDeg) }
        globe.addDotNodes(targets: dotPositions)
        globe.setVisibleDotIDs(visibleGlobeDotIDs)

        await arManager.start()
    }

    func stopCapture() {
        arManager.stop()
        clearHold()
    }

    func reset() {
        capturedImages = [:]
        capturedHDR = [:]
        capturedThumbnails = [:]
        nrPhotosTaken = 0
        isComplete = false
        globe.reset()
        buildTargets()
        clearHold()
        stableFrameCount = 0
        captureRequestPending = false
        firstShotArmed = false
        initialForwardDirection = nil
        currentSequenceIndex = 0
        captureOriginPosition = nil
        captureReferenceYawDeg = nil
        positionDriftMeters = 0
    }

    // MARK: - Per-frame update (30 fps, driven by GuidedCaptureView timer)

    func updateFrame() {
        arManager.processCurrentFrame()
        guard arManager.isAvailable else { return }

        trackingQuality = arManager.trackingQuality
        refreshSequenceIndex()
        globe.setVisibleDotIDs(visibleGlobeDotIDs)

        if initialForwardDirection == nil {
            let fwd = arManager.cameraForward
            let len = simd_length(fwd)
            if len > 0.0001 {
                initialForwardDirection = fwd / len
            }
        }

        if isFirstSequenceShot && !firstShotArmed && arManager.angularVelocity > 3.0 {
            // Prevent immediate auto-capture on screen load.
            // User must move once, then align center to register start.
            firstShotArmed = true
        }

        if let origin = captureOriginPosition {
            positionDriftMeters = simd_distance(arManager.cameraPosition, origin)
        } else {
            positionDriftMeters = 0
        }

        if nrPhotosTaken >= nrPhotos {
            markCompleteIfNeeded()
            return
        }

        // ── Cooldown after capture ──────────────────────────────────────
        if let last = lastCaptureTime,
           Date().timeIntervalSince(last) < Self.cooldownDuration {
            alignedDotId = nil
            holdProgress = 0
            isWaitingToCapture = false
            captureRequestPending = false
            globe.updateRingProgress(alignedId: nil, progress: 0)
            return
        }

        // ── Teleport-style deterministic target order ───────────────────
        // Always guide/capture the next uncaptured target in sequence.
        guard let activeId = activeGuideTargetID else { return }
        guard let activeDirection = worldDirection(for: activeId) else { return }

        let forward = simd_normalize(arManager.cameraForward)
        let alignment = simd_dot(forward, simd_normalize(activeDirection))
        let isDirectionAligned = alignment > Self.alignmentThreshold
        let isEyeLevelValid = !isFirstSequenceShot || isFirstShotEyeLevelValid
        let isFirstShotCaptureReady = !isFirstSequenceShot || firstShotArmed
        let isCaptureEligible = isDirectionAligned && captureGatesReady && isFirstShotCaptureReady && !takingPicture

        if isCaptureEligible {
            stableFrameCount += 1
        } else {
            stableFrameCount = 0
        }

        // ── Hold timer management ───────────────────────────────────────
        let previousAlignedId = alignedDotId
        alignedDotId = (isDirectionAligned && isEyeLevelValid) ? activeId : nil

        if !isCaptureEligible || stableFrameCount < Self.requiredStableFrames || previousAlignedId != alignedDotId {
            if holdStartTime != nil { clearHold() }
            globe.updateRingProgress(alignedId: nil, progress: 0)
        }

        if isCaptureEligible && stableFrameCount >= Self.requiredStableFrames {
            if Self.instantCaptureMode {
                holdProgress = 1.0
                globe.updateRingProgress(alignedId: alignedDotId, progress: 1.0)
                if !captureRequestPending && !takingPicture {
                    captureRequestPending = true
                    Task { await capturePhoto(for: activeId) }
                }
                return
            }

            if holdStartTime == nil {
                holdStartTime = Date()
                isWaitingToCapture = true
                HapticManager.light()
            }
            holdProgress = min(1.0, Date().timeIntervalSince(holdStartTime!) / Self.holdDuration)

            // Update 3D ring animation on the globe
            globe.updateRingProgress(alignedId: alignedDotId, progress: CGFloat(holdProgress))

            if holdProgress >= 1.0 && !takingPicture {
                Task { await capturePhoto(for: activeId) }
            }
        }

    }

    /// Lightweight frame update for the completion globe phase.
    /// Keeps processing ARKit frames so orientation tracking continues
    /// and the globe camera follows the user's gaze.
    func updateOrientationOnly() {
        arManager.processCurrentFrame()
    }

    // MARK: - Photo Capture (Enhanced)

    private func capturePhoto(for dotId: Int) async {
        defer { captureRequestPending = false }
        guard dotId < captureTargets.count, !captureTargets[dotId].isCaptured, !takingPicture else { return }
        guard dotId == activeGuideTargetID else { return }
        guard alignedDotId == dotId else { return }
        guard !isFirstSequenceShot || isFirstShotEyeLevelValid else { return }
        takingPicture = true

        do {
            let previewData: Data

            // ── HDR bracket via ARKit camera device exposure control ────
            var hdrResult: HDRBracketResult?
            if hdrEnabled {
                do {
                    let frames = try await arManager.captureHDRBracket()
                    hdrResult = HDRProcessor.merge(frames: frames)
                    if hdrResult == nil {
                        qualityWarning = "HDR fusion failed — using single exposure"
                        HapticManager.light()
                        clearWarningAfterDelay("HDR fusion failed — using single exposure")
                    }
                } catch let error as ARCaptureError where error == .excessiveMotion {
                    qualityWarning = "Hold still during HDR capture"
                    HapticManager.error()
                    clearWarningAfterDelay("Hold still during HDR capture")
                    takingPicture = false
                    clearHold()
                    stableFrameCount = 0
                    return
                } catch {
                    qualityWarning = "HDR failed — using single exposure"
                    HapticManager.light()
                    clearWarningAfterDelay("HDR failed — using single exposure")
                }
            }
            if let hdr = hdrResult {
                capturedHDR[dotId] = hdr
                previewData = hdr.previewJPEG
            } else {
                previewData = try await arManager.capturePhoto()
            }

            // ── Quality check (blur + brightness + overexposure) ────────
            let quality = await QualityChecker.analyze(previewData)
            let retryCount = captureTargets[dotId].retryCount

            // Allow lower quality after maxRetries to avoid stuck targets
            let strictCheck = retryCount < Self.maxRetries

            if strictCheck && (quality.isBlurry || quality.isDark || quality.isOverexposed) {
                var warnings: [String] = []
                if quality.isBlurry { warnings.append("blurry") }
                if quality.isDark { warnings.append("too dark") }
                if quality.isOverexposed { warnings.append("overexposed") }
                let warning = "Photo \(warnings.joined(separator: " & ")) — try again (\(retryCount + 1)/\(Self.maxRetries))"
                qualityWarning = warning
                HapticManager.error()
                clearWarningAfterDelay(warning)
                captureTargets[dotId].retryCount += 1
                takingPicture = false
                capturedHDR.removeValue(forKey: dotId)
                clearHold()
                stableFrameCount = 0
                return
            }

            // ── Store + update state ────────────────────────────────────
            capturedImages[dotId] = previewData
            if let img = UIImage(data: previewData) {
                capturedThumbnails[dotId] = img
            }
            captureTargets[dotId].isCaptured = true
            if captureReferenceYawDeg == nil {
                // First accepted center shot becomes the orientation reference.
                captureReferenceYawDeg = cameraYawDeg
            }
            if captureOriginPosition == nil {
                captureOriginPosition = arManager.cameraPosition
            }
            nrPhotosTaken += 1
            refreshSequenceIndex()
            globe.setVisibleDotIDs(visibleGlobeDotIDs)

            // Place photo on the live globe + mark dot as captured on sphere
            let t = captureTargets[dotId]
            globe.addPhoto(imageData: previewData,
                           yawDeg: t.yawDeg,
                           elevationDeg: t.pitchDeg)
            globe.markDotCaptured(id: dotId)

            FileHelper.saveCapture(previewData, sessionId: sessionId, step: dotId + 1)
            HapticManager.success()
        } catch {
            print("Capture error: \(error)")
            qualityWarning = "Capture failed — try again"
            HapticManager.error()
            clearWarningAfterDelay("Capture failed — try again")
        }

        lastCaptureTime = Date()
        clearHold()
        stableFrameCount = 0
        takingPicture = false
    }

    // MARK: - Direction Hint (camera-local space)

    /// HUD hint pointing toward the next uncaptured target.
    var directionHint: String? {
        if !trackingQuality.isGoodForCapture {
            return "Move slowly to initialize tracking"
        }
        if arManager.angularVelocity > Self.maxAngularVelocityDegPerSec {
            return "Hold still"
        }
        if !isPositionWithinTolerance {
            return "Return to capture spot"
        }
        if isFirstSequenceShot && !firstShotArmed {
            return "Move phone slightly, then align center"
        }
        if isFirstSequenceShot && !isFirstShotEyeLevelValid {
            return "Hold phone at eye level"
        }

        guard let activeId = activeGuideTargetID,
              let nextDirection = worldDirection(for: activeId) else { return nil }

        let forward = simd_normalize(arManager.cameraForward)

        // If already close, no hint needed
        if simd_dot(forward, nextDirection) > Self.alignmentThreshold { return nil }

        // Transform target direction into camera local space
        let invTransform = arManager.cameraTransform.inverse
        let worldDir = simd_float4(nextDirection.x,
                                   nextDirection.y,
                                   nextDirection.z, 0)
        let localDir = invTransform * worldDir
        let local = simd_make_float3(localDir)

        // local.x > 0 → target is to the right
        // local.y > 0 → target is above
        if abs(local.x) > abs(local.y) {
            return local.x > 0 ? "Turn right →" : "← Turn left"
        }
        return local.y > 0 ? "Look up ↑" : "Look down ↓"
    }

    /// Band label for the next uncaptured target.
    var currentBandLabel: String? {
        guard let activeId = activeGuideTargetID else { return nil }
        let next = captureTargets[activeId]
        switch next.pitchDeg {
        case 20...:    return "Upper"
        case -20..<20: return "Horizon"
        default:       return "Lower"
        }
    }

    var isFirstShotEyeLevelValid: Bool {
        abs(cameraPitchDeg) <= Self.firstShotEyeLevelToleranceDeg
    }

    var isPositionWithinTolerance: Bool {
        guard captureOriginPosition != nil else { return true }
        return positionDriftMeters <= Self.maxPositionDriftMeters
    }

    var captureGatesReady: Bool {
        trackingQuality.isGoodForCapture &&
            arManager.angularVelocity <= Self.maxAngularVelocityDegPerSec &&
            isPositionWithinTolerance &&
            (!isFirstSequenceShot || isFirstShotEyeLevelValid)
    }

    var needsFirstShotArming: Bool {
        isFirstSequenceShot && !firstShotArmed
    }

    var activeGuideTargetID: Int? {
        guard currentSequenceIndex < Self.captureSequence.count else { return nil }
        let id = Self.captureSequence[currentSequenceIndex]
        guard captureTargets.indices.contains(id), !captureTargets[id].isCaptured else { return nil }
        return id
    }

    var visibleGuideTargetIDs: [Int] {
        if nrPhotosTaken == 0 { return [0] }

        let pending = Self.captureSequence[currentSequenceIndex...]
            .filter { captureTargets.indices.contains($0) && !captureTargets[$0].isCaptured }

        return Array(pending.prefix(4))
    }

    private var visibleGlobeDotIDs: Set<Int> {
        // Use 2D frame guidance only; keep globe dots hidden for cleaner UX.
        []
    }

    func guideDots(for viewportSize: CGSize) -> [GuideDot] {
        let activeId = activeGuideTargetID
        let horizontalInset: CGFloat = 8
        let verticalInset: CGFloat = 8
        let center = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        let minRadius = min(viewportSize.width, viewportSize.height) * 0.24

        // First ring after center capture: force cardinal edge dots for cleaner UX.
        if nrPhotosTaken > 0 && currentSequenceIndex <= 4 {
            return visibleGuideTargetIDs.compactMap { id in
                guard captureTargets.indices.contains(id),
                      let point = firstRingPoint(for: id, viewportSize: viewportSize) else {
                    return nil
                }
                return GuideDot(
                    id: id,
                    screenPoint: point,
                    isActive: id == activeId,
                    isCaptured: captureTargets[id].isCaptured
                )
            }
        }

        return visibleGuideTargetIDs.compactMap { id in
            guard captureTargets.indices.contains(id) else { return nil }
            guard let direction = worldDirection(for: id),
                  let projected = arManager.projectToScreen(direction: direction, viewportSize: viewportSize) else {
                return nil
            }

            // Push projected points outward so post-anchor dots sit near frame edges.
            let dx = projected.x - center.x
            let dy = projected.y - center.y
            let distance = hypot(dx, dy)
            let unitX = distance > 0.001 ? dx / distance : 0
            let unitY = distance > 0.001 ? dy / distance : 0

            var guidedDistance = distance * Self.projectedGuideSpread
            if nrPhotosTaken > 0 {
                guidedDistance = max(guidedDistance, minRadius)
            }

            let guided = CGPoint(
                x: center.x + unitX * guidedDistance,
                y: center.y + unitY * guidedDistance
            )

            let clampedX = min(max(guided.x, horizontalInset), viewportSize.width - horizontalInset)
            let clampedY = min(max(guided.y, verticalInset), viewportSize.height - verticalInset)
            return GuideDot(
                id: id,
                screenPoint: CGPoint(x: clampedX, y: clampedY),
                isActive: id == activeId,
                isCaptured: captureTargets[id].isCaptured
            )
        }
    }

    private func firstRingPoint(for id: Int, viewportSize: CGSize) -> CGPoint? {
        guard Self.firstRingIDs.contains(id) else { return nil }
        let w = viewportSize.width
        let h = viewportSize.height

        switch id {
        case 2:  return CGPoint(x: w,      y: h * 0.5)  // right
        case 8:  return CGPoint(x: w * 0.5, y: 0)       // top
        case 6:  return CGPoint(x: 0,      y: h * 0.5)  // left
        case 12: return CGPoint(x: w * 0.5, y: h)       // bottom
        default: return nil
        }
    }

    func activeGuidePointer(for viewportSize: CGSize) -> GuidePointer? {
        guard nrPhotosTaken > 0 else { return nil }
        guard let activeId = activeGuideTargetID else { return nil }
        guard !guideDots(for: viewportSize).contains(where: { $0.id == activeId }) else { return nil }
        guard captureTargets.indices.contains(activeId) else { return nil }

        guard let direction = worldDirection(for: activeId) else { return nil }
        let invTransform = arManager.cameraTransform.inverse
        let worldDir = simd_float4(direction.x, direction.y, direction.z, 0)
        let localDir4 = invTransform * worldDir
        let localDir = simd_make_float3(localDir4)

        var v = CGVector(dx: CGFloat(localDir.x), dy: CGFloat(-localDir.y))
        let mag = max(0.001, sqrt(v.dx * v.dx + v.dy * v.dy))
        v.dx /= mag
        v.dy /= mag

        let center = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        let radius = min(viewportSize.width, viewportSize.height) * 0.40
        let point = CGPoint(x: center.x + v.dx * radius, y: center.y + v.dy * radius)
        let angle = atan2(v.dy, v.dx) * 180.0 / .pi
        return GuidePointer(screenPoint: point, angleDeg: angle)
    }

    var nextShotText: String {
        let nextNumber = min(nrPhotosTaken + 1, nrPhotos)
        if let band = currentBandLabel {
            return "Shot \(nextNumber) of \(nrPhotos) • \(band)"
        }
        return "Shot \(nextNumber) of \(nrPhotos)"
    }

    // MARK: - Camera orientation for LiveGlobeView (derived from forward vector)

    /// Yaw in degrees (0–360, clockwise from start) for the live globe camera.
    var cameraYawDeg: Double {
        let f = arManager.cameraForward
        var yaw = atan2(Double(f.x), Double(-f.z)) * 180.0 / .pi
        if yaw < 0 { yaw += 360 }
        return yaw
    }

    /// Pitch in degrees (0 = horizon, + = up, − = down) for the live globe camera.
    var cameraPitchDeg: Double {
        return asin(Double(arManager.cameraForward.y)) * 180.0 / .pi
    }

    // MARK: - Helpers

    private func buildTargets() {
        captureTargets = SphereGrid.targets.enumerated().map { i, t in
            CaptureTarget(id: i, yawDeg: t.yawDeg, pitchDeg: t.pitchDeg,
                          direction: t.direction)
        }
    }

    private var isFirstSequenceShot: Bool {
        currentSequenceIndex == 0
    }

    private func refreshSequenceIndex() {
        while currentSequenceIndex < Self.captureSequence.count {
            let id = Self.captureSequence[currentSequenceIndex]
            if captureTargets.indices.contains(id), captureTargets[id].isCaptured {
                currentSequenceIndex += 1
            } else {
                break
            }
        }
    }

    /// World-space direction used for guidance/alignment.
    /// Before first capture, target 0 follows live camera forward so
    /// the center circle always represents the starting-point registration.
    private func worldDirection(for targetId: Int) -> simd_float3? {
        guard captureTargets.indices.contains(targetId) else { return nil }

        if captureReferenceYawDeg == nil, targetId == 0 {
            let fwd = initialForwardDirection ?? arManager.cameraForward
            let len = simd_length(fwd)
            if len > 0.0001 {
                return fwd / len
            }
            return simd_float3(0, 0, -1)
        }

        let local = captureTargets[targetId].direction
        guard let yaw = captureReferenceYawDeg else { return local }
        return rotatedAroundWorldY(local, yawDeg: yaw)
    }

    private func rotatedAroundWorldY(_ vector: simd_float3, yawDeg: Double) -> simd_float3 {
        let r = Float(yawDeg * .pi / 180.0)
        let c = cos(r)
        let s = sin(r)
        let rotated = simd_float3(
            vector.x * c - vector.z * s,
            vector.y,
            vector.x * s + vector.z * c
        )
        return simd_normalize(rotated)
    }

    private func markCompleteIfNeeded() {
        guard !isComplete else { return }
        isComplete = true
        HapticManager.success()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            HapticManager.success()
        }
        // Keep AR running so user can look around completed globe.
    }

    private func clearHold() {
        holdStartTime = nil
        holdProgress = 0
        isWaitingToCapture = false
    }

    /// Clear a quality warning after 2.5 seconds if it hasn't been replaced.
    private func clearWarningAfterDelay(_ message: String) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if qualityWarning == message { qualityWarning = nil }
        }
    }
}
