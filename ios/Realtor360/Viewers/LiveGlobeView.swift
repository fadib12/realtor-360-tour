import SwiftUI
import SceneKit

// ─────────────────────────────────────────────────────────────────────────────
// Live Globe View — Immersive mosaic panorama background for guided capture.
//
// A SceneKit sphere viewed from the inside. The texture is an equirectangular
// mosaic that builds up incrementally as the user captures photos. The camera
// inside the sphere tracks the device orientation so the user sees the
// captured scene filling in behind the scanner UI.
// ─────────────────────────────────────────────────────────────────────────────

struct LiveGlobeView: UIViewRepresentable {
    let deviceYaw: Double
    let devicePitch: Double
    let globe: GlobeSceneController

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.scene = globe.scene
        v.pointOfView = globe.cameraNode
        v.backgroundColor = .clear
        v.scene?.background.contents = UIColor.clear
        v.isPlaying = true
        v.rendersContinuously = true
        v.allowsCameraControl = false
        v.autoenablesDefaultLighting = false
        v.antialiasingMode = .multisampling2X
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        globe.updateCamera(yawDeg: deviceYaw, pitchDeg: devicePitch)
    }
}

// MARK: - GlobeSceneController

@MainActor
class GlobeSceneController: ObservableObject {

    let scene = SCNScene()
    let cameraNode = SCNNode()
    private let material = SCNMaterial()

    init() {
        let sphere = SCNSphere(radius: 50)
        sphere.segmentCount = 64

        material.isDoubleSided = true
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.clear
        material.diffuse.contentsTransform = SCNMatrix4MakeScale(-1, 1, 1)
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .clamp
        material.transparencyMode = .default
        material.blendMode = .alpha
        sphere.materials = [material]

        let sphereNode = SCNNode(geometry: sphere)
        scene.rootNode.addChildNode(sphereNode)

        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 120
        cameraNode.camera?.zNear = 0.1
        cameraNode.camera?.zFar = 110
        cameraNode.camera?.wantsHDR = false
        cameraNode.position = SCNVector3(0, 0, 0)
        scene.rootNode.addChildNode(cameraNode)
    }

    /// Replace the sphere texture with the latest mosaic preview.
    func setMosaicTexture(_ image: UIImage?) {
        material.diffuse.contents = image ?? UIColor.clear
    }

    func updateCamera(yawDeg: Double, pitchDeg: Double) {
        // SceneKit camera default faces -Z. The sphere texture has a horizontal flip
        // (SCNMatrix4MakeScale(-1,1,1)) for inside-out viewing. With this flip,
        // euler Y = yawDeg maps the camera to see equirectangular content at
        // λ = (180 - yawDeg), which is exactly where our yaw convention places
        // the forward direction (yaw=0 → facing -Z → λ=180°).
        let yawRad = Float(yawDeg * .pi / 180.0)
        let pitchRad = Float(pitchDeg * .pi / 180.0)
        cameraNode.eulerAngles = SCNVector3(pitchRad, yawRad, 0)
    }

    func reset() {
        material.diffuse.contents = UIColor.clear
    }
}
