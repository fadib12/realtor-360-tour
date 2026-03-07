import SwiftUI
import ARKit
import UIKit
import simd
import ImageIO

// MARK: - SphereGrid (16 targets, 8 + 4 + 4)

enum SphereGrid {
    struct Target {
        let yawDeg: Double
        let pitchDeg: Double
        let direction: simd_float3
    }

    static func unitVector(yawDeg: Double, pitchDeg: Double) -> simd_float3 {
        let yaw = yawDeg * .pi / 180.0
        let pitch = pitchDeg * .pi / 180.0

        let x = cos(pitch) * sin(yaw)
        let y = sin(pitch)
        let z = cos(pitch) * cos(yaw)

        return simd_normalize(simd_float3(Float(x), Float(y), Float(z)))
    }

    static let targets: [Target] = [
        Target(yawDeg: 0, pitchDeg: 0, direction: unitVector(yawDeg: 0, pitchDeg: 0)),
        Target(yawDeg: 45, pitchDeg: 0, direction: unitVector(yawDeg: 45, pitchDeg: 0)),
        Target(yawDeg: 90, pitchDeg: 0, direction: unitVector(yawDeg: 90, pitchDeg: 0)),
        Target(yawDeg: 135, pitchDeg: 0, direction: unitVector(yawDeg: 135, pitchDeg: 0)),
        Target(yawDeg: 180, pitchDeg: 0, direction: unitVector(yawDeg: 180, pitchDeg: 0)),
        Target(yawDeg: 225, pitchDeg: 0, direction: unitVector(yawDeg: 225, pitchDeg: 0)),
        Target(yawDeg: 270, pitchDeg: 0, direction: unitVector(yawDeg: 270, pitchDeg: 0)),
        Target(yawDeg: 315, pitchDeg: 0, direction: unitVector(yawDeg: 315, pitchDeg: 0)),

        Target(yawDeg: 45, pitchDeg: 45, direction: unitVector(yawDeg: 45, pitchDeg: 45)),
        Target(yawDeg: 135, pitchDeg: 45, direction: unitVector(yawDeg: 135, pitchDeg: 45)),
        Target(yawDeg: 225, pitchDeg: 45, direction: unitVector(yawDeg: 225, pitchDeg: 45)),
        Target(yawDeg: 315, pitchDeg: 45, direction: unitVector(yawDeg: 315, pitchDeg: 45)),

        Target(yawDeg: 45, pitchDeg: -45, direction: unitVector(yawDeg: 45, pitchDeg: -45)),
        Target(yawDeg: 135, pitchDeg: -45, direction: unitVector(yawDeg: 135, pitchDeg: -45)),
        Target(yawDeg: 225, pitchDeg: -45, direction: unitVector(yawDeg: 225, pitchDeg: -45)),
        Target(yawDeg: 315, pitchDeg: -45, direction: unitVector(yawDeg: 315, pitchDeg: -45))
    ]

    static var count: Int { targets.count }
}

// MARK: - Capture UI Phase State Machine

enum CapturePhase: Equatable {
    case initialLock
    case firstCaptureCommitted
    case guidedContinuation
    case stitching
    case completed

    var isCapturing: Bool {
        switch self {
        case .initialLock, .firstCaptureCommitted, .guidedContinuation: return true
        case .stitching, .completed: return false
        }
    }
}

// MARK: - CaptureViewModel

@MainActor
class CaptureViewModel: ObservableObject {

    let nrPhotos: Int = SphereGrid.count
    let globe = GlobeSceneController()
    let arManager = ARTrackingManager()
    let mosaicRenderer = PreviewMosaicRenderer()

    private let sphereCapture = SphereCaptureManager()

    @Published var capturedThumbnails: [Int: UIImage] = [:]
    @Published private(set) var firstCaptureThumbnail: UIImage? = nil
    @Published var nrPhotosTaken: Int = 0
    @Published var isComplete = false
    @Published private(set) var positionDriftMeters: Float = 0
    @Published var phase: CapturePhase = .initialLock
    @Published var stitchedPanorama: UIImage? = nil

