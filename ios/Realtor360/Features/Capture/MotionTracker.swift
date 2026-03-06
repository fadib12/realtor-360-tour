import CoreMotion
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MotionTracker — CoreMotion 3DOF orientation for photosphere capture.
//
// Replaces ARKit orientation tracking with a lightweight CMMotionManager-based
// tracker.  ARKit owns the camera hardware, making it incompatible with
// AVFoundation HDR bracket capture.  CoreMotion gives us accurate 3DOF
// (yaw, pitch, roll) using the fused sensor pipeline (gyro + accel + compass)
// without touching the camera.
//
// Reference frame: .xArbitraryCorrectedZVertical
//   Z axis = gravity (vertical)
//   X axis = arbitrary but stable heading (magnetically corrected)
//
// Interface matches ARTrackingManager so CaptureViewModel can swap in:
//   horizontalDeg  (0–360° clockwise from start)
//   verticalDeg    (~75° at natural phone hold, +up)
//   rollDeg        (0 when level)
//   isAvailable
//
// Sensor rate: 60 Hz for smooth dot projection.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
class MotionTracker: ObservableObject {

    // ── Published orientation (same interface as ARTrackingManager) ─────────
    /// Horizontal rotation from starting heading (0–360°, clockwise).
    @Published var horizontalDeg: Double = 0
    /// Vertical angle. ≈75° when phone is held at natural viewing angle.
    @Published var verticalDeg: Double = 75
    /// Roll in degrees (side tilt). 0 = phone perfectly upright.
    @Published var rollDeg: Double = 0
    /// True once the first sensor reading arrives.
    @Published var isAvailable = false

    // ── Private ─────────────────────────────────────────────────────────────
    private let motion = CMMotionManager()
    private var initialYaw: Double?

    // MARK: - Lifecycle

    func start() async {
        guard motion.isDeviceMotionAvailable else {
            isAvailable = false
            return
        }
        initialYaw = nil

        // 60 Hz — smooth for real-time dot projection
        motion.deviceMotionUpdateInterval = 1.0 / 60.0

        // xArbitraryCorrectedZVertical gives a magnetically-corrected heading
        // so yaw drift is minimised over the ~60 s capture session.
        motion.startDeviceMotionUpdates(
            using: .xArbitraryCorrectedZVertical,
            to: .main
        ) { [weak self] dm, error in
            guard let self, let dm else { return }
            self.processSensorData(dm)
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        isAvailable = false
        initialYaw = nil
    }

    func resetReference() {
        initialYaw = nil
    }

    // MARK: - Sensor Processing

    /// Extract yaw / pitch / roll from CMDeviceMotion attitude.
    ///
    /// CMAttitude Euler angles (using correctedZ reference):
    ///   yaw:   rotation around Z (vertical) axis, radians
    ///   pitch: rotation around X axis, radians
    ///   roll:  rotation around Y axis, radians
    ///
    /// For a phone held portrait:
    ///   - yaw  = compass heading (0 → 2π, CCW from above)
    ///   - pitch = tilt forward/back (0 = vertical, π/2 = face-up on table)
    ///   - roll  = lean left/right
    private func processSensorData(_ dm: CMDeviceMotion) {
        let att = dm.attitude

        // ── Yaw → 0–360° clockwise from start ────────────────────────────
        // CMAttitude yaw is CCW from above in radians.
        // Negate to get clockwise, convert to degrees, wrap to [0, 360).
        var yawDeg = -att.yaw * 180.0 / .pi
        if yawDeg < 0   { yawDeg += 360.0 }
        if yawDeg >= 360 { yawDeg -= 360.0 }

        if initialYaw == nil { initialYaw = yawDeg }

        var heading = yawDeg - initialYaw!
        if heading < 0   { heading += 360.0 }
        if heading >= 360 { heading -= 360.0 }
        horizontalDeg = heading

        // ── Pitch → vertical angle ───────────────────────────────────────
        // Phone held naturally (portrait, slightly angled): pitch ≈ 0 rad.
        // Map to: 75° = horizon (natural hold), higher = looking up.
        //
        // CMAttitude pitch: 0 = vertical, positive = tilting forward (top away).
        // For photosphere: we want "elevation from forward direction".
        // pitch ≈ 0 → phone vertical → looking at horizon → verticalDeg = 75
        // pitch > 0 → phone tilts forward/up → looking up → verticalDeg > 75
        // pitch < 0 → phone tilts back/down → looking down → verticalDeg < 75
        verticalDeg = 75.0 + att.pitch * 180.0 / .pi

        // ── Roll → side tilt ─────────────────────────────────────────────
        rollDeg = att.roll * 180.0 / .pi

        if !isAvailable { isAvailable = true }
    }
}
