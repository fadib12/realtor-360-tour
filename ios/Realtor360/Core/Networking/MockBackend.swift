import Foundation

/// A fully-offline mock backend that simulates upload + processing.
/// Returns "complete" after a short delay with placeholder URLs.
final class MockBackend: APIClientProtocol {
    // In-memory session status
    private actor Store {
        var statuses: [String: StatusResponse] = [:]
        func set(_ id: String, _ status: StatusResponse) { statuses[id] = status }
        func get(_ id: String) -> StatusResponse? { statuses[id] }
    }
    private let store = Store()

    func createSession(name: String, captureType: CaptureType, photoCount: Int) async throws -> CreateSessionResponse {
        let id = "mock_\(UUID().uuidString.prefix(8))"
        let uploads = (0..<photoCount).map { "mock://upload/\(id)/\($0)" }
        return CreateSessionResponse(
            id: id,
            uploadUrls: captureType == .multiPhoto16 ? uploads : nil,
            panoramaUploadUrl: captureType == .panorama360 ? "mock://upload/\(id)/panorama" : nil,
            pollUrl: "/v1/captures/\(id)/status"
        )
    }

    func uploadPhoto(to url: String, data: Data) async throws {
        // Simulate network latency per photo
        try await Task.sleep(for: .milliseconds(150))
    }

    func startProcessing(sessionId: String) async throws -> ProcessResponse {
        // Kick off a background "processing" simulation
        Task { [store] in
            try? await Task.sleep(for: .seconds(3))
            let done = StatusResponse(
                status: "complete",
                progress: 1.0,
                errorMessage: nil,
                previewUrl: "mock://preview/\(sessionId)",
                panoramaUrl: "mock://panorama/\(sessionId)",
                worldUrl: "https://marble.worldlabs.ai/w/mock_\(sessionId)",
                thumbnailUrl: "mock://thumbnail/\(sessionId)",
                splats: SplatsResponse(low: "mock://splats/100k", medium: "mock://splats/500k", fullRes: "mock://splats/full"),
                colliderMeshUrl: "mock://collider/\(sessionId)",
                generatedAt: ISO8601DateFormatter().string(from: Date())
            )
            await store.set(sessionId, done)
        }
        return ProcessResponse(status: "processing")
    }

    func pollStatus(sessionId: String) async throws -> StatusResponse {
        try await Task.sleep(for: .milliseconds(400))
        if let status = await store.get(sessionId) { return status }
        return StatusResponse(status: "processing", progress: 0.5,
                              errorMessage: nil,
                              previewUrl: nil, panoramaUrl: nil,
                              worldUrl: nil, thumbnailUrl: nil,
                              splats: nil, colliderMeshUrl: nil,
                              generatedAt: nil)
    }
}