    @Published var alignedDotId: Int? = nil
    @Published var isWaitingToCapture = false
    @Published var holdProgress: Double = 0
    @Published var takingPicture = false
    @Published var qualityWarning: String? = nil

    @Published var trackingQuality: ARTrackingManager.TrackingQuality = .notAvailable

    // Required scanner outputs
    @Published private(set) var currentTargetIndex: Int = 0
    @Published private(set) var totalTargets: Int = SphereGrid.count
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentTargetYaw: Double = 0
    @Published private(set) var currentTargetPitch: Double = 0
    @Published private(set) var liveYaw: Double = 0
    @Published private(set) var livePitch: Double = 0
    @Published private(set) var yawError: Double = 0
    @Published private(set) var pitchError: Double = 0
    @Published private(set) var angleErrorDeg: Double = 180
    @Published private(set) var translationErrorMeters: Double = 0
    @Published private(set) var targetScreenPoint: CGPoint = .zero
    @Published private(set) var isPositionValid: Bool = false
    @Published private(set) var isAngleValid: Bool = false
    @Published private(set) var isScreenAligned: Bool = false
    @Published private(set) var canCapture: Bool = false
    @Published private(set) var trackingState: ARTrackingManager.TrackingQuality = .notAvailable
    @Published private(set) var scannerState: SphereCaptureManager.ScannerState = .idle
    @Published private(set) var targetVisited: [Bool] = Array(repeating: false, count: SphereGrid.count)
    @Published private(set) var visitedTargets: [Int] = []
    @Published private(set) var remainingTargets: [Int] = Array(0..<SphereGrid.count)
    @Published private(set) var coverageFraction: Double = 0
    @Published private(set) var warningUserMoved: Bool = false
    @Published private(set) var warningTrackingLimited: Bool = false
    @Published private(set) var scanCompleted: Bool = false

    var sessionId = UUID().uuidString
    private var capturedImages: [Int: Data] = [:]
    private var capturedActualPositions: [Int: (yawDeg: Double, pitchDeg: Double)] = [:]
    private var lastGuideViewportSize: CGSize = .zero

    var capturedImageData: [Data] {
        (0..<nrPhotos).compactMap { capturedImages[$0] }
    }

    /// The angular size (in degrees) that the targeting square subtends on the
    /// 120° globe. Photos are warped at this FOV so they exactly fill the square.
    var displayWarpFOV: (hDeg: Double, vDeg: Double) {
        let screenH = Double(lastGuideViewportSize.height)
        let screenW = Double(lastGuideViewportSize.width)
        guard screenH > 100, screenW > 100 else { return (50, 65) }

        let globeVFOV = 120.0 * .pi / 180.0
        let aspect = screenW / screenH
        let globeHFOV = 2.0 * atan(aspect * tan(globeVFOV / 2.0))

        let windowW = screenW * 0.78
        let windowH = min(windowW / 0.75, screenH * 0.55)
        let adjustedW = windowH * 0.75

        let vFraction = windowH / screenH
        let hFraction = adjustedW / screenW
        let vAngle = 2.0 * atan(vFraction * tan(globeVFOV / 2.0)) * 180.0 / .pi
        let hAngle = 2.0 * atan(hFraction * tan(globeHFOV / 2.0)) * 180.0 / .pi

        return (hAngle, vAngle)
    }

    var capturedHDRData: [HDRBracketResult] { [] }

    var activeGuideTargetID: Int? {
        sphereCapture.activeTargetID
    }

    var isFirstShot: Bool {
        nrPhotosTaken == 0
    }

