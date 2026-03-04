import CoreMotion
import Combine

class MotionService: ObservableObject {
    @Published var yaw: Double = 0        // -180 to 180
    @Published var pitch: Double = 0      // -90 to 90
    @Published var roll: Double = 0       // -180 to 180
    @Published var isAvailable = false
    
    private let motionManager = CMMotionManager()
    private var referenceYaw: Double = 0
    private var isCalibrated = false
    
    init() {
        isAvailable = motionManager.isDeviceMotionAvailable
    }
    
    func start() {
        guard motionManager.isDeviceMotionAvailable else {
            print("Device motion not available")
            return
        }
        
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0  // 60 Hz
        
        motionManager.startDeviceMotionUpdates(
            using: .xArbitraryZVertical,
            to: .main
        ) { [weak self] motion, error in
            guard let self = self, let motion = motion else { return }
            
            // Get attitude (orientation)
            let attitude = motion.attitude
            
            // Convert to degrees
            // Pitch: rotation around X axis (tilting up/down)
            // Device pointing up = positive pitch
            let pitchDegrees = attitude.pitch * 180.0 / .pi
            
            // Yaw: rotation around Z axis (compass direction)
            var yawDegrees = attitude.yaw * 180.0 / .pi
            
            // Calibrate yaw on first reading
            if !self.isCalibrated {
                self.referenceYaw = yawDegrees
                self.isCalibrated = true
            }
            
            // Calculate relative yaw from starting position
            yawDegrees = yawDegrees - self.referenceYaw
            
            // Normalize to -180 to 180
            while yawDegrees > 180 { yawDegrees -= 360 }
            while yawDegrees < -180 { yawDegrees += 360 }
            
            // Convert to 0-360 for display
            if yawDegrees < 0 { yawDegrees += 360 }
            
            // Roll for reference
            let rollDegrees = attitude.roll * 180.0 / .pi
            
            self.yaw = yawDegrees
            self.pitch = pitchDegrees
            self.roll = rollDegrees
        }
    }
    
    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }
    
    func calibrate() {
        // Reset reference yaw to current position
        isCalibrated = false
    }
    
    /// Check if current orientation matches target within tolerance
    func isAligned(targetYaw: Double, targetPitch: Double) -> Bool {
        let yawError = abs(normalizeAngle(yaw - targetYaw))
        let pitchError = abs(pitch - targetPitch)
        
        return yawError <= yawTolerance && pitchError <= pitchTolerance
    }
    
    /// Calculate the angle difference, accounting for wrap-around
    private func normalizeAngle(_ angle: Double) -> Double {
        var normalized = angle
        while normalized > 180 { normalized -= 360 }
        while normalized < -180 { normalized += 360 }
        return normalized
    }
}
