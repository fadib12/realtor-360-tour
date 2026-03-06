import AVFoundation
import SwiftUI

// MARK: - CameraManager

class CameraManager: NSObject, ObservableObject {
    @Published var error: String?
    @Published var isReady = false

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var photoContinuation: CheckedContinuation<Data, Error>?

    @MainActor
    func setup() async {
        let granted = await requestPermission()
        guard granted else {
            error = "Camera permission denied. Enable in Settings → Realtor 360."
            return
        }
        configureSession()
    }

    // MARK: Permissions

    private func requestPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .authorized { return true }
        if status == .notDetermined {
            return await AVCaptureDevice.requestAccess(for: .video)
        }
        return false
    }

    // MARK: Session configuration

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            error = "No rear camera available"
            session.commitConfiguration()
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input)  { session.addInput(input) }
            if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
            photoOutput.maxPhotoQualityPrioritization = .balanced
        } catch {
            self.error = "Camera setup failed: \(error.localizedDescription)"
        }
        session.commitConfiguration()

        // Start on a background thread to avoid blocking the UI
        Task.detached { [weak self] in
            self?.session.startRunning()
            await MainActor.run { self?.isReady = true }
        }
    }

    // MARK: Capture

    func capturePhoto() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            self.photoContinuation = continuation
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.flashMode = .off
            settings.photoQualityPrioritization = .balanced
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func stop() {
        Task.detached { [weak self] in
            self?.session.stopRunning()
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error {
            photoContinuation?.resume(throwing: error)
        } else if let data = photo.fileDataRepresentation() {
            photoContinuation?.resume(returning: data)
        } else {
            photoContinuation?.resume(throwing: CameraError.noData)
        }
        photoContinuation = nil
    }
}

enum CameraError: LocalizedError {
    case noData, permissionDenied
    var errorDescription: String? {
        switch self {
        case .noData:           return "No photo data captured"
        case .permissionDenied: return "Camera permission denied"
        }
    }
}

// MARK: - Camera Preview (UIViewRepresentable)

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.previewLayer.frame = uiView.bounds
    }

    class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer.frame = bounds
        }
    }
}
