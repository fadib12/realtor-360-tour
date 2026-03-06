import SwiftUI
import ARKit

// ─────────────────────────────────────────────────────────────────────────────
// Guided 360° Capture — Immersive Globe Interface
//
// The user sees the inside of a BLACK SPHERE with immersive guide overlays.
// Green dots are scattered across the sphere at 16 precise positions. As the
// user rotates their phone, the sphere
// rotates — dots move naturally around them. When aim aligns with
// a dot and the user holds steady, the photo auto-captures and that section
// of the sphere fills with the real image.
//
// After all 16 shots, the full sphere is built and the user can look around
// inside their completed 360° panorama before continuing.
//
// Architecture:
//   Background → LiveGlobeView (SceneKit sphere, black → fills with photos)
//   Reticle    → Center aim rings + hold progress
//   Dots       → 2D projected overlays (green circles on sphere surface)
//   Capture    → CaptureViewModel (alignment → hold → HDR bracket → globe)
// ─────────────────────────────────────────────────────────────────────────────

struct GuidedCaptureView: View {
    @ObservedObject var captureVM: CaptureViewModel
    let onComplete: () -> Void
    let onCancel: () -> Void

    @State private var timer: Timer?
    @State private var showFlash = false
    @State private var showDiscardAlert = false
    @State private var showInstructions = false
    @AppStorage("captureInstructionSeen") private var instructionSeen = false
    @State private var dontShowAgain = false
    @State private var showCompletionGlobe = false
    @State private var globeTimer: Timer?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let frameW = size.width * 0.82
            // Match portrait camera aspect (~3:4) so preview is not over-cropped/zoomed.
            let frameH = frameW * (4.0 / 3.0)
            let frameCenterY = size.height * 0.57
            let frameRect = CGRect(
                x: (size.width - frameW) / 2,
                y: frameCenterY - (frameH / 2),
                width: frameW,
                height: frameH
            )

            ZStack {
                // ── 1. Full-screen globe (black sphere, fills with photos) ──
                Color.black.ignoresSafeArea()

                if showCompletionGlobe {
                    LiveGlobeView(
                        deviceYaw: captureVM.cameraYawDeg,
                        devicePitch: captureVM.cameraPitchDeg,
                        globe: captureVM.globe
                    )
                    .ignoresSafeArea()
                }

                if !showCompletionGlobe {
                    // ── 2. Competitor-style framed camera area ──────────────
                    CameraFeedView(image: captureVM.arManager.cameraImage)
                        .frame(width: frameRect.width, height: frameRect.height)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color.white.opacity(0.88), lineWidth: 1.6)
                        )
                        .position(x: frameRect.midX, y: frameRect.midY)
                        .allowsHitTesting(false)

                    // ── 3. Progressive projected guide dots ─────────────────
                    ProjectedGuideDotsOverlay(
                        guideDots: captureVM.guideDots(for: frameRect.size),
                        activeGuideTargetID: captureVM.activeGuideTargetID,
                        progress: captureVM.holdProgress,
                        showCenterOnly: captureVM.nrPhotosTaken == 0,
                        isFirstShotEyeLevelValid: captureVM.isFirstShotEyeLevelValid,
                        isPositionWithinTolerance: captureVM.isPositionWithinTolerance,
                        frameRect: frameRect
                    )
                        .allowsHitTesting(false)

                    // ── 4. Flash overlay ────────────────────────────────────
                    if showFlash {
                        Color.white.opacity(0.3)
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                    }

