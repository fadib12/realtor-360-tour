import AVFoundation
import UIKit

class CameraService: NSObject, ObservableObject {
    @Published var isConfigured = false
    @Published var error: Error?
    
    let session = AVCaptureSession()
    private var photoOutput = AVCapturePhotoOutput()
    private var currentPhotoCompletion: ((Result<URL, Error>) -> Void)?
    
    private let sessionQueue = DispatchQueue(label: "com.realtor360.cameraSession")
    
    override init() {
        super.init()
    }
    
    // MARK: - Configuration
    
    func configure() {
        sessionQueue.async { [weak self] in
            self?.configureSession()
        }
    }
    
    private func configureSession() {
        guard !isConfigured else { return }
        
        session.beginConfiguration()
        session.sessionPreset = .photo
        
        // Find wide-angle camera (prefer ultra-wide if available)
        var device: AVCaptureDevice?
        
        // Try ultra-wide first
        if let ultraWide = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) {
            device = ultraWide
        } else if let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            device = wide
        }
        
        guard let camera = device else {
            DispatchQueue.main.async {
                self.error = CameraError.noCameraAvailable
            }
            return
        }
        
        do {
            // Configure camera for best quality
            try camera.lockForConfiguration()
            
            // Lock exposure and white balance if possible (reduces seams)
            if camera.isExposureModeSupported(.locked) {
                camera.exposureMode = .continuousAutoExposure
            }
            if camera.isWhiteBalanceModeSupported(.locked) {
                camera.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            
            camera.unlockForConfiguration()
            
            // Add input
            let input = try AVCaptureDeviceInput(device: camera)
            
            if session.canAddInput(input) {
                session.addInput(input)
            }
            
            // Add output
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
                
                // Configure for high quality JPEG
                photoOutput.maxPhotoQualityPrioritization = .quality
            }
            
            session.commitConfiguration()
            
            DispatchQueue.main.async {
                self.isConfigured = true
            }
            
        } catch {
            session.commitConfiguration()
            DispatchQueue.main.async {
                self.error = error
            }
        }
    }
    
    // MARK: - Session Control
    
    func start() {
        sessionQueue.async { [weak self] in
            guard let self = self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }
    
    func stop() {
        sessionQueue.async { [weak self] in
            guard let self = self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }
    
    // MARK: - Photo Capture
    
    func capturePhoto(frameIndex: Int) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: CameraError.notConfigured)
                    return
                }
                
                self.currentPhotoCompletion = { result in
                    switch result {
                    case .success(let url):
                        continuation.resume(returning: url)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                
                let settings = AVCapturePhotoSettings()
                settings.flashMode = .off
                
                // Store frame index for filename
                UserDefaults.standard.set(frameIndex, forKey: "currentFrameIndex")
                
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraService: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            currentPhotoCompletion?(.failure(error))
            currentPhotoCompletion = nil
            return
        }
        
        guard let data = photo.fileDataRepresentation() else {
            currentPhotoCompletion?(.failure(CameraError.noPhotoData))
            currentPhotoCompletion = nil
            return
        }
        
        // Save to disk immediately
        let frameIndex = UserDefaults.standard.integer(forKey: "currentFrameIndex")
        let filename = String(format: "frame_%02d.jpg", frameIndex)
        
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let framesDir = documentsURL.appendingPathComponent("frames", isDirectory: true)
        
        // Create frames directory if needed
        try? FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
        
        let fileURL = framesDir.appendingPathComponent(filename)
        
        do {
            try data.write(to: fileURL)
            currentPhotoCompletion?(.success(fileURL))
        } catch {
            currentPhotoCompletion?(.failure(error))
        }
        
        currentPhotoCompletion = nil
    }
}

// MARK: - Errors

enum CameraError: LocalizedError {
    case noCameraAvailable
    case notConfigured
    case noPhotoData
    
    var errorDescription: String? {
        switch self {
        case .noCameraAvailable:
            return "No camera available"
        case .notConfigured:
            return "Camera not configured"
        case .noPhotoData:
            return "Could not get photo data"
        }
    }
}
