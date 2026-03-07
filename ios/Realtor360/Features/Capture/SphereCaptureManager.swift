import Foundation
import ARKit
import UIKit
import simd

@MainActor
final class SphereCaptureManager: ObservableObject {

    struct Config {
        var translationThreshold: Float = 0.08
        var idealTranslation: Float = 0.04
        var angleToleranceDeg: Double = 12.0
        var perfectAngleDeg: Double = 6.0
        var stableHoldDuration: TimeInterval = 0.3
        /// Max angular velocity (deg/sec) to count as "stable" for the hold timer.
        var maxStableAngularVelocity: Double = 15.0
        var projectionDistance: Float = 1.0
        var centerCaptureRadius: CGFloat = 60.0
        var zoomFactor: CGFloat = 1.0
        var totalTargets: Int = 16
    }

    struct Target: Identifiable {
        let id: Int
        let yawDeg: Double
        let pitchDeg: Double
        let direction: simd_float3
    }

    enum ScannerState: String, Codable {
        case idle
        case initializingTracking
        case ready
        case waitingForAlignment
        case alignedHolding
        case capturing
        case photoAccepted
        case errorTrackingLimited
        case errorUserMoved
        case completed
    }

    struct CoverageState: Codable {
        let targetVisited: [Bool]
        let coverageFraction: Double
        let visitedTargets: [Int]
        let remainingTargets: [Int]
    }

    @Published private(set) var scannerState: ScannerState = .idle
    @Published private(set) var currentTargetIndex: Int = 0
    @Published private(set) var progress: Double = 0

    @Published private(set) var currentTargetYaw: Double = 0
    @Published private(set) var currentTargetPitch: Double = 0
    @Published private(set) var liveYaw: Double = 0
    @Published private(set) var livePitch: Double = 0
    @Published private(set) var yawError: Double = 0
    @Published private(set) var pitchError: Double = 0
    @Published private(set) var angleErrorDeg: Double = 180

    @Published private(set) var translationErrorMeters: Float = 0
    @Published private(set) var targetScreenPoint: CGPoint = .zero
    @Published private(set) var isTargetOffScreen: Bool = false
    @Published private(set) var isTargetInFront: Bool = false
    @Published private(set) var screenDistance: CGFloat = .greatestFiniteMagnitude

    @Published private(set) var isPositionValid: Bool = false
    @Published private(set) var isAngleValid: Bool = false
    @Published private(set) var isScreenAligned: Bool = false
    @Published private(set) var holdProgress: Double = 0
    @Published private(set) var canCapture: Bool = false

    @Published private(set) var warningUserMoved: Bool = false
    @Published private(set) var warningTrackingLimited: Bool = true
    @Published private(set) var scanCompleted: Bool = false

    @Published private(set) var targetVisited: [Bool]
    @Published private(set) var coverageFraction: Double = 0

    let config: Config
    let targets: [Target]
    let orderedTargetIDs: [Int]
    let totalTargets: Int

    var activeTargetID: Int? {
        guard !scanCompleted, currentTargetIndex < orderedTargetIDs.count else { return nil }
        return orderedTargetIDs[currentTargetIndex]
    }

    var photoMetadata: [SphereCapturePhotoMetadata] { capturedMetadata }

    var visitedTargets: [Int] {
        targetVisited.enumerated().compactMap { idx, visited in
            visited ? idx : nil
        }
    }

    var remainingTargets: [Int] {
        targetVisited.enumerated().compactMap { idx, visited in
            visited ? nil : idx
        }
    }

    var currentCoverageMapState: CoverageState {
        CoverageState(
            targetVisited: targetVisited,
            coverageFraction: coverageFraction,
            visitedTargets: visitedTargets,
            remainingTargets: remainingTargets
        )
    }

    var targetPoint3D: simd_float3? {
        guard let id = activeTargetID else { return nil }
        return targetPoint3D(for: id)
    }

    private(set) var originPosition: simd_float3?
    private var referenceYawDeg: Double?
    private var stableTime: TimeInterval = 0
    private var lastFrameTimestamp: TimeInterval?
    private(set) var holdDurationUsedForCapture: TimeInterval = 0
    private var pendingCaptureTargetID: Int?
    /// True from when a capture is triggered until the photo is accepted.
    private(set) var captureInFlight: Bool = false
    private var capturedMetadata: [SphereCapturePhotoMetadata] = []

