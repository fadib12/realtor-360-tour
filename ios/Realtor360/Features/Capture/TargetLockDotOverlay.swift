import SwiftUI

/// Overlay for a single movable target dot relative to a fixed center ring.
struct TargetLockDotOverlay: View {
    let dot: GuideDot
    let center: CGPoint
    let progress: Double

    var body: some View {
        ZStack {
            // Movable target dot with glow and scale
            Circle()
                .fill(dot.isActive ? Color.green : Color.gray)
                .frame(width: progress > 0.95 ? 44 : 36, height: progress > 0.95 ? 44 : 36)
                .shadow(color: Color.green.opacity(progress > 0.95 ? 0.6 : 0.3), radius: progress > 0.95 ? 16 : 8)
                .position(dot.screenPoint)
                .overlay(
                    Circle()
                        .stroke(Color.white, lineWidth: dot.isActive ? 3 : 1)
                        .frame(width: progress > 0.95 ? 44 : 36, height: progress > 0.95 ? 44 : 36)
                        .position(dot.screenPoint)
                )

            // Lock-on feedback: highlight when dot is inside center ring
            if progress > 0.95 {
                Circle()
                    .stroke(Color.green, lineWidth: 6)
                    .frame(width: 60, height: 60)
                    .position(center)
                    .opacity(0.9)
                    .scaleEffect(1.1)
                    .animation(.easeInOut(duration: 0.2), value: progress)
            }
        }
    }
}
