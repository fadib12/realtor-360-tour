import Foundation
import Combine
import UIKit

@MainActor
class GuidedCaptureController: ObservableObject {
    // State
    @Published var currentTargetIndex: Int = 0
    @Published var capturedFrames: [CapturedFrame] = []
    @Published var isAligned: Bool = false
    @Published var isCapturing: Bool = false
    @Published var captureComplete: Bool = false
    @Published var showHoldSteady: Bool = false
    @Published var error: Error?
    
    // Services
    let cameraService: CameraService
    let motionService: MotionService
    
    // Stability tracking
    private var alignedSince: Date?
    private var stabilityTimer: Timer?
    
    // Cancellables
    private var cancellables = Set<AnyCancellable>()
    
    var currentTarget: CaptureTarget? {
        guard currentTargetIndex < captureTargets.count else { return nil }
        return captureTargets[currentTargetIndex]
    }
    
    var progress: Double {
        Double(capturedFrames.count) / Double(captureTargets.count)
    }
    
    var progressText: String {
        "\(capturedFrames.count)/\(captureTargets.count)"
    }
    
    init(cameraService: CameraService, motionService: MotionService) {
        self.cameraService = cameraService
        self.motionService = motionService
        
        setupMotionObserver()
    }
    
    private func setupMotionObserver() {
        // Monitor motion for alignment
        Timer.publish(every: 0.05, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkAlignment()
            }
            .store(in: &cancellables)
    }
    
    private func checkAlignment() {
        guard let target = currentTarget, !isCapturing else {
            isAligned = false
            return
        }
        
        let aligned = motionService.isAligned(
            targetYaw: target.yaw,
            targetPitch: target.pitch
        )
        
        if aligned {
            if alignedSince == nil {
                alignedSince = Date()
            }
            
            // Check if stable for required duration
            if let alignedSince = alignedSince,
               Date().timeIntervalSince(alignedSince) >= stabilityDuration {
                isAligned = true
                
                // Trigger capture
                if !isCapturing {
                    Task {
                        await captureCurrentTarget()
                    }
                }
            }
        } else {
            alignedSince = nil
            isAligned = false
        }
    }
    
    func start() {
        currentTargetIndex = 0
        capturedFrames = []
        captureComplete = false
        error = nil
        
        // Start services
        cameraService.configure()
        cameraService.start()
        motionService.start()
        motionService.calibrate()
    }
    
    func stop() {
        cameraService.stop()
        motionService.stop()
        cancellables.removeAll()
    }
    
    private func captureCurrentTarget() async {
        guard let target = currentTarget else { return }
        
        isCapturing = true
        showHoldSteady = false
        
        do {
            // Haptic feedback
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            
            // Capture photo
            let fileURL = try await cameraService.capturePhoto(frameIndex: currentTargetIndex)
            
            // Record captured frame
            let frame = CapturedFrame(
                index: currentTargetIndex,
                fileURL: fileURL,
                yaw: motionService.yaw,
                pitch: motionService.pitch,
                timestamp: Date()
            )
            capturedFrames.append(frame)
            
            // Success haptic
            let successGenerator = UINotificationFeedbackGenerator()
            successGenerator.notificationOccurred(.success)
            
            // Move to next target
            currentTargetIndex += 1
            alignedSince = nil
            isAligned = false
            
            // Check if complete
            if currentTargetIndex >= captureTargets.count {
                captureComplete = true
                stop()
            }
            
        } catch {
            self.error = error
            
            // Error haptic
            let errorGenerator = UINotificationFeedbackGenerator()
            errorGenerator.notificationOccurred(.error)
        }
        
        isCapturing = false
    }
    
    func retryCapture() {
        error = nil
        start()
    }
    
    /// Get all captured file URLs
    func getCapturedFileURLs() -> [URL] {
        return capturedFrames.map { $0.fileURL }
    }
    
    /// Get frame metadata for upload
    func getFramesMeta() -> [FrameMeta] {
        return capturedFrames.map { frame in
            FrameMeta(
                index: frame.index,
                yaw: frame.yaw,
                pitch: frame.pitch
            )
        }
    }
    
    /// Clean up captured frames from disk
    func cleanupFrames() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let framesDir = documentsURL.appendingPathComponent("frames", isDirectory: true)
        
        try? FileManager.default.removeItem(at: framesDir)
    }
}
