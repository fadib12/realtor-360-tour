import Foundation
import simd

// ─────────────────────────────────────────────────────────────────────────────
// Spherical Target Manager — Node-Expansion Capture Graph
//
// Owns:
//   • 16-target spherical grid (wraps SphereGrid for stitcher compatibility)
//   • Pre-computed neighbor adjacency via angular distance on the sphere
//   • BFS-style frontier expansion as nodes are captured
//   • Active target selection (nearest frontier node to camera forward)
//   • Visible dot set management (active + helpers)
//
// Capture flow:
//   1. Before first capture: only target 0 is visible (center registration dot)
//   2. After first capture: 4 spherical neighbors of the captured node spawn
//   3. Each subsequent capture expands the frontier with its own neighbors
//   4. Duplicates / already-captured targets are excluded automatically
//   5. The active target is always the frontier node closest to camera forward
//   6. The user progressively paints the sphere — never sees all 16 at once
//
// The 16 target positions match SphereGrid exactly so the PanoramaStitcher
// and UploadViewModel remain fully compatible (images indexed by target ID).
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
class SphericalTargetManager: ObservableObject {

    // MARK: - Types

    struct SphericalNode: Identifiable {
        let id: Int
        let yawDeg: Double
        let pitchDeg: Double
        /// Unit direction in SphereGrid local space (before reference-yaw rotation).
        let direction: simd_float3
        var isCaptured: Bool = false
        var retryCount: Int = 0
    }

    // MARK: - Configuration

    /// Angular distance threshold (degrees) for neighbor eligibility.
    /// 80° covers: horizon-to-adjacent-horizon (45°), horizon-to-upper (55°),
    /// upper-to-adjacent-upper (≈48°), and upper-to-opposite-upper (≈70°), plus more overlap for seamless stitching.
    static let neighborAngleThresholdDeg: Double = 80.0
    /// Maximum neighbors per node. 5 gives richer BFS connectivity at the
    /// upper/lower rings where more candidates fall within the threshold.
    static let maxNeighborsPerNode: Int = 5

    // MARK: - State

    /// All 16 target nodes (indexed by SphereGrid order for stitcher compat).
    private(set) var nodes: [SphericalNode] = []

    /// Frontier: uncaptured node IDs adjacent to at least one captured node.
    @Published private(set) var frontier: Set<Int> = []

    /// Currently active target (nearest frontier node to camera forward).
    @Published private(set) var activeTargetID: Int?

    /// IDs of all captured nodes.
    private(set) var capturedIDs: Set<Int> = []

    /// Pre-computed adjacency list: nodeID → sorted list of neighbor IDs.
    private var adjacency: [Int: [Int]] = [:]

    /// Reference yaw (degrees) anchoring the sphere orientation to where the user
    /// was looking when the session started. Set on first AR frame, NOT on first capture.
    var referenceYawDeg: Double?

    // MARK: - Computed

    var capturedCount: Int { capturedIDs.count }
    var totalCount: Int { nodes.count }  // 16
    var isAllCaptured: Bool { capturedCount >= totalCount }

    /// IDs visible on-screen: before first capture just [0], after that
    /// the active target + up to 3 nearest helper targets from the frontier.
    /// This keeps the UI clean (aim-bot feel, not a noisy target cloud).
    var visibleDotIDs: [Int] {
        if capturedCount == 0 { return [0] }
        guard let active = activeTargetID else { return Array(frontier.prefix(4)) }

        // Active target always shown
        var result: [Int] = [active]

        // Add up to 3 nearest frontier helpers (by angular distance from active)
        let activeDir = nodes[active].direction
        let helpers = frontier
            .filter { $0 != active }
            .sorted { a, b in
                let da = Self.angularDistanceDeg(nodes[a].direction, activeDir)
                let db = Self.angularDistanceDeg(nodes[b].direction, activeDir)
                return da < db
            }
            .prefix(3)

        result.append(contentsOf: helpers)
        return result
    }

    // MARK: - Init

    init() {
        buildNodes()
        buildAdjacency()
    }

    // MARK: - Lifecycle