                    // ── 5. Quality warning ──────────────────────────────────
                    if let warning = captureVM.qualityWarning {
                        Text(warning)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.yellow)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .position(x: size.width / 2, y: 120)
                            .transition(.opacity)
                            .animation(.easeInOut(duration: 0.3), value: captureVM.qualityWarning)
                    }

                    // ── 6. Top bar + Bottom bar ─────────────────────────────
                    VStack(spacing: 0) {
                        topBar
                        Spacer()
                        bottomBar
                    }
                }

                // ── 9. Completion globe (full-screen, look around) ──────────
                if showCompletionGlobe {
                    completionOverlay
                }

                // ── 10. Instruction modal (first launch) ────────────────────
                if showInstructions {
                    instructionOverlay
                }
            }
            .onAppear {
                startTimer()
                if !instructionSeen { showInstructions = true }
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .toolbar(.hidden, for: .tabBar)
        .onDisappear {
            timer?.invalidate()
            globeTimer?.invalidate()
        }
        .onChange(of: captureVM.isComplete) { _, done in
            if done {
                timer?.invalidate()
                // Start a lightweight timer for globe orientation tracking
                globeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
                    Task { @MainActor in captureVM.updateOrientationOnly() }
                }
                withAnimation(.easeInOut(duration: 0.6)) {
                    showCompletionGlobe = true
                }
            }
        }
        .onChange(of: captureVM.nrPhotosTaken) { old, new in
            if new > old { triggerFlash() }
        }
        .alert("Discard Capture?", isPresented: $showDiscardAlert) {
            Button("Discard", role: .destructive) { onCancel() }
            Button("Continue", role: .cancel) {}
        } message: {
            Text("You have \(captureVM.nrPhotosTaken) photos captured.")
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button { handleBack() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.black)
                    .frame(width: 48, height: 48)
                    .background(Color.white, in: Circle())
            }
            Spacer()
            Button { handleBack() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.red, in: Circle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 56)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 10) {
            let guidance = captureVM.nrPhotosTaken == 0
                ? (captureVM.needsFirstShotArming
                    ? "Move phone slightly, then align center dot at eye level"
                    : "Align center dot at eye level")
                : "Shoot all photos from the same spot as your initial\nphoto to ensure an optimal result."

            Text(guidance)
                .font(.system(size: 14, weight: .regular))
            .foregroundColor(.white.opacity(0.92))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: guidance)

            // Progress bar
            HStack(spacing: 10) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.3))
                        Capsule()
                            .fill(Color.green)
                            .frame(width: max(4, geo.size.width
                                * CGFloat(captureVM.nrPhotosTaken)
                                / CGFloat(captureVM.nrPhotos)))
                            .animation(.easeInOut(duration: 0.35), value: captureVM.nrPhotosTaken)
                    }
                }
                .frame(height: 14)

                Text("\(captureVM.nrPhotosTaken) of \(captureVM.nrPhotos)")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .fixedSize()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Completion Overlay (look around your sphere)

    private var completionOverlay: some View {
        // The globe is already showing as the full-screen background.
        // Camera preview is hidden. User can look around in their sphere.
        VStack {
            Spacer()

            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.green)

                Text("Capture Complete!")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)

                Text("Look around to explore your 360° sphere")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.7))
            }

            Spacer()

            Button {
                globeTimer?.invalidate()
                captureVM.stopCapture()
                onComplete()
            } label: {
                Text("Continue")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Color.green, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
        .transition(.opacity)
    }

    // MARK: - Instruction Modal (first-launch)

    private var instructionOverlay: some View {
        ZStack {
            Color.black.opacity(0.65)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Text("How to capture")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.black)

                ZStack {
                    Image(systemName: "globe")
                        .font(.system(size: 80))
                        .foregroundColor(.blue.opacity(0.6))

                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 40))
                        .foregroundColor(.blue.opacity(0.4))
                        .offset(y: 22)
                }
                .frame(height: 140)

                VStack(spacing: 12) {
                    instructionRow(icon: "viewfinder",
                                   text: "Align the center reticle with green dots")
                    instructionRow(icon: "camera.fill",
                                   text: "Hold steady — photos auto-capture")
                    instructionRow(icon: "arrow.triangle.2.circlepath",
                                   text: "Rotate to scan all directions")
                    instructionRow(icon: "globe",
                                   text: "Build a full 360° sphere of your room")
                }

                HStack(spacing: 8) {
                    Image(systemName: dontShowAgain ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundColor(dontShowAgain ? .blue : .gray.opacity(0.5))
                    Text("Don't show again")
                        .font(.system(size: 15))
                        .foregroundColor(.gray)
                }
                .onTapGesture { dontShowAgain.toggle() }

                Button {
                    if dontShowAgain { instructionSeen = true }
                    withAnimation(.easeOut(duration: 0.25)) { showInstructions = false }
                } label: {
                    Text("Got it")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.black, in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 20)
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.white)
            )
            .padding(.horizontal, 44)
        }
    }

    private func instructionRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(.blue)
                .frame(width: 32)
            Text(text)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.black)
            Spacer()
        }
    }

    // MARK: - Helpers

    // No-op helper removed (using projected guide dots overlay).

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            Task { @MainActor in captureVM.updateFrame() }
        }
    }

    private func triggerFlash() {
        showFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.2)) { showFlash = false }
        }
    }

    private func handleBack() {
        if captureVM.nrPhotosTaken == 0 { onCancel() }
        else { showDiscardAlert = true }
    }

    private func hintIcon(_ hint: String) -> String {
        if hint.contains("right") { return "arrow.turn.right.up" }
        if hint.contains("left")  { return "arrow.turn.left.up" }
        if hint.contains("up")    { return "arrow.up" }
        if hint.contains("down")  { return "arrow.down" }
        if hint.contains("capture spot") || hint.contains("Move Back") { return "location.north.line.fill" }
        if hint.contains("upright") || hint.contains("Tilted") { return "arrow.clockwise.circle.fill" }
        if hint.contains("eye level") { return "eye.fill" }
        if hint.contains("still") { return "hand.raised.fill" }
        if hint.contains("tracking") || hint.contains("initialize") { return "scope" }
        return "arrow.triangle.2.circlepath"
    }
}