    init(config: Config = Config(), targetOrder: [Int]? = nil) {
        self.config = config
        self.targets = Self.defaultTargets()
        self.totalTargets = config.totalTargets
        self.targetVisited = Array(repeating: false, count: config.totalTargets)

        let fallbackOrder = Array(0..<config.totalTargets)
        if let targetOrder, targetOrder.count == config.totalTargets {
            self.orderedTargetIDs = targetOrder
        } else {
            self.orderedTargetIDs = fallbackOrder
        }

        reset()
    }

    func beginSession() {
        reset()
        scannerState = .initializingTracking
    }

    func reset() {
        scannerState = .idle
        currentTargetIndex = 0
        progress = 0
        currentTargetYaw = 0
        currentTargetPitch = 0
        liveYaw = 0
        livePitch = 0
        yawError = 0
        pitchError = 0
        angleErrorDeg = 180
        translationErrorMeters = 0
        targetScreenPoint = .zero
        isTargetOffScreen = false
        isTargetInFront = false
        screenDistance = .greatestFiniteMagnitude
        isPositionValid = false
        isAngleValid = false
        isScreenAligned = false
        holdProgress = 0
        canCapture = false
        warningUserMoved = false
        warningTrackingLimited = true
        scanCompleted = false
        targetVisited = Array(repeating: false, count: totalTargets)
        coverageFraction = 0

        originPosition = nil
        referenceYawDeg = nil
        stableTime = 0
        lastFrameTimestamp = nil
        holdDurationUsedForCapture = 0
        pendingCaptureTargetID = nil
        captureInFlight = false
        capturedMetadata = []
    }

    func processFrame(
        frame: ARFrame?,
        trackingQuality: ARTrackingManager.TrackingQuality,
        opticsReady: Bool,
        angularVelocityDegSec: Double,
        previewSize: CGSize,
        interfaceOrientation: UIInterfaceOrientation
    ) {
        guard !scanCompleted else {
            scannerState = .completed
            canCapture = false
            holdProgress = 0
            return
        }

        warningTrackingLimited = !trackingQuality.isGoodForCapture

        guard let frame else {
            scannerState = .initializingTracking
            resetTransientAlignmentState()
            return
        }

        let timestamp = frame.timestamp
        let deltaTime = max(0.0, (lastFrameTimestamp.map { timestamp - $0 } ?? (1.0 / 30.0)))
        lastFrameTimestamp = timestamp

        if !trackingQuality.isGoodForCapture {
            scannerState = .errorTrackingLimited
            resetTransientAlignmentState()
            return
        }

        let transform = frame.camera.transform
        let position = simd_make_float3(transform.columns.3)
        let forward = simd_normalize(-simd_make_float3(transform.columns.2))

        if originPosition == nil {
            originPosition = position
            referenceYawDeg = normalizeDegrees(rawYaw(forward: forward))
            scannerState = .ready
        }

        guard let origin = originPosition,
              let targetID = activeTargetID else {
            scannerState = .initializingTracking
            resetTransientAlignmentState()
            return
        }

        if scannerState == .ready {
            scannerState = .waitingForAlignment
        }

        let target = targets[targetID]
        currentTargetYaw = target.yawDeg
        currentTargetPitch = target.pitchDeg

        translationErrorMeters = simd_distance(position, origin)
        warningUserMoved = translationErrorMeters > config.idealTranslation
        isPositionValid = translationErrorMeters <= config.translationThreshold

        let targetDirectionWorld = worldDirection(for: targetID)
        let dotValue = simd_clamp(simd_dot(forward, targetDirectionWorld), -1, 1)
        angleErrorDeg = acos(Double(dotValue)) * 180.0 / .pi
        isAngleValid = angleErrorDeg <= config.angleToleranceDeg

        let rawLiveYaw = normalizeDegrees(rawYaw(forward: forward))
        if let referenceYawDeg {
            liveYaw = normalizeDegrees(rawLiveYaw - referenceYawDeg)
        } else {
            liveYaw = rawLiveYaw
        }

        livePitch = rawPitch(forward: forward)
        yawError = shortestYawDistance(from: liveYaw, to: currentTargetYaw)
        pitchError = abs(livePitch - currentTargetPitch)

        let targetPoint = origin + targetDirectionWorld * config.projectionDistance
        let projected = frame.camera.projectPoint(
            targetPoint,
            orientation: interfaceOrientation,
            viewportSize: previewSize
        )

        targetScreenPoint = CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
        isTargetOffScreen = projected.x < 0
            || projected.x > previewSize.width
            || projected.y < 0
            || projected.y > previewSize.height

        let toTarget = simd_normalize(targetPoint - position)
        isTargetInFront = simd_dot(forward, toTarget) > 0

        let center = CGPoint(x: previewSize.width / 2, y: previewSize.height / 2)
        screenDistance = hypot(targetScreenPoint.x - center.x, targetScreenPoint.y - center.y)
        isScreenAligned = screenDistance <= config.centerCaptureRadius

        let isMotionStable = angularVelocityDegSec < config.maxStableAngularVelocity
        let alignmentValid = isPositionValid && isAngleValid && isMotionStable
        canCapture = alignmentValid

        // Don't reset hold state while a capture is in flight
        if captureInFlight || pendingCaptureTargetID != nil {
            scannerState = .capturing
            holdProgress = 1.0
        } else if !isPositionValid {
            scannerState = .errorUserMoved
            resetHold()
        } else if alignmentValid {
            scannerState = .alignedHolding
            stableTime += deltaTime
            holdProgress = min(1.0, max(0.0, stableTime / config.stableHoldDuration))

            if stableTime >= config.stableHoldDuration {
                pendingCaptureTargetID = targetID
                captureInFlight = true
                holdDurationUsedForCapture = stableTime
                scannerState = .capturing
            }
        } else {
            scannerState = .waitingForAlignment
            resetHold()
        }
    }

