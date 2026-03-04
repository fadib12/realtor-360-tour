import Foundation

class APIService {
    static let shared = APIService()
    
    // Configure this to your server URL
    private let baseURL: String = {
        #if DEBUG
        return "http://localhost:8000"
        #else
        return "https://api.realtor360.app"
        #endif
    }()
    
    private init() {}
    
    // MARK: - Get Tour
    
    func getTour(tourId: String) async throws -> TourResponse {
        let url = URL(string: "\(baseURL)/api/tours/\(tourId)")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode(TourResponse.self, from: data)
    }
    
    // MARK: - Get Upload URLs
    
    func getUploadUrls(tourId: String, count: Int = 16) async throws -> UploadUrlsResponse {
        let url = URL(string: "\(baseURL)/api/tours/\(tourId)/uploads")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = UploadUrlsRequest(count: count)
        request.httpBody = try JSONEncoder().encode(body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode(UploadUrlsResponse.self, from: data)
    }
    
    // MARK: - Complete Upload
    
    func completeUpload(tourId: String, frameKeys: [String], framesMeta: [FrameMeta]) async throws -> CompleteUploadResponse {
        let url = URL(string: "\(baseURL)/api/tours/\(tourId)/complete-upload")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = CompleteUploadRequest(frameKeys: frameKeys, framesMeta: framesMeta)
        request.httpBody = try JSONEncoder().encode(body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode(CompleteUploadResponse.self, from: data)
    }
}

// MARK: - Errors

enum APIError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int)
    case uploadFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid server response"
        case .httpError(let statusCode):
            return "Server error (status: \(statusCode))"
        case .uploadFailed(let message):
            return "Upload failed: \(message)"
        }
    }
}
