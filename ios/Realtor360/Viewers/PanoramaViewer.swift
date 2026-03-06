import SwiftUI
import SceneKit

/// 360° panorama viewer using a SceneKit sphere with an equirectangular texture.
struct PanoramaViewer: View {
    let imageURL: URL?
    let imageData: Data?
    @Environment(\.dismiss) private var dismiss

    init(imageURL: URL? = nil, imageData: Data? = nil) {
        self.imageURL = imageURL
        self.imageData = imageData
    }

    /// Convenience: load from a CaptureSession (local file or remote URL)
    init(session: CaptureSession) {
        if let panoramaURL = session.panoramaURL,
           let url = URL(string: panoramaURL),
           !panoramaURL.hasPrefix("mock://") {
            // 1. Real remote panorama URL (live backend)
            self.imageURL = url
            self.imageData = nil
        } else if let data = FileHelper.loadPanorama(sessionId: session.id) {
            // 2. Locally-stitched panorama (on-device compositor)
            self.imageURL = nil
            self.imageData = data
        } else {
            // 3. Fallback: first raw capture (better than nothing)
            self.imageURL = nil
            self.imageData = FileHelper.loadCapture(sessionId: session.id, step: 1)
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            PanoramaSceneView(imageURL: imageURL, imageData: imageData)
                .ignoresSafeArea()

            // Close button
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.5))
            }
            .padding(.top, 12)
            .padding(.leading, 16)
        }
    }
}

// MARK: - SceneKit Panorama

private struct PanoramaSceneView: UIViewRepresentable {
    let imageURL: URL?
    let imageData: Data?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.scene = SCNScene()
        scnView.backgroundColor = .black
        scnView.allowsCameraControl = false  // we handle all gestures manually
        scnView.isPlaying = true

        // Camera at the centre of the sphere — never moves
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 70
        cameraNode.camera?.zNear = 0.1
        cameraNode.camera?.zFar = 110
        cameraNode.position = SCNVector3(0, 0, 0)
        scnView.scene?.rootNode.addChildNode(cameraNode)
        scnView.pointOfView = cameraNode
        context.coordinator.cameraNode = cameraNode

        // Sphere geometry (viewed from inside)
        let sphere = SCNSphere(radius: 50)
        sphere.segmentCount = 96

        let material = SCNMaterial()
        material.isDoubleSided = true
        material.lightingModel = .constant               // show texture as-is, no lighting
        material.diffuse.contentsTransform = SCNMatrix4MakeScale(-1, 1, 1)
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .clamp

        // Load texture
        if let data = imageData, let image = UIImage(data: data) {
            material.diffuse.contents = image
        } else if let url = imageURL {
            material.diffuse.contents = UIColor.darkGray
            Task {
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    if let img = UIImage(data: data) {
                        await MainActor.run { material.diffuse.contents = img }
                    }
                } catch {
                    print("PanoramaViewer: failed to load image – \(error)")
                }
            }
        } else {
            material.diffuse.contents = UIColor.darkGray
        }

        sphere.materials = [material]
        scnView.scene?.rootNode.addChildNode(SCNNode(geometry: sphere))

        // Pan gesture → look around (rotate camera euler angles)
        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        scnView.addGestureRecognizer(pan)

        // Pinch gesture → zoom (change FOV, camera stays at origin)
        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )
        scnView.addGestureRecognizer(pinch)

        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    // MARK: - Coordinator (manual gesture handling)

    class Coordinator: NSObject {
        var cameraNode: SCNNode?

        // Rotation state (degrees)
        private var yaw: Float = 0
        private var pitch: Float = 0
        private var panStartYaw: Float = 0
        private var panStartPitch: Float = 0

        // Inertia
        private var displayLink: CADisplayLink?
        private var velocityX: Float = 0
        private var velocityY: Float = 0
        private let friction: Float = 0.92

        // Zoom
        private var baseFOV: CGFloat = 70

        // ── Pan (look around) ──────────────────────────────────────────

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let view = g.view else { return }
            let t = g.translation(in: view)
            let sensitivity: Float = 0.18

            switch g.state {
            case .began:
                stopInertia()
                panStartYaw = yaw
                panStartPitch = pitch
            case .changed:
                yaw   = panStartYaw   - Float(t.x) * sensitivity
                pitch = clamp(panStartPitch + Float(t.y) * sensitivity, -89, 89)
                applyRotation()
            case .ended, .cancelled:
                let v = g.velocity(in: view)
                velocityX = -Float(v.x) * sensitivity * 0.016
                velocityY =  Float(v.y) * sensitivity * 0.016
                startInertia()
            default: break
            }
        }

        // ── Pinch (zoom FOV — never moves the camera) ──────────────────

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard let cam = cameraNode?.camera else { return }
            switch g.state {
            case .began:
                baseFOV = cam.fieldOfView
            case .changed:
                // Pinch out (scale > 1) → zoom in (smaller FOV)
                cam.fieldOfView = min(120, max(30, baseFOV / g.scale))
            default: break
            }
        }

        // ── Helpers ─────────────────────────────────────────────────────

        private func applyRotation() {
            cameraNode?.eulerAngles = SCNVector3(
                pitch * .pi / 180,
                yaw   * .pi / 180,
                0
            )
        }

        private func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
            min(hi, max(lo, v))
        }

        // ── Inertia (smooth deceleration after finger lift) ────────────

        private func startInertia() {
            stopInertia()
            let link = CADisplayLink(target: self, selector: #selector(inertiaStep))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func stopInertia() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func inertiaStep() {
            velocityX *= friction
            velocityY *= friction
            if abs(velocityX) < 0.01 && abs(velocityY) < 0.01 {
                stopInertia()
                return
            }
            yaw   += velocityX
            pitch  = clamp(pitch + velocityY, -89, 89)
            applyRotation()
        }

        deinit {
            displayLink?.invalidate()
        }
    }
}
