import SwiftUI
import SceneKit

// ─────────────────────────────────────────────────────────────────────────────
// Live Globe View — Immersive panorama-building background for guided capture.
//
// During the 16-photo full-sphere capture, this view renders a SceneKit sphere
// from the inside. Each captured photo is composited onto a growing
// equirectangular texture at its correct (yaw, elevation) position — including
// ceiling and floor. Photos near the poles are stretched wider to match the
// equirectangular projection. The camera inside the sphere tracks the user's
// real device orientation, so the user sees the black void gradually fill
// with their captured surroundings — like building a world from within.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - LiveGlobeView (SwiftUI wrapper)

struct LiveGlobeView: UIViewRepresentable {
    /// Current device yaw in degrees (0–360) from CaptureViewModel.
    let deviceYaw: Double
    /// Current device pitch from CaptureViewModel.
    let devicePitch: Double
    /// The SceneKit globe scene coordinator (shared, updated by CaptureViewModel).
    let globe: GlobeSceneController

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.scene = globe.scene
        scnView.pointOfView = globe.cameraNode
        scnView.backgroundColor = .clear
        scnView.isPlaying = true
        scnView.rendersContinuously = true
        scnView.allowsCameraControl = false   // we drive the camera manually
        scnView.autoenablesDefaultLighting = false
        scnView.isUserInteractionEnabled = false
        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        globe.updateCamera(yawDeg: deviceYaw, pitchDeg: devicePitch)
    }
}

// MARK: - GlobeSceneController

/// Manages the SceneKit sphere + camera for the live globe effect.
/// Created once per capture session and shared between CaptureViewModel
/// (which feeds captured images) and LiveGlobeView (which renders).
@MainActor
class GlobeSceneController: ObservableObject {

    let scene = SCNScene()
    let cameraNode = SCNNode()

    private let sphereNode = SCNNode()
    private let material = SCNMaterial()
    /// 3D dot nodes placed on the sphere surface at capture target positions.
    private var dotNodes: [Int: SCNNode] = [:]
    /// Ring (torus) nodes around each dot — animated when aligned.
    private var ringNodes: [Int: SCNNode] = [:]
    /// Ring progress geometry for animated fill.
    private var ringProgress: [Int: CGFloat] = [:]
    /// Dot IDs currently visible in the guidance step.
    private var visibleDotIDs: Set<Int> = []
    /// Dot IDs that already have captured photos.
    private var capturedDotIDs: Set<Int> = []

    // ── Equirectangular canvas (built up incrementally) ─────────────────
    private let canvasWidth  = 2048
    private let canvasHeight = 1024
    private var canvasContext: CGContext?
    private var featherMask: CGImage?

    // ── Photo placement constants (portrait mode, spec: ~70° HFOV ~55° VFOV) ──
    private let cameraHFOV: CGFloat = 55.0         // portrait width ≈ 55°
    private let cameraVFOV: CGFloat = 70.0         // portrait height ≈ 70°
    /// Sphere radius matching the geometry.
    private let sphereRadius: Float = 50.0

    /// Number of photos composited so far.
    @Published var photoCount: Int = 0

    // MARK: - Init

    init() {
        setupScene()
        setupCanvas()
    }

    // MARK: - Setup

    private func setupScene() {
        // Sphere surrounding the camera (viewed from inside)
        let sphere = SCNSphere(radius: 50)
        sphere.segmentCount = 64

        material.isDoubleSided = true
        material.lightingModel = .constant      // no lighting — show texture as-is
        material.diffuse.contents = UIColor.black
        material.diffuse.contentsTransform = SCNMatrix4MakeScale(-1, 1, 1)  // flip for interior
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .clamp

        sphere.materials = [material]
        sphereNode.geometry = sphere
        scene.rootNode.addChildNode(sphereNode)

        // Camera at center
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 75
        cameraNode.camera?.zNear = 0.1
        cameraNode.camera?.zFar = 110
        cameraNode.position = SCNVector3(0, 0, 0)
        scene.rootNode.addChildNode(cameraNode)
    }

