import Foundation

// MARK: - Request / Response DTOs

struct CreateSessionRequest: Codable {
    let name: String
    let captureType: String
    let photoCount: Int
}

struct CreateSessionResponse: Codable {
    let id: String
    let uploadUrls: [String]?
    let panoramaUploadUrl: String?
    let pollUrl: String
}

struct ProcessResponse: Codable {
    let status: String
}

struct SplatsResponse: Codable {
    let low: String?
    let medium: String?
    let fullRes: String?

    enum CodingKeys: String, CodingKey {
        case low = "100k"
        case medium = "500k"
        case fullRes = "full_res"
    }
}

struct StatusResponse: Codable {
    let status: String
    let progress: Double?
    let errorMessage: String?
    let previewUrl: String?
    let panoramaUrl: String?
    let worldUrl: String?
    let thumbnailUrl: String?
    let splats: SplatsResponse?
    let colliderMeshUrl: String?
    let generatedAt: String?
}

// MARK: - Protocol

protocol APIClientProtocol: Sendable {
    func createSession(name: String, captureType: CaptureType, photoCount: Int) async throws -> CreateSessionResponse
    func uploadPhoto(to url: String, data: Data) async throws
    func startProcessing(sessionId: String) async throws -> ProcessResponse
    func pollStatus(sessionId: String) async throws -> StatusResponse
}

// MARK: - Errors

enum APIError: LocalizedError {
    case uploadFailed
    case processingFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .uploadFailed:     return "Photo upload failed"
        case .processingFailed: return "Server processing failed"
        case .invalidResponse:  return "Invalid server response"
        }
    }
}

// MARK: - Real API Client

final class RealAPIClient: APIClientProtocol {
    private let baseURL: String

    init(baseURL: String = "http://localhost:8000") {
        self.baseURL = baseURL
    }

    func createSession(name: String, captureType: CaptureType, photoCount: Int) async throws -> CreateSessionResponse {
        var request = URLRequest(url: URL(string: "\(baseURL)/v1/captures")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            CreateSessionRequest(name: name, captureType: captureType.rawValue, photoCount: photoCount)
        )
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(CreateSessionResponse.self, from: data)
    }

    func uploadPhoto(to urlString: String, data: Data) async throws {
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "PUT"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.uploadFailed
        }
    }

    func startProcessing(sessionId: String) async throws -> ProcessResponse {
        var request = URLRequest(url: URL(string: "\(baseURL)/v1/captures/\(sessionId)/process")!)
        request.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(ProcessResponse.self, from: data)
    }

    func pollStatus(sessionId: String) async throws -> StatusResponse {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "\(baseURL)/v1/captures/\(sessionId)/status")!)
        return try JSONDecoder().decode(StatusResponse.self, from: data)
    }
}
