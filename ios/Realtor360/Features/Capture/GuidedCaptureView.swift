import SwiftUI
import ARKit

// ─────────────────────────────────────────────────────────────────────────────
// Guided 360° Capture — Layered Sphere Scanner
//
// Architecture:
//   Layer 0  → Black (always)
//   Layer 1  → Globe sphere (always visible, tracks orientation)
//              During initialLock: live camera warped into sphere texture
//              After captures: captured photos stitched into sphere texture
//   Layer 2  → Targeting square (white border aim guide, always visible)
//   Layer 3  → 3D-projected green target dots + fixed center capture ring
//              During initialLock: only active dot shown
//              After first capture: all uncaptured dots shown
//   Layer 4  → HUD (progress, guidance, warnings)
//   Completion → Opaque globe for look-around
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

            ZStack {
                Color.black.ignoresSafeArea()

                // ── Stitching spinner ───────────────────────────────
                if captureVM.phase == .stitching {
                    stitchingOverlay
                }

                // ── Completion: opaque sphere look-around ───────────
                if captureVM.phase == .completed && showCompletionGlobe {
                    LiveGlobeView(
                        deviceYaw: captureVM.cameraYawDeg,
                        devicePitch: captureVM.cameraPitchDeg,
                        globe: captureVM.globe
                    )
                    .ignoresSafeArea()
                }

                if captureVM.phase.isCapturing {

                    // ── Layer 1: Globe (always visible) ──
                    // During initialLock: live camera is warped into the sphere texture
                    // After captures: captured photos are stitched into sphere texture
                    LiveGlobeView(
                        deviceYaw: captureVM.cameraYawDeg,
                        devicePitch: captureVM.cameraPitchDeg,
                        globe: captureVM.globe
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                    // ── Layer 2: Targeting square (aim guide — always visible) ──
                    targetingSquare(screenSize: size)
                        .allowsHitTesting(false)

                    // ── Layer 3: 3D-projected dots + center ring ──
                    targetLockOverlay(screenSize: size)
                        .allowsHitTesting(false)
                        .onChange(of: captureVM.holdProgress) { old, new in
                            if new > 0.95 && old <= 0.95 {
                                HapticManager.success()
                            }
                        }

                    // Flash overlay
                    if showFlash {
                        Color.white.opacity(0.35)
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                    }

                    // Quality warning
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

                    // HUD
                    VStack(spacing: 0) {
                        topBar
                        Spacer()
                        bottomBar
                    }
                }

                // ── Completion overlay ─────────────────────────────
                if captureVM.phase == .completed && showCompletionGlobe {
                    completionOverlay
                }

                // ── Instruction modal ──────────────────────────────
                if showInstructions {
                    instructionOverlay
                }
            }
            .onAppear {
                captureVM.setGuideViewportSize(size)
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
        .onChange(of: captureVM.phase) { _, newPhase in
            if newPhase == .stitching {
                timer?.invalidate()
            }
            if newPhase == .completed {
                globeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
                    Task { @MainActor in captureVM.updateOrientationOnly() }
                }
                withAnimation(.easeInOut(duration: 0.6)) {
                    showCompletionGlobe = true
                }
            }
        }
        .onChange(of: captureVM.isComplete) { old, new in }
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

            Text(captureVM.arManager.selectedLensLabel)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))

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
            let guidance: String = {
                switch captureVM.phase {
                case .initialLock:
                    return "Align the dot with the center ring"
                case .firstCaptureCommitted:
                    return "Shoot all photos from the same spot as your initial photo to ensure an optimal result."
                case .guidedContinuation:
                    return captureVM.directionHint
                        ?? "Shoot all photos from the same spot as your initial photo to ensure an optimal result."
                case .stitching:
                    return "Building your 360° panorama…"
                case .completed:
                    return ""
                }
            }()

            Text(guidance)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.15), value: guidance)

            HStack(spacing: 10) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.2))
                        Capsule()
                            .fill(Color.green)
                            .frame(width: max(4, geo.size.width
                                * CGFloat(captureVM.nrPhotosTaken)
                                / CGFloat(captureVM.nrPhotos)))
                            .animation(.easeInOut(duration: 0.35), value: captureVM.nrPhotosTaken)
                    }
                }
                .frame(height: 10)

                Text("\(captureVM.nrPhotosTaken) of \(captureVM.nrPhotos)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                    .fixedSize()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Stitching Overlay

    private var stitchingOverlay: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 120, height: 120)
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
            VStack(spacing: 8) {
                Text("Building Panorama")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                Text("Stitching 16 photos into a 360° equirectangular panorama…")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            Spacer()
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.4), value: captureVM.phase)
    }

    // MARK: - Completion Overlay

    private var completionOverlay: some View {
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

    // MARK: - Instruction Modal

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

    // MARK: - Targeting Square (aim guide — always visible)

    @ViewBuilder
    private func targetingSquare(screenSize: CGSize) -> some View {
        let windowW = screenSize.width * 0.78
        let windowH = min(windowW / 0.75, screenSize.height * 0.55)
        let adjustedW = windowH * 0.75

        RoundedRectangle(cornerRadius: 3)
            .stroke(Color.white.opacity(0.5), lineWidth: 2)
            .frame(width: adjustedW, height: windowH)
            .position(x: screenSize.width / 2, y: screenSize.height / 2)
    }

    // MARK: - Target Lock Overlay (3D-Projected Dots)

    @ViewBuilder
    private func targetLockOverlay(screenSize: CGSize) -> some View {
        let ringCenter = CGPoint(x: screenSize.width / 2, y: screenSize.height / 2)
        let dots = captureVM.visibleTargetDots(screenSize: screenSize)
        let isInitialLock = captureVM.phase == .initialLock

        ZStack {
            ForEach(dots) { dot in
                if !dot.isCaptured {
                    // During initialLock: show ONLY the active dot
                    // After first capture: show all uncaptured dots
                    if !isInitialLock || dot.isActive {
                        Circle()
                            .fill(Color.green)
                            .frame(
                                width: dot.isActive ? 48 : 40,
                                height: dot.isActive ? 48 : 40
                            )
                            .shadow(color: .green.opacity(0.6), radius: dot.isActive ? 12 : 6)
                            .position(dot.screenPoint)
                    }
                }
            }

            centerRing(at: ringCenter, progress: captureVM.holdProgress)

            if let activeDot = dots.first(where: { $0.isActive && !$0.isCaptured }) {
                directionChevron(dotPosition: activeDot.screenPoint, ringCenter: ringCenter)
            }
        }
    }

    private func centerRing(at center: CGPoint, progress: Double) -> some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.9), lineWidth: 4)
                .frame(width: 100, height: 100)
                .position(center)

            if progress > 0.01 {
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 114, height: 114)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.12), value: progress)
                    .position(center)
            }
        }
    }

    @ViewBuilder
    private func directionChevron(dotPosition: CGPoint, ringCenter: CGPoint) -> some View {
        let dx = dotPosition.x - ringCenter.x
        let dy = dotPosition.y - ringCenter.y
        let dist = hypot(dx, dy)

        if dist > 58 {
            let ux = dx / dist
            let uy = dy / dist

            Image(systemName: "chevron.right")
                .font(.system(size: 24, weight: .heavy))
                .foregroundColor(.white.opacity(0.85))
                .rotationEffect(.degrees(Double(atan2(uy, ux)) * 180.0 / .pi))
                .position(
                    x: ringCenter.x + ux * 58,
                    y: ringCenter.y + uy * 58
                )
                .shadow(color: .black.opacity(0.6), radius: 4)
        }
    }

    // MARK: - Helpers

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
}