    private func setupCanvas() {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        canvasContext = CGContext(
            data: nil,
            width: canvasWidth,
            height: canvasHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )

        // Start with a fully black canvas
        canvasContext?.setFillColor(UIColor.black.cgColor)
        canvasContext?.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))

        // Pre-create the feather mask (reused for all photos)
        featherMask = createFeatherMask(width: 256, height: 256, edgeFraction: 0.28)
    }

    // MARK: - Add a captured photo to the globe

    /// Composites a JPEG photo at the given angular position on the sphere.
    /// Called from CaptureViewModel after each successful capture.
    func addPhoto(imageData: Data, yawDeg: Double, elevationDeg: Double) {
        guard let ctx = canvasContext,
              let uiImage = UIImage(data: imageData),
              let cgImage = uiImage.cgImage else { return }

        // Equirectangular placement — stretch width near poles
        let cosElev = max(cos(CGFloat(elevationDeg) * .pi / 180.0), 0.18)
        let photoWidthPx  = (cameraHFOV / 360.0) * CGFloat(canvasWidth) / cosElev
        let photoHeightPx = (cameraVFOV / 180.0) * CGFloat(canvasHeight)

        let centerX = (CGFloat(yawDeg) / 360.0) * CGFloat(canvasWidth)
        // CG origin is bottom-left: +elevation → higher Y
        let centerY = CGFloat(canvasHeight) * (0.5 + CGFloat(elevationDeg) / 180.0)

        let left   = centerX - photoWidthPx / 2.0
        let bottom = centerY - photoHeightPx / 2.0

        let rect = CGRect(x: left, y: bottom, width: photoWidthPx, height: photoHeightPx)

        // Draw with feather mask
        if let mask = featherMask {
            drawMasked(ctx: ctx, image: cgImage, rect: rect, mask: mask)

            // Handle 360° wrap-around
            if left < 0 {
                drawMasked(ctx: ctx, image: cgImage,
                           rect: rect.offsetBy(dx: CGFloat(canvasWidth), dy: 0),
                           mask: mask)
            }
            if left + photoWidthPx > CGFloat(canvasWidth) {
                drawMasked(ctx: ctx, image: cgImage,
                           rect: rect.offsetBy(dx: -CGFloat(canvasWidth), dy: 0),
                           mask: mask)
            }
        }

        // Update the sphere texture
        if let cgResult = ctx.makeImage() {
            let texture = UIImage(cgImage: cgResult)
            material.diffuse.contents = texture
        }

        photoCount += 1
    }

    // MARK: - Camera orientation (driven by device sensors)

    /// Rotate the internal camera to match the user's physical orientation.
    /// pitchDeg: 0 = horizon, +up, −down (real pitch, not offset).
    func updateCamera(yawDeg: Double, pitchDeg: Double) {
        // Yaw: rotate around Y axis. Negate for SceneKit CCW convention.
        // Offset by 180° so camera starts facing the "front" of the sphere texture.
        let yawRad = Float((-yawDeg + 180.0) * .pi / 180.0)
        // Pitch: direct mapping from real pitch degrees.
        let pitchRad = Float(pitchDeg * .pi / 180.0)
        cameraNode.eulerAngles = SCNVector3(pitchRad, yawRad, 0)
    }

    // MARK: - Reset (new capture session)

    func reset() {
        canvasContext?.setFillColor(UIColor.black.cgColor)
        canvasContext?.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        material.diffuse.contents = UIColor.black
        photoCount = 0

        // Remove old dot and ring nodes
        for (_, node) in dotNodes { node.removeFromParentNode() }
        for (_, node) in ringNodes { node.removeFromParentNode() }
        dotNodes.removeAll()
        ringNodes.removeAll()
        ringProgress.removeAll()
        visibleDotIDs.removeAll()
        capturedDotIDs.removeAll()
    }

    // MARK: - Dot Management (3D dots on the sphere surface)

    /// Place green dot spheres on the globe at each capture target position,
    /// each with a white ring around it for alignment/capture animation.
    func addDotNodes(targets: [(id: Int, yawDeg: Double, pitchDeg: Double)]) {
        for t in targets {
            // ── Green dot ───────────────────────────────────────────────
            let dot = SCNSphere(radius: 1.2)
            dot.segmentCount = 16
            let dotMat = SCNMaterial()
            dotMat.diffuse.contents = UIColor.green
            dotMat.lightingModel = .constant
            dot.materials = [dotMat]

            let node = SCNNode(geometry: dot)

            // Position on inner sphere surface
            let r = sphereRadius - 1.5
            let yawRad = Float(t.yawDeg) * .pi / 180.0
            let pitchRad = Float(t.pitchDeg) * .pi / 180.0

            let x = -r * cos(pitchRad) * sin(yawRad)
            let y =  r * sin(pitchRad)
            let z =  r * cos(pitchRad) * cos(yawRad)

            node.position = SCNVector3(x, y, z)
            scene.rootNode.addChildNode(node)
            dotNodes[t.id] = node

            // ── White ring (torus) around each dot ──────────────────────
            let torus = SCNTorus(ringRadius: 2.2, pipeRadius: 0.18)
            let ringMat = SCNMaterial()
            ringMat.diffuse.contents = UIColor.white
            ringMat.lightingModel = .constant
            torus.materials = [ringMat]

            let ringNode = SCNNode(geometry: torus)
            ringNode.position = SCNVector3(x, y, z)
            ringNode.opacity = 0.6

            // Orient ring to face toward center (camera position)
            // The ring should be flat on the sphere surface, facing inward
            let pos = simd_float3(x, y, z)
            let up = simd_float3(0, 1, 0)
            let normal = simd_normalize(-pos) // point toward center
            let right = simd_normalize(simd_cross(up, normal))
            let correctedUp = simd_cross(normal, right)
            // Build look-at rotation
            let col0 = simd_float4(right.x, right.y, right.z, 0)
            let col1 = simd_float4(correctedUp.x, correctedUp.y, correctedUp.z, 0)
            let col2 = simd_float4(normal.x, normal.y, normal.z, 0)
            let col3 = simd_float4(0, 0, 0, 1)
            ringNode.simdTransform = simd_float4x4(columns: (col0, col1, col2, col3))
            ringNode.simdPosition = pos

            scene.rootNode.addChildNode(ringNode)
            ringNodes[t.id] = ringNode
            ringProgress[t.id] = 0
        }

        // Hidden by default until CaptureViewModel sets active visibility.
        setVisibleDotIDs([])
    }

    func setVisibleDotIDs(_ ids: Set<Int>) {
        visibleDotIDs = ids
        for id in dotNodes.keys {
            applyVisibility(for: id)
        }
    }

    /// Update ring animation for the currently aligned dot.
    /// Called from CaptureViewModel each frame with the progress (0–1).
    func updateRingProgress(alignedId: Int?, progress: CGFloat) {
        for (id, ringNode) in ringNodes {
            let visibleAndPending = visibleDotIDs.contains(id) && !capturedDotIDs.contains(id)
            if !visibleAndPending {
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.1
                ringNode.opacity = 0
                ringNode.scale = SCNVector3(1, 1, 1)
                if let torus = ringNode.geometry as? SCNTorus {
                    torus.pipeRadius = 0.18
                }
                SCNTransaction.commit()
                continue
            }

            if id == alignedId {
                // Scale up the ring and make it bright green when aligned
                ringNode.opacity = 1.0
                ringNode.geometry?.firstMaterial?.diffuse.contents = UIColor.green

                // Animate scale based on progress (1.0 → 1.3)
                let s = Float(1.0 + 0.3 * progress)
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.05
                ringNode.scale = SCNVector3(s, s, s)
                if let torus = ringNode.geometry as? SCNTorus {
                    // Thicken the pipe as progress increases
                    torus.pipeRadius = CGFloat(0.18 + 0.22 * Float(progress))
                }
                SCNTransaction.commit()

                // Also pulse the dot
                if let dotNode = dotNodes[id] {
                    SCNTransaction.begin()
                    SCNTransaction.animationDuration = 0.05
                    dotNode.scale = SCNVector3(1.2, 1.2, 1.2)
                    dotNode.geometry?.firstMaterial?.diffuse.contents = UIColor(
                        red: 0, green: 1, blue: 0.3, alpha: 1
                    )
                    SCNTransaction.commit()
                }
            } else {
                // Reset non-aligned rings
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.15
                ringNode.opacity = 0.6
                ringNode.scale = SCNVector3(1, 1, 1)
                ringNode.geometry?.firstMaterial?.diffuse.contents = UIColor.white
                if let torus = ringNode.geometry as? SCNTorus {
                    torus.pipeRadius = 0.18
                }
                SCNTransaction.commit()

                // Reset dot scale
                if let dotNode = dotNodes[id], !(dotNode.geometry as? SCNSphere != nil && (dotNode.geometry as! SCNSphere).radius < 1.0) {
                    SCNTransaction.begin()
                    SCNTransaction.animationDuration = 0.15
                    dotNode.scale = SCNVector3(1, 1, 1)
                    dotNode.geometry?.firstMaterial?.diffuse.contents = UIColor.green
                    SCNTransaction.commit()
                }
            }
        }
    }

    /// Mark a dot as captured: shrink it, hide ring, change to translucent.
    func markDotCaptured(id: Int) {
        capturedDotIDs.insert(id)
        if let node = dotNodes[id] {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.3
            if let sphere = node.geometry as? SCNSphere {
                sphere.radius = 0.5
            }
            node.geometry?.firstMaterial?.diffuse.contents = UIColor.green.withAlphaComponent(0.3)
            node.scale = SCNVector3(1, 1, 1)
            SCNTransaction.commit()
        }
        if let ring = ringNodes[id] {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.3
            ring.opacity = 0
            SCNTransaction.commit()
        }

        applyVisibility(for: id)
    }

    // MARK: - Private drawing helpers

    private func drawMasked(ctx: CGContext, image: CGImage, rect: CGRect, mask: CGImage) {
        ctx.saveGState()
        ctx.clip(to: rect, mask: mask)
        ctx.draw(image, in: rect)
        ctx.restoreGState()
    }

    private func applyVisibility(for id: Int) {
        let isVisible = visibleDotIDs.contains(id)
        let isCaptured = capturedDotIDs.contains(id)

        if let dotNode = dotNodes[id] {
            if isCaptured {
                dotNode.opacity = isVisible ? 0.3 : 0.0
            } else {
                dotNode.opacity = isVisible ? 1.0 : 0.0
            }
        }

        if let ringNode = ringNodes[id] {
            ringNode.opacity = (isVisible && !isCaptured) ? 0.6 : 0.0
        }
    }

    /// Grayscale feather mask: white center (visible), black edges (transparent).
    private func createFeatherMask(width: Int, height: Int, edgeFraction: CGFloat) -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        let hMargin = Int(CGFloat(width) * edgeFraction)
        let vMargin = Int(CGFloat(height) * 0.10)

        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Left edge
        for x in 0..<hMargin {
            let t = CGFloat(x) / CGFloat(hMargin)
            let gray = 0.5 * (1.0 - cos(.pi * t))
            ctx.setFillColor(gray: gray, alpha: 1.0)
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        // Right edge
        for x in (width - hMargin)..<width {
            let t = CGFloat(width - 1 - x) / CGFloat(hMargin)
            let gray = 0.5 * (1.0 - cos(.pi * t))
            ctx.setFillColor(gray: gray, alpha: 1.0)
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        // Top/bottom edges
        ctx.setBlendMode(.multiply)
        for y in 0..<vMargin {
            let t = CGFloat(y) / CGFloat(vMargin)
            let gray = 0.5 * (1.0 - cos(.pi * t))
            ctx.setFillColor(gray: gray, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        for y in (height - vMargin)..<height {
            let t = CGFloat(height - 1 - y) / CGFloat(vMargin)
            let gray = 0.5 * (1.0 - cos(.pi * t))
            ctx.setFillColor(gray: gray, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }

        return ctx.makeImage()
    }
}