    func consumePendingCaptureTargetID() -> Int? {
        let targetID = pendingCaptureTargetID
        pendingCaptureTargetID = nil
        return targetID
    }

    func requestManualCapture() -> Int? {
        guard canCapture, let targetID = activeTargetID else { return nil }
        pendingCaptureTargetID = targetID
        holdDurationUsedForCapture = max(stableTime, config.stableHoldDuration)
        scannerState = .capturing
        return targetID
    }

    func markPhotoAccepted(targetID: Int, metadata: SphereCapturePhotoMetadata) {
        guard currentTargetIndex < orderedTargetIDs.count else { return }
        guard orderedTargetIDs[currentTargetIndex] == targetID else { return }

        targetVisited[targetID] = true
        capturedMetadata.append(metadata)
        progress = Double(visitedTargets.count) / Double(totalTargets)
        coverageFraction = progress

        scannerState = .photoAccepted
        captureInFlight = false
        resetHold()
        canCapture = false

        currentTargetIndex += 1

        if currentTargetIndex >= orderedTargetIDs.count {
            scanCompleted = true
            scannerState = .completed
            canCapture = false
            holdProgress = 0
        } else {
            scannerState = .waitingForAlignment
        }
    }

    func targetPoint3D(for targetID: Int) -> simd_float3? {
        guard targets.indices.contains(targetID), let origin = originPosition else { return nil }
        return origin + worldDirection(for: targetID) * config.projectionDistance
    }

    func targetPoint3D(for targetID: Int, fallbackOrigin: simd_float3) -> simd_float3 {
        let origin = originPosition ?? fallbackOrigin
        return origin + worldDirection(for: targetID) * config.projectionDistance
    }

    func worldDirection(for targetID: Int) -> simd_float3 {
        guard targets.indices.contains(targetID) else { return simd_float3(0, 0, 1) }
        let base = targets[targetID].direction
        guard let referenceYawDeg else { return base }
        return rotateAroundWorldY(base, yawDeg: referenceYawDeg)
    }

    func buildPhotoMetadata(
        timestamp: TimeInterval,
        rollDeg: Double,
        cameraTransform: simd_float4x4
    ) -> SphereCapturePhotoMetadata? {
        guard let targetID = activeTargetID,
              targets.indices.contains(targetID) else { return nil }

        return SphereCapturePhotoMetadata(
            photoIndex: currentTargetIndex,
            targetID: targetID,
            targetYaw: currentTargetYaw,
            targetPitch: currentTargetPitch,
            actualYaw: liveYaw,
            actualPitch: livePitch,
            actualRoll: rollDeg,
            cameraTransform: SphereCapturePhotoMetadata.flatTransform(cameraTransform),
            yawError: yawError,
            pitchError: pitchError,
            angleErrorDeg: angleErrorDeg,
            translationErrorMeters: Double(translationErrorMeters),
            targetScreenX: Double(targetScreenPoint.x),
            targetScreenY: Double(targetScreenPoint.y),
            holdDurationUsed: holdDurationUsedForCapture,
            timestamp: timestamp
        )
    }

