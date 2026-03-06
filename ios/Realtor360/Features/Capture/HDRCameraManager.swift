import AVFoundation
import CoreImage
import UIKit
import SwiftUI
import UniformTypeIdentifiers

// ─────────────────────────────────────────────────────────────────────────────
// HDR Camera Manager — AVFoundation-based bracketed capture for photosphere.
//
// Uses AVCaptureSession + AVCapturePhotoOutput with exposure brackets to
// capture 3 images per dot position (-2 EV, 0 EV, +2 EV). These brackets
// are merged via Mertens-style exposure fusion into a single 32-bit HDR
// buffer that preserves full dynamic range (bright windows + dark corners
// in the same room).
//
// Stack:
//   Camera    → AVFoundation (AVCaptureSession, AVCapturePhotoOutput)
//   Brackets  → AVCapturePhotoBracketSettings (auto-exposure brackets)
//   Fusion    → Mertens exposure fusion (weighted average on float buffers)
//   Output    → Float32 RGBA buffer → 32-bit EXR via ImageIO
//
// This replaces ARKit's capturedImage pixel buffer (single exposure, no HDR).
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - HDRCameraManager
//
// Standalone AVFoundation bracket capture (backup path).
// HDRBracketResult and BracketFrame are defined in HDRProcessor.swift.
// The primary capture path uses ARTrackingManager + HDRProcessor.

@MainActor
class HDRCameraManager: NSObject, ObservableObject {

    // ── Public state ────────────────────────────────────────────────────────
    @Published var isReady = false
    @Published var error: String?

    /// The capture session — connect to CameraPreviewView for live feed.
    let session = AVCaptureSession()

    // ── Private capture pipeline ────────────────────────────────────────────
    private let photoOutput = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Bracket photos accumulate here during a single capture.
    private var bracketPhotos: [AVCapturePhoto] = []
    private var expectedBracketCount = 0
    private var bracketContinuation: CheckedContinuation<HDRBracketResult, Error>?

    // ── EV bracket stops ────────────────────────────────────────────────────
    /// Exposure compensation values for the 3-shot bracket.
    private let bracketEVs: [Float] = [-2.0, 0.0, 2.0]

    // MARK: - Lifecycle

    func setup() async {
        let granted = await requestPermission()
        guard granted else {
            error = "Camera permission denied. Enable in Settings → Realtor 360."
            return
        }
        configureSession()
    }

    func stop() {
        Task.detached { [weak self] in
            self?.session.stopRunning()
        }
    }

    // MARK: - Permission