    var directionHint: String? {
        if trackingQuality == .notAvailable {
            return "Waiting for camera…"
        }
        if case .limited(let reason) = trackingQuality, reason == "Initializing" {
            return "Initializing tracking — move slowly"
        }
        if !isPositionValid && nrPhotosTaken > 0 {
            return "Return to your capture spot"
        }
        if takingPicture {
            return "Capturing…"
        }
        if canCapture {
            return "Hold steady…"
        }
        guard activeGuideTargetID != nil else { return nil }

        var yawErr = currentTargetYaw - liveYaw
        if yawErr > 180 { yawErr -= 360 }
        if yawErr < -180 { yawErr += 360 }
        let pitchErr = currentTargetPitch - livePitch

        if abs(yawErr) < 6 && abs(pitchErr) < 6 {
            return "Almost there — hold steady"
        }

        if abs(yawErr) > abs(pitchErr) {
            return yawErr > 0
                ? "Tilt your device to the right"
                : "Tilt your device to the left"
        }
        return pitchErr > 0
            ? "Tilt your device up"
            : "Tilt your device down"
    }

    var cameraYawDeg: Double {
        let forward = arManager.cameraForward
        var yaw = atan2(Double(forward.x), Double(-forward.z)) * 180.0 / .pi
        if yaw < 0 { yaw += 360 }
        return yaw
    }

    var cameraPitchDeg: Double {
        asin(Double(arManager.cameraForward.y)) * 180.0 / .pi
    }

    init() {
        syncFromEngine()
    }

    func startCapture() async {
        sessionId = UUID().uuidString
        capturedImages = [:]
        capturedActualPositions = [:]
        capturedThumbnails = [:]
        firstCaptureThumbnail = nil
        nrPhotosTaken = 0
        isComplete = false
        stitchedPanorama = nil
        qualityWarning = nil
        takingPicture = false
        phase = .initialLock

        globe.reset()
        mosaicRenderer.reset()

        sphereCapture.beginSession()
        syncFromEngine()

        await arManager.start()
    }

    func stopCapture() {
        arManager.stop()
    }

    func reset() {
        capturedImages = [:]
        capturedActualPositions = [:]
        capturedThumbnails = [:]
        firstCaptureThumbnail = nil
        nrPhotosTaken = 0
        isComplete = false
        stitchedPanorama = nil
        qualityWarning = nil
        takingPicture = false
        phase = .initialLock
        lastGuideViewportSize = .zero

        globe.reset()
        mosaicRenderer.reset()
        sphereCapture.reset()
        arManager.unlockCameraSettings()
        arManager.stop()

        syncFromEngine()
    }

    func updateFrame() {
        arManager.processCurrentFrame()
        trackingQuality = arManager.trackingQuality

        sphereCapture.processFrame(
            frame: arManager.currentFrame,
            trackingQuality: arManager.trackingQuality,
            opticsReady: arManager.opticsReady,
            angularVelocityDegSec: arManager.angularVelocity,
            previewSize: lastGuideViewportSize,
            interfaceOrientation: currentInterfaceOrientation
        )

        syncFromEngine()

        if holdProgress > 0, let activeID = activeGuideTargetID {
            alignedDotId = activeID
        } else {
            alignedDotId = nil
        }

        if !isComplete && nrPhotosTaken == 0 && phase != .initialLock {
            phase = .initialLock
        }

        // Live camera → sphere texture during initialLock
        // Uses capture FOV so live window matches captured photo window size.
        // Positioned at current device orientation so it always appears where the iPhone is facing.
        if phase == .initialLock {
            if let camImg = arManager.cameraImage {
                let fov = displayWarpFOV
                // Map camera yaw to equirectangular longitude:
                // cameraYaw=0 → facing -Z → equirect λ=180°
                // The warp forward at yawDeg=0 is +Z (λ=0), so offset by 180°.
                let sphereYaw = fmod(180.0 - cameraYawDeg + 360.0, 360.0)
                mosaicRenderer.updateLivePreview(
                    image: camImg,
                    yawDeg: sphereYaw,
                    pitchDeg: cameraPitchDeg,
                    rollDeg: 0,
                    hfovDeg: fov.hDeg,
                    vfovDeg: fov.vDeg
                )
                globe.setMosaicTexture(mosaicRenderer.liveImage)
            }
        } else {
            mosaicRenderer.clearLive()
        }

        guard !takingPicture else { return }
        guard let targetID = sphereCapture.consumePendingCaptureTargetID() else { return }

        Task { await capturePhoto(for: targetID) }
    }