    func buildScanSummaryMetadata(sessionId: String) -> SphereCaptureSummaryMetadata {
        SphereCaptureSummaryMetadata(
            sessionId: sessionId,
            totalTargets: totalTargets,
            capturedCount: visitedTargets.count,
            currentTargetIndex: currentTargetIndex,
            orderedTargetIDs: orderedTargetIDs,
            targetVisited: targetVisited,
            visitedTargets: visitedTargets,
            remainingTargets: remainingTargets,
            coverageFraction: coverageFraction,
            photoMetadata: capturedMetadata,
            completed: scanCompleted,
            timestamp: Date().timeIntervalSince1970
        )
    }

    func buildCaptureManifest(
        sessionId: String,
        cameraHFOVDeg: Double,
        cameraVFOVDeg: Double
    ) -> CaptureManifest {
        CaptureManifest.build(
            sessionId: sessionId,
            orderedTargetIDs: orderedTargetIDs,
            photoMetadata: capturedMetadata,
            cameraHFOVDeg: cameraHFOVDeg,
            cameraVFOVDeg: cameraVFOVDeg
        )
    }

    private func resetHold() {
        stableTime = 0
        holdProgress = 0
        holdDurationUsedForCapture = 0
    }

    private func resetTransientAlignmentState() {
        canCapture = false
        holdProgress = 0
        stableTime = 0
        isAngleValid = false
        isPositionValid = false
        isScreenAligned = false
        warningUserMoved = false
    }

    private func rawYaw(forward: simd_float3) -> Double {
        atan2(Double(forward.x), Double(forward.z)) * 180.0 / .pi
    }

    private func rawPitch(forward: simd_float3) -> Double {
        atan2(Double(forward.y), Double(hypot(forward.x, forward.z))) * 180.0 / .pi
    }

    private func shortestYawDistance(from lhs: Double, to rhs: Double) -> Double {
        let delta = abs(normalizeDegrees(lhs) - normalizeDegrees(rhs))
        return min(delta, 360.0 - delta)
    }

    private func normalizeDegrees(_ value: Double) -> Double {
        var wrapped = value.truncatingRemainder(dividingBy: 360.0)
        if wrapped < 0 { wrapped += 360.0 }
        return wrapped
    }

    private func rotateAroundWorldY(_ vector: simd_float3, yawDeg: Double) -> simd_float3 {
        let radians = Float(yawDeg * .pi / 180.0)
        let cosYaw = cos(radians)
        let sinYaw = sin(radians)
        return simd_normalize(simd_float3(
            vector.x * cosYaw + vector.z * sinYaw,
            vector.y,
            -vector.x * sinYaw + vector.z * cosYaw
        ))
    }

    private static func targetDirection(yawDeg: Double, pitchDeg: Double) -> simd_float3 {
        let yawRad = yawDeg * .pi / 180.0
        let pitchRad = pitchDeg * .pi / 180.0

        let x = cos(pitchRad) * sin(yawRad)
        let y = sin(pitchRad)
        let z = cos(pitchRad) * cos(yawRad)

        return simd_normalize(simd_float3(Float(x), Float(y), Float(z)))
    }

    private static func defaultTargets() -> [Target] {
        let rawTargets: [(Double, Double)] = [
            (0, 0), (45, 0), (90, 0), (135, 0),
            (180, 0), (225, 0), (270, 0), (315, 0),
            (45, 45), (135, 45), (225, 45), (315, 45),
            (45, -45), (135, -45), (225, -45), (315, -45)
        ]

        return rawTargets.enumerated().map { index, item in
            let yaw = item.0
            let pitch = item.1
            return Target(
                id: index,
                yawDeg: yaw,
                pitchDeg: pitch,
                direction: targetDirection(yawDeg: yaw, pitchDeg: pitch)
            )
        }
    }
}