    private func requestPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .authorized { return true }
        if status == .notDetermined {
            return await AVCaptureDevice.requestAccess(for: .video)
        }
        return false
    }

    // MARK: - Session configuration

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        // Wide-angle back camera (best for interiors)
        guard let cam = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back
        ) else {
            error = "No rear camera available"
            session.commitConfiguration()
            return
        }
        device = cam

        do {
            let input = try AVCaptureDeviceInput(device: cam)
            if session.canAddInput(input)  { session.addInput(input) }
            if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }

            // Enable maximum quality + bracket support
            photoOutput.maxPhotoQualityPrioritization = .quality
            photoOutput.isHighResolutionCaptureEnabled = true

        } catch {
            self.error = "Camera setup failed: \(error.localizedDescription)"
        }
        session.commitConfiguration()

        // Lock focus to continuous auto for best indoor capture
        configureCameraDevice(cam)

        // Start on background thread
        Task.detached { [weak self] in
            self?.session.startRunning()
            await MainActor.run { self?.isReady = true }
        }
    }

    /// Optimise the camera device for indoor photosphere work.
    private func configureCameraDevice(_ cam: AVCaptureDevice) {
        do {
            try cam.lockForConfiguration()
            // Continuous auto-focus for varying room depths
            if cam.isFocusModeSupported(.continuousAutoFocus) {
                cam.focusMode = .continuousAutoFocus
            }
            // Continuous auto-exposure — brackets will override per-shot
            if cam.isExposureModeSupported(.continuousAutoExposure) {
                cam.exposureMode = .continuousAutoExposure
            }
            // Auto white-balance
            if cam.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                cam.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            cam.unlockForConfiguration()
        } catch {
            print("Device config warning: \(error)")
        }
    }

    // MARK: - Single-shot JPEG capture (fallback / preview)

    /// Quick single-exposure JPEG capture (no brackets).
    func capturePhoto() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let settings = AVCapturePhotoSettings(
                format: [AVVideoCodecKey: AVVideoCodecType.jpeg]
            )
            settings.flashMode = .off
            settings.photoQualityPrioritization = .quality

            // Temporarily store the continuation for the delegate callback
            self.bracketPhotos = []
            self.expectedBracketCount = 1
            self.bracketContinuation = nil

            // Use a simple one-shot wrapper
            let delegate = SingleShotDelegate { result in
                switch result {
                case .success(let data): continuation.resume(returning: data)
                case .failure(let err):  continuation.resume(throwing: err)
                }
            }
            self._singleShotDelegate = delegate
            self.photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    private var _singleShotDelegate: SingleShotDelegate?

    // MARK: - HDR Bracket Capture (3 exposures → merged HDR)

    /// Captures a 3-exposure bracket set and merges them into a single HDR result.
    /// Returns both a tone-mapped JPEG (for preview) and raw 32-bit float pixels.
    func captureHDRBracket() async throws -> HDRBracketResult {
        guard let cam = device else { throw HDRCameraError.notReady }

        // Build bracket settings with 3 auto-exposure bias values
        let bracketSettings = bracketEVs.compactMap {
            AVCaptureAutoExposureBracketedStillImageSettings
                .autoExposureSettings(exposureTargetBias: max(cam.minExposureTargetBias,
                                                              min($0, cam.maxExposureTargetBias)))
        }

        guard !bracketSettings.isEmpty else { throw HDRCameraError.bracketConfigFailed }

        let photoSettings = AVCapturePhotoBracketSettings(
            rawPixelFormatType: 0,
            processedFormat: [AVVideoCodecKey: AVVideoCodecType.jpeg],
            bracketedSettings: bracketSettings
        )
        photoSettings.photoQualityPrioritization = .quality

        return try await withCheckedThrowingContinuation { continuation in
            self.bracketPhotos = []
            self.expectedBracketCount = bracketSettings.count
            self.bracketContinuation = continuation
            self.photoOutput.capturePhoto(with: photoSettings, delegate: self)
        }
    }

    // MARK: - Merge delegate photos → HDR result (delegates to HDRProcessor)

    /// Converts AVCapturePhoto array to BracketFrames and merges via HDRProcessor.
    private func mergePhotos(_ photos: [AVCapturePhoto]) -> HDRBracketResult? {
        let frames: [BracketFrame] = photos.compactMap { photo in
            guard let data = photo.fileDataRepresentation(),
                  let ci = CIImage(data: data) else { return nil }
            return BracketFrame(ciImage: ci, ev: 0)
        }
        return HDRProcessor.merge(frames: frames)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate (Bracket Capture)

extension HDRCameraManager: AVCapturePhotoCaptureDelegate {

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                bracketContinuation?.resume(throwing: error)
                bracketContinuation = nil
                return
            }

            bracketPhotos.append(photo)

            // When all bracket exposures are collected, merge them
            if bracketPhotos.count >= expectedBracketCount {
                if expectedBracketCount == 1 {
                    // Single-shot mode: this was a non-bracket capture handled elsewhere
                    return
                }

                // Merge on a background thread (CPU-heavy)
                let photos = bracketPhotos
                bracketPhotos = []

                Task.detached { [weak self] in
                    guard let self else { return }
                    let result = await MainActor.run { self.mergePhotos(photos) }

                    await MainActor.run {
                        if let result {
                            self.bracketContinuation?.resume(returning: result)
                        } else {
                            self.bracketContinuation?.resume(
                                throwing: HDRCameraError.mergeFailed
                            )
                        }
                        self.bracketContinuation = nil
                    }
                }
            }
        }
    }
}

// MARK: - Single-shot delegate (for non-bracket capture)

private class SingleShotDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    let completion: (Result<Data, Error>) -> Void

    init(completion: @escaping (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            completion(.failure(error))
        } else if let data = photo.fileDataRepresentation() {
            completion(.success(data))
        } else {
            completion(.failure(HDRCameraError.noData))
        }
    }
}

// MARK: - Errors

enum HDRCameraError: LocalizedError {
    case notReady, noData, bracketConfigFailed, mergeFailed

    var errorDescription: String? {
        switch self {
        case .notReady:            return "Camera not ready"
        case .noData:              return "No photo data captured"
        case .bracketConfigFailed: return "HDR bracket configuration failed"
        case .mergeFailed:         return "HDR merge failed"
        }
    }
}

// MARK: - AVFoundation Camera Preview (UIViewRepresentable)

/// Full-screen live camera preview backed by AVCaptureVideoPreviewLayer.
/// Replaces ARCameraPreview (ARSCNView) for the photosphere capture pipeline.
struct HDRCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer.frame = bounds
        }
    }
}
