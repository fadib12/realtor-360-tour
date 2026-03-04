import SwiftUI

struct TargetDotView: View {
    let targetYaw: Double
    let targetPitch: Double
    let currentYaw: Double
    let currentPitch: Double
    let isAligned: Bool
    
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let dotPosition = calculateDotPosition(in: size)
            
            ZStack {
                // Target dot
                Circle()
                    .fill(isAligned ? Color.green : Color.white)
                    .frame(width: dotSize, height: dotSize)
                    .overlay(
                        Circle()
                            .stroke(Color.white, lineWidth: 3)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
                    .position(dotPosition)
                
                // Alignment ring (appears when aligned)
                if isAligned {
                    Circle()
                        .stroke(Color.green, lineWidth: 4)
                        .frame(width: dotSize + 20, height: dotSize + 20)
                        .position(dotPosition)
                        .modifier(PulseModifier())
                }
                
                // Direction indicator arrow
                if !isAligned {
                    DirectionArrow(
                        from: CGPoint(x: size.width / 2, y: size.height / 2),
                        to: dotPosition,
                        size: size
                    )
                }
                
                // Center crosshair
                Crosshair()
                    .position(x: size.width / 2, y: size.height / 2)
            }
        }
    }
    
    private var dotSize: CGFloat { 50 }
    
    private func calculateDotPosition(in size: CGSize) -> CGPoint {
        // Calculate where the target dot should appear on screen
        // based on the difference between current and target orientation
        
        let yawDiff = normalizeAngle(targetYaw - currentYaw)
        let pitchDiff = targetPitch - currentPitch
        
        // Map orientation difference to screen position
        // Assuming roughly 60° field of view
        let fovH: Double = 60
        let fovV: Double = 80  // Portrait mode
        
        let xOffset = (yawDiff / fovH) * Double(size.width)
        let yOffset = -(pitchDiff / fovV) * Double(size.height)  // Invert Y
        
        // Clamp to screen bounds with margin
        let margin: CGFloat = 40
        let x = max(margin, min(size.width - margin, size.width / 2 + CGFloat(xOffset)))
        let y = max(margin, min(size.height - margin, size.height / 2 + CGFloat(yOffset)))
        
        return CGPoint(x: x, y: y)
    }
    
    private func normalizeAngle(_ angle: Double) -> Double {
        var normalized = angle
        while normalized > 180 { normalized -= 360 }
        while normalized < -180 { normalized += 360 }
        return normalized
    }
}

// MARK: - Crosshair

struct Crosshair: View {
    var body: some View {
        ZStack {
            // Horizontal line
            Rectangle()
                .fill(Color.white.opacity(0.5))
                .frame(width: 30, height: 2)
            
            // Vertical line
            Rectangle()
                .fill(Color.white.opacity(0.5))
                .frame(width: 2, height: 30)
            
            // Center dot
            Circle()
                .fill(Color.white.opacity(0.8))
                .frame(width: 6, height: 6)
        }
    }
}

// MARK: - Direction Arrow

struct DirectionArrow: View {
    let from: CGPoint
    let to: CGPoint
    let size: CGSize
    
    var body: some View {
        // Only show arrow if target is significantly off-screen
        let dx = to.x - from.x
        let dy = to.y - from.y
        let distance = sqrt(dx * dx + dy * dy)
        
        if distance > 100 {
            Path { path in
                // Arrow pointing from center toward target
                let angle = atan2(dy, dx)
                let arrowLength: CGFloat = 40
                let arrowStart = CGPoint(
                    x: from.x + cos(angle) * 60,
                    y: from.y + sin(angle) * 60
                )
                let arrowEnd = CGPoint(
                    x: arrowStart.x + cos(angle) * arrowLength,
                    y: arrowStart.y + sin(angle) * arrowLength
                )
                
                path.move(to: arrowStart)
                path.addLine(to: arrowEnd)
                
                // Arrowhead
                let headLength: CGFloat = 15
                let headAngle: CGFloat = .pi / 6
                
                path.move(to: arrowEnd)
                path.addLine(to: CGPoint(
                    x: arrowEnd.x - headLength * cos(angle - headAngle),
                    y: arrowEnd.y - headLength * sin(angle - headAngle)
                ))
                
                path.move(to: arrowEnd)
                path.addLine(to: CGPoint(
                    x: arrowEnd.x - headLength * cos(angle + headAngle),
                    y: arrowEnd.y - headLength * sin(angle + headAngle)
                ))
            }
            .stroke(Color.white.opacity(0.6), lineWidth: 3)
        }
    }
}

// MARK: - Pulse Animation

struct PulseModifier: ViewModifier {
    @State private var isPulsing = false
    
    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.2 : 1.0)
            .opacity(isPulsing ? 0.5 : 1.0)
            .animation(
                .easeInOut(duration: 0.5)
                .repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear {
                isPulsing = true
            }
    }
}

#Preview {
    ZStack {
        Color.black
        TargetDotView(
            targetYaw: 45,
            targetPitch: 0,
            currentYaw: 30,
            currentPitch: 5,
            isAligned: false
        )
    }
}
