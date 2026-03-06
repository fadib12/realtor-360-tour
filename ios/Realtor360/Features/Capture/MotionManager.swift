import CoreMotion
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// Exact port of the Flutter camera_360 plugin's sensor handling.
//
// Flutter source (camera_360.dart):
//   deviceHorizontalDeg = (360 - degrees(yaw + roll) % 360)
//   deviceVerticalDeg   = degrees(pitch)
//   deviceRotationDeg   = degrees(roll)
//   calculateDegreesFromZero(initial, current) → 0-based from start
//   Sensor rate: 30 Hz   |   Reference frame: xArbitraryZVertical
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
class MotionManager: ObservableObject {

    /// Horizontal rotation from starting position (0–360°, clockwise).
    /// Matches Flutter's `deviceHorizontalDegManipulated`.
    @Published var horizontalDeg: Double = 0

    /// Pitch in degrees. ≈75° when held at natural viewing angle.
    /// Matches Flutter's `deviceVerticalDeg`.
    @Published var verticalDeg: Double = 75

    /// Roll in degrees (tilt left/right). 0 = level.
    /// Matches Flutter's `deviceRotationDeg`.
    @Published var rollDeg: Double = 0

    @Published var isAvailable = false

    private let motion = CMMotionManager()
    /// Matches Flutter's `deviceHorizontalDegInitial`
    private var initialHorizontalDeg: Double?

    func start() {
        guard motion.isDeviceMotionAvailable else {
            isAvailable = false
            return
        }
        isAvailable = true
        initialHorizontalDeg = nil

        // 30 Hz — matching Flutter: Duration.microsecondsPerSecond ~/ 30
        motion.deviceMotionUpdateInterval = 1.0 / 30.0

        // xArbitraryZVertical — matching Flutter's dchs_motion_sensors on iOS
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] dm, _ in
            guard let self, let dm else { return }

            let yawRad  = dm.attitude.yaw
            let pitchRad = dm.attitude.pitch
            let rollRad  = dm.attitude.roll

            // ── Horizontal: (360 - degrees(yaw + roll) % 360) ──
            // Dart's % on doubles always returns non-negative; Swift's doesn't.
            let rawDeg = (yawRad + rollRad) * 180.0 / .pi
            var mod = rawDeg.truncatingRemainder(dividingBy: 360.0)
            if mod < 0 { mod += 360.0 }
            var deviceHorizontalDeg = 360.0 - mod
            if deviceHorizontalDeg >= 360.0 { deviceHorizontalDeg -= 360.0 }

            // Store initial reading once
            if self.initialHorizontalDeg == nil {
                self.initialHorizontalDeg = deviceHorizontalDeg
            }

            // calculateDegreesFromZero — exact port
            let initial = self.initialHorizontalDeg!
            var manipulated: Double
            if deviceHorizontalDeg >= 0 && deviceHorizontalDeg < initial {
                manipulated = deviceHorizontalDeg + (360.0 - initial)
            } else {
                manipulated = deviceHorizontalDeg - initial
            }
            if manipulated < 0   { manipulated += 360.0 }
            if manipulated >= 360 { manipulated -= 360.0 }

            self.horizontalDeg = manipulated

            // ── Vertical: degrees(pitch) ──
            self.verticalDeg = pitchRad * 180.0 / .pi

            // ── Roll: degrees(roll) ──
            self.rollDeg = rollRad * 180.0 / .pi
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        initialHorizontalDeg = nil
        horizontalDeg = 0
        verticalDeg = 75
        rollDeg = 0
    }

    func resetReference() {
        initialHorizontalDeg = nil
    }
}
