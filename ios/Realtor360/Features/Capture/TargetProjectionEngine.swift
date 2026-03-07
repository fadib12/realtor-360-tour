import Foundation
import CoreGraphics
import simd

// ─────────────────────────────────────────────────────────────────────────────
// Target Projection Engine — Sphere → Screen Coordinate Mapping
//
// Owns:
//   • Projecting world-space target directions into guide-frame screen coords
//   • Border pinning: off-screen targets clamped to the guide rectangle edges
//   • Behind-camera handling: direction resolved via camera-local 2D
//
// The guide rectangle is a screen-space HUD window into the spherical capture
// system. Dots are anchored to the sphere; this engine maps them correctly
// into the rectangle. Off-screen directions are pinned to the nearest border
// point so the user always sees where each target is, creating the illusion
// of the sphere rotating behind the rectangular UI.
// ─────────────────────────────────────────────────────────────────────────────

enum TargetProjectionEngine {

    // MARK: - Types

    struct ProjectedDot: Identifiable {
        let id: Int
        /// Position in guide-frame local coordinates (0,0 = top-left of frame).
        let screenPoint: CGPoint
        /// True when the projected point naturally falls within the guide frame.
        let isOnScreen: Bool
        /// True when the dot has been pinned to the guide rectangle border.
        let isPinned: Bool
    }

    // MARK: - Projection

    /// Project multiple target directions into the guide-frame coordinate space.
    ///
    /// Each target is projected via ARKit's camera intrinsics. If the projected
    /// point falls outside the guide frame (or is behind the camera), the dot is
    /// pinned to the nearest point on the guide rectangle border along the ray
    /// from the frame center.
    ///
    /// - Parameters:
    ///   - targets: Array of `(id, worldDirection)` pairs.
    ///   - arManager: AR tracking manager (provides camera transform + projection).
    ///   - frameSize: Size of the guide frame in points.
    /// - Returns: One `ProjectedDot` per input target.
    @MainActor
    static func projectTargets(
        _ targets: [(id: Int, direction: simd_float3)],
        using arManager: ARTrackingManager,
        frameSize: CGSize
    ) -> [ProjectedDot] {

        let center = CGPoint(x: frameSize.width / 2, y: frameSize.height / 2)
        let margin: CGFloat = 14

        return targets.compactMap { id, direction in
            // ARKit projection (works for front-hemisphere directions)
            if let projected = arManager.projectToScreen(
                direction: direction, viewportSize: frameSize
            ) {
                let inBounds = projected.x >= 0 && projected.x <= frameSize.width
                            && projected.y >= 0 && projected.y <= frameSize.height

                if inBounds {
                    return ProjectedDot(id: id, screenPoint: projected,
                                        isOnScreen: true, isPinned: false)
                }

                // In front of camera but outside guide frame → pin to border
                let pinned = pinToBorder(
                    projected, center: center,
                    frameSize: frameSize, margin: margin
                )
                return ProjectedDot(id: id, screenPoint: pinned,
                                    isOnScreen: false, isPinned: true)
            }

            // Behind camera → transform to camera-local 2D → pin to border
            let pinned = projectBehindCamera(
                direction: direction, arManager: arManager,
                center: center, frameSize: frameSize, margin: margin
            )
            return ProjectedDot(id: id, screenPoint: pinned,
                                isOnScreen: false, isPinned: true)
        }
    }

    // MARK: - Border Pinning

    /// Pin a screen point to the guide rectangle border along the ray from center.
    ///
    /// Given a point that may be outside the frame, find where the ray from the
    /// frame center through that point intersects the (margin-inset) frame edge.
    private static func pinToBorder(
        _ point: CGPoint,
        center: CGPoint,
        frameSize: CGSize,
        margin: CGFloat
    ) -> CGPoint {
        let dx = point.x - center.x
        let dy = point.y - center.y

        guard abs(dx) > 0.001 || abs(dy) > 0.001 else {
            return CGPoint(x: margin, y: center.y)
        }

        let halfW = frameSize.width  / 2 - margin
        let halfH = frameSize.height / 2 - margin
        let scaleX = abs(dx) > 0.001 ? halfW / abs(dx) : CGFloat.greatestFiniteMagnitude
        let scaleY = abs(dy) > 0.001 ? halfH / abs(dy) : CGFloat.greatestFiniteMagnitude
        let scale = min(scaleX, scaleY)

        return CGPoint(
            x: center.x + dx * scale,
            y: center.y + dy * scale
        )
    }

    /// For behind-camera targets: convert direction to camera-local 2D and pin.
    ///
    /// The target direction is transformed into the camera's local coordinate
    /// system. In camera-local space, +X = right, +Y = up, −Z = forward.
    /// We use the X and −Y components to find the 2D direction on screen,
    /// then pin to the frame border.
    @MainActor
    private static func projectBehindCamera(
        direction: simd_float3,
        arManager: ARTrackingManager,
        center: CGPoint,
        frameSize: CGSize,
        margin: CGFloat
    ) -> CGPoint {
        let inv = arManager.cameraTransform.inverse
        let local4 = inv * simd_float4(direction.x, direction.y, direction.z, 0)
        let local = simd_make_float3(local4)

        // Camera-local: +x = right, +y = up, −z = forward
        // Screen: +x = right, +y = down (hence negate Y)
        let dx = CGFloat(local.x)
        let dy = CGFloat(-local.y)
        let mag = max(0.001, sqrt(dx * dx + dy * dy))
        let ux = dx / mag
        let uy = dy / mag

        let halfW = frameSize.width  / 2 - margin
        let halfH = frameSize.height / 2 - margin
        let scaleX = abs(ux) > 0.001 ? halfW / abs(ux) : CGFloat.greatestFiniteMagnitude
        let scaleY = abs(uy) > 0.001 ? halfH / abs(uy) : CGFloat.greatestFiniteMagnitude
        let scale = min(scaleX, scaleY)

        return CGPoint(
            x: center.x + ux * scale,
            y: center.y + uy * scale
        )
    }
}