    func updateOrientationOnly() {
        arManager.processCurrentFrame()
        objectWillChange.send()
    }

    func manualCaptureIfValid() {
        guard !takingPicture,
              let targetID = sphereCapture.requestManualCapture() else { return }

        Task { await capturePhoto(for: targetID) }
    }

    func setGuideViewportSize(_ size: CGSize) {
        lastGuideViewportSize = size
    }

    // MARK: - 3D-Projected Target Dots

    struct ProjectedDot: Identifiable {
        let id: Int
        let screenPoint: CGPoint
        let isCaptured: Bool
        let isActive: Bool
    }

    /// Projects all 16 target positions into screen coordinates using perspective
    /// projection that matches the SceneKit globe camera (110° vertical FOV).
    /// Returns only dots that are in front of the camera and within the view frustum.
    func visibleTargetDots(screenSize: CGSize) -> [ProjectedDot] {
        lastGuideViewportSize = screenSize
        var dots: [ProjectedDot] = []

        let globeVFOVDeg: Double = 120
        let aspect = Double(screenSize.width / screenSize.height)
        let tanHalfV = tan(globeVFOVDeg / 2 * .pi / 180)
        let tanHalfH = tanHalfV * aspect

        let activeID = activeGuideTargetID ?? -1

        for i in 0..<SphereGrid.count {
            var yawErr = SphereGrid.targets[i].yawDeg - liveYaw
            if yawErr > 180 { yawErr -= 360 }
            if yawErr < -180 { yawErr += 360 }
            let pitchErr = SphereGrid.targets[i].pitchDeg - livePitch

            let yawRad = yawErr * .pi / 180
            let pitchRad = pitchErr * .pi / 180

            let tanX = tan(yawRad)
            let tanY = tan(pitchRad)

            // Behind camera or outside frustum
            guard abs(yawErr) < 80, abs(pitchErr) < 80 else { continue }

            let fractionX = tanX / tanHalfH
            let fractionY = tanY / tanHalfV
            guard abs(fractionX) < 1.15, abs(fractionY) < 1.15 else { continue }

            let sx = screenSize.width / 2 + CGFloat(fractionX) * screenSize.width / 2
            let sy = screenSize.height / 2 - CGFloat(fractionY) * screenSize.height / 2

            dots.append(ProjectedDot(
                id: i,
                screenPoint: CGPoint(x: sx, y: sy),
                isCaptured: targetVisited[i],
                isActive: i == activeID
            ))
        }

        return dots
    }