    func reset() {
        for i in nodes.indices {
            nodes[i].isCaptured = false
            nodes[i].retryCount = 0
        }
        capturedIDs.removeAll()
        frontier.removeAll()
        activeTargetID = nil
        referenceYawDeg = nil

        // Seed target 0 into the frontier so it's immediately visible
        // and selectable as the active target. The dot lives on the sphere
        // from the start — the camera is INSIDE the sphere looking at it.
        frontier.insert(0)
    }

    // MARK: - Node Expansion

    /// Mark a node as captured and expand the frontier with its uncaptured neighbors.
    func markCaptured(id: Int) {
        guard nodes.indices.contains(id) else { return }
        nodes[id].isCaptured = true
        capturedIDs.insert(id)
        frontier.remove(id)

        // Spawn uncaptured neighbors into the frontier
        if let neighbors = adjacency[id] {
            for nid in neighbors where !capturedIDs.contains(nid) {
                frontier.insert(nid)
            }
        }
    }

    /// Update the active target to the frontier node best aligned with camera forward.
    func updateActiveTarget(cameraForward: simd_float3) {
        guard !frontier.isEmpty else {
            activeTargetID = nil
            return
        }

        var bestID: Int?
        var bestDot: Float = -2  // cosine similarity, higher = closer

        for id in frontier {
            guard let wdir = worldDirection(for: id) else { continue }
            let d = simd_dot(simd_normalize(cameraForward), simd_normalize(wdir))
            if d > bestDot {
                bestDot = d
                bestID = id
            }
        }

        activeTargetID = bestID
    }

    // MARK: - Direction Resolution

    /// World-space direction for a target, with reference-yaw rotation applied.
    ///
    /// Every dot is always anchored to the sphere. The camera lives inside the
    /// sphere and looks at the dots — they never track the camera direction.
    /// `referenceYawDeg` aligns the sphere so target 0 sits in front of where
    /// the user was looking when the session started.
    func worldDirection(for id: Int) -> simd_float3? {
        guard nodes.indices.contains(id) else { return nil }
        let local = nodes[id].direction
        guard let yaw = referenceYawDeg else { return local }
        return Self.rotateAroundWorldY(local, yawDeg: yaw)
    }

    /// Increment retry count for a target (quality rejection).
    func incrementRetry(for id: Int) {
        guard nodes.indices.contains(id) else { return }
        nodes[id].retryCount += 1
    }

    func retryCount(for id: Int) -> Int {
        guard nodes.indices.contains(id) else { return 0 }
        return nodes[id].retryCount
    }

    // MARK: - Adjacency Queries

    func neighbors(of id: Int) -> [Int] { adjacency[id] ?? [] }

    // MARK: - Private

    private func buildNodes() {
        nodes = SphereGrid.targets.enumerated().map { i, t in
            SphericalNode(id: i, yawDeg: t.yawDeg, pitchDeg: t.pitchDeg,
                          direction: t.direction)
        }
    }

    /// Build the adjacency graph: for each node, its N closest neighbors within
    /// the angular threshold. This gives natural spherical connectivity —
    /// horizon nodes connect to adjacent horizon + nearest upper/lower,
    /// upper/lower nodes connect to horizon below/above + ring neighbors.
    private func buildAdjacency() {
        let n = nodes.count
        for i in 0..<n {
            var pairs: [(id: Int, angle: Double)] = []
            for j in 0..<n where j != i {
                let angle = Self.angularDistanceDeg(nodes[i].direction, nodes[j].direction)
                if angle <= Self.neighborAngleThresholdDeg {
                    pairs.append((id: j, angle: angle))
                }
            }
            pairs.sort { $0.angle < $1.angle }
            adjacency[i] = pairs.prefix(Self.maxNeighborsPerNode).map(\.id)
        }
    }

    // MARK: - Static Utilities

    static func angularDistanceDeg(_ a: simd_float3, _ b: simd_float3) -> Double {
        let dot = simd_clamp(simd_dot(simd_normalize(a), simd_normalize(b)), -1, 1)
        return Double(acos(dot)) * 180.0 / .pi
    }

    static func rotateAroundWorldY(_ v: simd_float3, yawDeg: Double) -> simd_float3 {
        let r = Float(yawDeg * .pi / 180.0)
        let c = cos(r); let s = sin(r)
        return simd_normalize(simd_float3(
            v.x * c - v.z * s,
            v.y,
            v.x * s + v.z * c
        ))
    }
}