// MARK: - Projected Guide Dots

/// Teleport-style guide dots:
/// - Shot 1: fixed center circle + dot, eye-level gated.
/// - Remaining shots: projected moving dots from AR target directions.
private struct ProjectedGuideDotsOverlay: View {
    let guideDots: [GuideDot]
    let activeGuideTargetID: Int?
    let progress: Double
    let showCenterOnly: Bool
    let isFirstShotEyeLevelValid: Bool
    let isPositionWithinTolerance: Bool
    let frameRect: CGRect

    var body: some View {
        GeometryReader { _ in
            let center = CGPoint(x: frameRect.midX, y: frameRect.midY)
            let centerReady = isFirstShotEyeLevelValid && isPositionWithinTolerance

            ZStack {
                if showCenterOnly {
                    Circle()
                        .stroke(Color.white.opacity(0.94), lineWidth: 5)
                        .frame(width: 108, height: 108)
                        .position(center)

                    Circle()
                        .fill(Color.green.opacity(centerReady ? 0.95 : 0.45))
                        .frame(width: 42, height: 42)
                        .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 2))
                        .position(center)

                    if centerReady {
                        Circle()
                            .trim(from: 0, to: max(0.02, progress))
                            .stroke(Color.green, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                            .frame(width: 122, height: 122)
                            .rotationEffect(.degrees(-90))
                            .animation(.easeInOut(duration: 0.12), value: progress)
                            .position(center)
                    }
                } else {
                    // Fixed center reticle (dot moves into ring for capture).
                    Circle()
                        .stroke(Color.white.opacity(0.94), lineWidth: 5)
                        .frame(width: 108, height: 108)
                        .position(center)

                    Circle()
                        .trim(from: 0, to: max(0.02, progress))
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .frame(width: 122, height: 122)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.08), value: progress)
                        .position(center)

                    ForEach(guideDots) { dot in
                        let absolute = absolutePoint(dot.screenPoint)
                        Circle()
                            .fill(Color.green.opacity(dot.isActive ? 0.98 : 0.72))
                            .frame(width: dot.isActive ? 42 : 36, height: dot.isActive ? 42 : 36)
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(dot.isActive ? 0.95 : 0.72),
                                            lineWidth: dot.isActive ? 3 : 1.5)
                            )
                            .shadow(color: .black.opacity(0.35), radius: 5, x: 0, y: 2)
                            .position(absolute)
                            .animation(.easeInOut(duration: 0.12), value: absolute)
                    }

                    if let active = guideDots.first(where: { $0.id == activeGuideTargetID }) {
                        let absolute = absolutePoint(active.screenPoint)
                        let dx = absolute.x - center.x
                        let dy = absolute.y - center.y
                        let distance = max(0.001, hypot(dx, dy))
                        let ux = dx / distance
                        let uy = dy / distance

                        if distance > 58 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 30, weight: .bold))
                                .foregroundColor(.white)
                                .rotationEffect(.degrees(atan2(uy, ux) * 180.0 / .pi))
                                .position(
                                    x: center.x + ux * 76,
                                    y: center.y + uy * 76
                                )
                                .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)
                        }
                    }
                }
            }
        }
    }

    private func absolutePoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: frameRect.minX + point.x, y: frameRect.minY + point.y)
    }
}