struct SphereCapturePhotoMetadata: Codable {
    let photoIndex: Int
    let targetID: Int
    let targetYaw: Double
    let targetPitch: Double
    let actualYaw: Double
    let actualPitch: Double
    let actualRoll: Double
    /// Column-major 4x4 camera transform at capture time (16 elements).
    let cameraTransform: [Double]
    let yawError: Double
    let pitchError: Double
    let angleErrorDeg: Double
    let translationErrorMeters: Double
    let targetScreenX: Double
    let targetScreenY: Double
    let holdDurationUsed: Double
    let timestamp: TimeInterval

    /// Convenience: flat column-major array from simd_float4x4.
    static func flatTransform(_ t: simd_float4x4) -> [Double] {
        let c = t.columns
        return [
            Double(c.0.x), Double(c.0.y), Double(c.0.z), Double(c.0.w),
            Double(c.1.x), Double(c.1.y), Double(c.1.z), Double(c.1.w),
            Double(c.2.x), Double(c.2.y), Double(c.2.z), Double(c.2.w),
            Double(c.3.x), Double(c.3.y), Double(c.3.z), Double(c.3.w)
        ]
    }
}

struct SphereCaptureSummaryMetadata: Codable {
    let sessionId: String
    let totalTargets: Int
    let capturedCount: Int
    let currentTargetIndex: Int
    let orderedTargetIDs: [Int]
    let targetVisited: [Bool]
    let visitedTargets: [Int]
    let remainingTargets: [Int]
    let coverageFraction: Double
    let photoMetadata: [SphereCapturePhotoMetadata]
    let completed: Bool
    let timestamp: TimeInterval
}

// MARK: - Ordered Capture Manifest

/// Complete capture manifest linking every shot to its image file and full metadata.
/// Written once after all 16 shots are accepted — the single source of truth for
/// downstream stitching, upload, and reconstruction pipelines.
struct CaptureManifest: Codable {
    let version: Int
    let sessionId: String
    let createdAt: TimeInterval
    let totalShots: Int
    /// Portrait-mode horizontal FOV in degrees (from ARKit intrinsics).
    let cameraHFOVDeg: Double
    /// Portrait-mode vertical FOV in degrees (from ARKit intrinsics).
    let cameraVFOVDeg: Double
    let shots: [Shot]

    struct Shot: Codable {
        let order: Int
        let targetID: Int
        let imageFile: String
        let metadataFile: String
        let targetYawDeg: Double
        let targetPitchDeg: Double
        let actualYawDeg: Double
        let actualPitchDeg: Double
        let actualRollDeg: Double
        /// Column-major 4x4 camera transform (16 doubles).
        let cameraTransform: [Double]
        let angleErrorDeg: Double
        let translationErrorMeters: Double
        let holdDurationSec: Double
        let capturedAt: TimeInterval
    }

    /// Build a manifest from the ordered photo metadata and session info.
    static func build(
        sessionId: String,
        orderedTargetIDs: [Int],
        photoMetadata: [SphereCapturePhotoMetadata],
        cameraHFOVDeg: Double,
        cameraVFOVDeg: Double
    ) -> CaptureManifest {
        let metaByTarget: [Int: SphereCapturePhotoMetadata] = Dictionary(
            uniqueKeysWithValues: photoMetadata.map { ($0.targetID, $0) }
        )

        let shots: [Shot] = orderedTargetIDs.enumerated().compactMap { order, targetID in
            guard let m = metaByTarget[targetID] else { return nil }
            return Shot(
                order: order,
                targetID: targetID,
                imageFile: String(format: "step_%02d.jpg", targetID + 1),
                metadataFile: String(format: "step_%02d.json", targetID + 1),
                targetYawDeg: m.targetYaw,
                targetPitchDeg: m.targetPitch,
                actualYawDeg: m.actualYaw,
                actualPitchDeg: m.actualPitch,
                actualRollDeg: m.actualRoll,
                cameraTransform: m.cameraTransform,
                angleErrorDeg: m.angleErrorDeg,
                translationErrorMeters: m.translationErrorMeters,
                holdDurationSec: m.holdDurationUsed,
                capturedAt: m.timestamp
            )
        }

        return CaptureManifest(
            version: 1,
            sessionId: sessionId,
            createdAt: Date().timeIntervalSince1970,
            totalShots: orderedTargetIDs.count,
            cameraHFOVDeg: cameraHFOVDeg,
            cameraVFOVDeg: cameraVFOVDeg,
            shots: shots
        )
    }
}
