import Foundation

struct CaptureStep {
    let index: Int              // 1-based
    let targetYawDegrees: Double
    let targetPitchDegrees: Double
    let toleranceDegrees: Double

    /// Generate 16 evenly-spaced steps around a 360° horizontal ring.
    static func defaultSteps(count: Int = 16) -> [CaptureStep] {
        let yawIncrement = 360.0 / Double(count)
        return (0..<count).map { i in
            CaptureStep(
                index: i + 1,
                targetYawDegrees: Double(i) * yawIncrement,
                targetPitchDegrees: 0,
                toleranceDegrees: 12
            )
        }
    }
}