    private func capturePhoto(for targetID: Int) async {
        guard !takingPicture else { return }
        takingPicture = true

        defer {
            takingPicture = false
        }

        do {
            var imageData = try await arManager.capturePhoto()
            let timestamp = Date().timeIntervalSince1970
            let captureTransform = arManager.cameraTransform
            let captureRoll = arManager.rollDeg
            let metadata = sphereCapture.buildPhotoMetadata(
                timestamp: timestamp,
                rollDeg: captureRoll,
                cameraTransform: captureTransform
            )

            if let metadata,
               let metadataJSON = try? JSONEncoder().encode(metadata),
               let metadataString = String(data: metadataJSON, encoding: .utf8) {
                imageData = FileHelper.embedEXIFUserComment(in: imageData, userComment: metadataString)
            }

            let quality = await QualityChecker.analyze(imageData)
            var warnings: [String] = []
            if quality.isBlurry { warnings.append("blurry") }
            if quality.isDark { warnings.append("too dark") }
            if quality.isOverexposed { warnings.append("overexposed") }
            if !warnings.isEmpty {
                let warning = "Captured with \(warnings.joined(separator: " & "))"
                qualityWarning = warning
                clearWarningAfterDelay(warning)
            }

            capturedImages[targetID] = imageData
            if let metadata {
                capturedActualPositions[targetID] = (yawDeg: metadata.actualYaw, pitchDeg: metadata.actualPitch)
            } else {
                capturedActualPositions[targetID] = (yawDeg: liveYaw, pitchDeg: livePitch)
            }

            if let preview = await Self.generatePreview(from: imageData, maxDimension: 1280) {
                capturedThumbnails[targetID] = preview
                if firstCaptureThumbnail == nil {
                    firstCaptureThumbnail = preview
                }
            } else if firstCaptureThumbnail == nil,
                      let preview = UIImage(data: imageData) {
                firstCaptureThumbnail = preview
            }

            if !arManager.cameraLocked {
                arManager.lockCameraSettings()
            }

            // Warp capture into the live mosaic preview
            let mosaicYaw: Double
            let mosaicPitch: Double
            let mosaicRoll: Double
            if let m = metadata {
                mosaicYaw = m.actualYaw
                mosaicPitch = m.actualPitch
                mosaicRoll = m.actualRoll
            } else {
                mosaicYaw = liveYaw
                mosaicPitch = livePitch
                mosaicRoll = captureRoll
            }
            let warpFOV = displayWarpFOV
            // mosaicYaw is from SphereCaptureManager which uses atan2(x, z) — yaw=0 is +Z.
            // The warp convention is also yaw=0 → +Z. No conversion needed.
            mosaicRenderer.blendCapture(
                imageData: imageData,
                yawDeg: mosaicYaw,
                pitchDeg: mosaicPitch,
                rollDeg: 0,
                hfovDeg: warpFOV.hDeg,
                vfovDeg: warpFOV.vDeg
            )
            globe.setMosaicTexture(mosaicRenderer.mosaicImage)

            FileHelper.saveCapture(imageData, sessionId: sessionId, step: targetID + 1)

            if let metadata {
                FileHelper.saveCaptureMetadata(metadata, sessionId: sessionId, step: targetID + 1)
                sphereCapture.markPhotoAccepted(targetID: targetID, metadata: metadata)
            } else {
                let fallback = SphereCapturePhotoMetadata(
                    photoIndex: currentTargetIndex,
                    targetID: targetID,
                    targetYaw: currentTargetYaw,
                    targetPitch: currentTargetPitch,
                    actualYaw: liveYaw,
                    actualPitch: livePitch,
                    actualRoll: captureRoll,
                    cameraTransform: SphereCapturePhotoMetadata.flatTransform(captureTransform),
                    yawError: yawError,
                    pitchError: pitchError,
                    angleErrorDeg: angleErrorDeg,
                    translationErrorMeters: translationErrorMeters,
                    targetScreenX: Double(targetScreenPoint.x),
                    targetScreenY: Double(targetScreenPoint.y),
                    holdDurationUsed: holdProgress * sphereCapture.config.stableHoldDuration,
                    timestamp: timestamp
                )
                FileHelper.saveCaptureMetadata(fallback, sessionId: sessionId, step: targetID + 1)
                sphereCapture.markPhotoAccepted(targetID: targetID, metadata: fallback)
            }

            HapticManager.success()
            syncFromEngine()

            // Phase transitions after capture
            mosaicRenderer.clearLive()
            if nrPhotosTaken == 1 && phase == .initialLock {
                phase = .firstCaptureCommitted
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    guard let self, self.phase == .firstCaptureCommitted else { return }
                    self.phase = .guidedContinuation
                }
            } else if phase == .firstCaptureCommitted || phase == .initialLock {
                phase = .guidedContinuation
            }

            if scanCompleted {
                let summary = sphereCapture.buildScanSummaryMetadata(sessionId: sessionId)
                FileHelper.saveScanSummaryMetadata(summary, sessionId: sessionId)

                let hfov = Double(arManager.portraitHFOVRadians) * 180.0 / .pi
                let vfov = Double(arManager.portraitVFOVRadians) * 180.0 / .pi
                let manifest = sphereCapture.buildCaptureManifest(
                    sessionId: sessionId,
                    cameraHFOVDeg: hfov,
                    cameraVFOVDeg: vfov
                )
                FileHelper.saveManifest(manifest, sessionId: sessionId)

                markCompleteIfNeeded()
            }

        } catch {
            print("Capture error: \(error)")
            qualityWarning = "Capture failed — try again"
            HapticManager.error()
            clearWarningAfterDelay("Capture failed — try again")
        }
    }

    private static func generatePreview(from jpegData: Data, maxDimension: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        }.value
    }

    private func markCompleteIfNeeded() {
        guard !isComplete else { return }

        isComplete = true
        phase = .stitching
        HapticManager.success()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            HapticManager.success()
        }

        let hfov = Double(arManager.portraitHFOVRadians) * 180.0 / .pi
        let vfov = Double(arManager.portraitVFOVRadians) * 180.0 / .pi

        let plan = StitchPreparation.prepare(
            sessionId: sessionId,
            capturedImages: capturedImages,
            capturedPositions: capturedActualPositions,
            photoMetadata: sphereCapture.photoMetadata,
            orderedTargetIDs: sphereCapture.orderedTargetIDs,
            hfovDeg: hfov,
            vfovDeg: vfov
        )

        if !plan.isComplete {
            print("⚠️ Stitch plan incomplete: missing targets \(plan.missingTargetIDs)")
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = PanoramaStitcher.stitch(plan: plan)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let data = result, let image = UIImage(data: data) {
                    self.stitchedPanorama = image
                }
                self.phase = .completed
            }
        }
    }

    private func syncFromEngine() {
        currentTargetIndex = sphereCapture.currentTargetIndex
        totalTargets = sphereCapture.totalTargets
        progress = sphereCapture.progress
        currentTargetYaw = sphereCapture.currentTargetYaw
        currentTargetPitch = sphereCapture.currentTargetPitch
        liveYaw = sphereCapture.liveYaw
        livePitch = sphereCapture.livePitch
        yawError = sphereCapture.yawError
        pitchError = sphereCapture.pitchError
        angleErrorDeg = sphereCapture.angleErrorDeg
        translationErrorMeters = Double(sphereCapture.translationErrorMeters)
        targetScreenPoint = sphereCapture.targetScreenPoint
        isPositionValid = sphereCapture.isPositionValid
        isAngleValid = sphereCapture.isAngleValid
        isScreenAligned = sphereCapture.isScreenAligned
        holdProgress = sphereCapture.holdProgress
        canCapture = sphereCapture.canCapture
        trackingState = arManager.trackingQuality
        scannerState = sphereCapture.scannerState
        targetVisited = sphereCapture.targetVisited
        visitedTargets = sphereCapture.visitedTargets
        remainingTargets = sphereCapture.remainingTargets
        coverageFraction = sphereCapture.coverageFraction
        warningUserMoved = sphereCapture.warningUserMoved
        warningTrackingLimited = sphereCapture.warningTrackingLimited
        scanCompleted = sphereCapture.scanCompleted

        nrPhotosTaken = sphereCapture.visitedTargets.count
        positionDriftMeters = sphereCapture.translationErrorMeters
        trackingQuality = arManager.trackingQuality
        isWaitingToCapture = sphereCapture.scannerState == .alignedHolding
    }

    private var currentInterfaceOrientation: UIInterfaceOrientation {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .interfaceOrientation ?? .portrait
    }

    private func clearWarningAfterDelay(_ message: String) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if qualityWarning == message {
                qualityWarning = nil
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
