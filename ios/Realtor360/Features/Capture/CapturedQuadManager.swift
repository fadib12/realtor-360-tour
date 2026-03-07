import SwiftUI
import SceneKit
import ARKit
import simd

// ─────────────────────────────────────────────────────────────────────────────
// CapturedQuadManager — Lightweight World-Anchored Preview Panels
//
// After each photo capture, a LOW-RES preview image is placed as a textured
// 3D plane (quad) in world space at the ARKit camera pose from that shot.
//
// These panels are TEMPORARY visualization aids — the real product is the
// stitched 360° equirectangular from the full-res originals.
//
// Performance rules:
//   • Only low-res preview UIImages are used as textures (max ~1280px)
//   • Full-res data is never loaded into SceneKit
//   • Nodes are created once and not rebuilt
//   • Only nearby panels are rendered (visibility culling by angular distance)
//   • Material uses .constant lighting (no scene lighting artifacts)
//   • No HDR tonemapping, no additive blending, opaque rendering
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
class CapturedQuadManager: ObservableObject {

    let scene = SCNScene()
    let cameraNode = SCNNode()

    // ── Configuration ───────────────────────────────────────────────────────
    /// Distance (meters) at which captured quads are placed in front of the camera.
    private let quadDistance: Float = 3.5
    /// Scale factor applied to the calculated quad size.
    private let quadScale: Float = 1.05
    /// Maximum angular distance (degrees) from current camera forward for
    /// a panel to remain visible. Panels beyond this are hidden for perf.
    private let visibilityConeAngleDeg: Float = 120.0

    // ── State ───────────────────────────────────────────────────────────────
    /// Stored quads keyed by capture target ID.
    private var quadNodes: [Int: SCNNode] = [:]
    /// World-space forward direction at capture time (for visibility culling).
    private var quadDirections: [Int: simd_float3] = [:]
    /// Whether the camera FOV has been calibrated from ARKit intrinsics.
    private var fovCalibrated = false

    // MARK: - Init

    init() {
        setupScene()
    }

    private func setupScene() {
        scene.background.contents = UIColor.black

        let camera = SCNCamera()
        camera.zNear = 0.05
        camera.zFar = 100
        camera.fieldOfView = 60  // updated from ARKit on first frame
        camera.wantsHDR = false
        camera.colorGrading.contents = nil // no post-processing
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
    }

    // MARK: - Camera Tracking

    /// Synchronise the SceneKit camera to the live ARKit camera pose.
    /// Also performs visibility culling on existing panels.
    func updateCamera(transform: simd_float4x4, frame: ARFrame? = nil) {
        cameraNode.simdTransform = transform

        // Calibrate vertical FOV from ARKit projection matrix (once).
        if !fovCalibrated, let frame = frame {
            let proj = frame.camera.projectionMatrix(
                for: .portrait,
                viewportSize: CGSize(width: 390, height: 844),
                zNear: 0.05,
                zFar: 100
            )
            let fovYRad = 2.0 * atan(1.0 / Double(proj[1][1]))
            let fovYDeg = fovYRad * 180.0 / .pi
            if fovYDeg > 10 && fovYDeg < 120 {
                cameraNode.camera?.fieldOfView = CGFloat(fovYDeg)
                fovCalibrated = true
            }
        }

        // Visibility culling: hide panels far from current view direction
        let cameraForward = -simd_normalize(simd_make_float3(transform.columns.2))
        let cosCone = cos(visibilityConeAngleDeg * .pi / 180.0)
        for (id, direction) in quadDirections {
            guard let node = quadNodes[id] else { continue }
            let dot = simd_dot(cameraForward, direction)
            node.isHidden = dot < cosCone
        }
    }

    // MARK: - Add Captured Quad

    /// Place a low-res preview image as a textured 3D plane.
    ///
    /// - Parameters:
    ///   - id: Target ID (0–15) for deduplication.
    ///   - image: Pre-downscaled UIImage (~1280px max dimension).
    ///   - cameraTransform: The ARKit camera transform at capture time.
    func addQuad(id: Int, image: UIImage, cameraTransform: simd_float4x4) {
        guard quadNodes[id] == nil else { return }  // no duplicates

        let d = quadDistance

        // Calculate plane size to approximate camera FOV at placement distance
        let fovDeg = Float(cameraNode.camera?.fieldOfView ?? 60)
        let vfov = fovDeg * .pi / 180.0
        let height = 2.0 * d * tan(vfov / 2.0) * quadScale
        let aspect = Float(image.size.width / image.size.height)
        let width = height * aspect

        // ── Geometry ────────────────────────────────────────────────────
        let plane = SCNPlane(width: CGFloat(width), height: CGFloat(height))
        plane.cornerRadius = 0

        // Material: .constant lighting = no scene illumination artifacts.
        // Opaque, no transparency, no HDR tonemapping.
        let material = SCNMaterial()
        material.diffuse.contents = image
        material.diffuse.intensity = 1.0
        material.diffuse.magnificationFilter = .linear
        material.diffuse.minificationFilter = .linear
        material.diffuse.mipFilter = .linear
        material.isDoubleSided = false
        material.lightingModel = .constant
        material.transparency = 1.0
        material.blendMode = .replace  // fully opaque, no additive blending
        material.writesToDepthBuffer = true
        material.readsFromDepthBuffer = true
        plane.materials = [material]

        // ── Node ────────────────────────────────────────────────────────
        let node = SCNNode(geometry: plane)

        // Position: quadDistance meters in front of the capture camera
        let camPos = simd_make_float3(cameraTransform.columns.3)
        let forward = -simd_normalize(simd_make_float3(cameraTransform.columns.2))
        node.simdPosition = camPos + forward * d

        // Orientation: match the camera rotation
        node.simdOrientation = simd_quatf(cameraTransform)

        // Store direction for visibility culling
        quadDirections[id] = forward

        // ── Fade-in animation ───────────────────────────────────────────
        node.opacity = 0
        scene.rootNode.addChildNode(node)
        quadNodes[id] = node

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.35
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
        node.opacity = 1
        SCNTransaction.commit()
    }

    // MARK: - Reset

    func reset() {
        for (_, node) in quadNodes {
            node.removeFromParentNode()
        }
        quadNodes.removeAll()
        quadDirections.removeAll()
        fovCalibrated = false
    }

    var quadCount: Int { quadNodes.count }
}

// MARK: - SwiftUI Wrapper

/// Full-screen SceneKit view showing captured image quads in 3D world space.
///
/// The SceneKit camera tracks the live ARKit device pose. As photos are
/// captured, they appear as large floating panels anchored in the world,
/// creating a scene-reconstruction effect.
struct WorldQuadSceneView: UIViewRepresentable {
    let manager: CapturedQuadManager
    var transparent: Bool = false

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = manager.scene
        view.pointOfView = manager.cameraNode
        view.backgroundColor = transparent ? .clear : .black
        if transparent {
            view.scene?.background.contents = UIColor.clear
        }
        view.isPlaying = true
        view.rendersContinuously = true
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.isUserInteractionEnabled = false
        view.antialiasingMode = .multisampling2X
        view.preferredFramesPerSecond = 60
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        uiView.backgroundColor = transparent ? .clear : .black
        uiView.scene?.background.contents = transparent ? UIColor.clear : UIColor.black
    }
}
