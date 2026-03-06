import Foundation

// MARK: - Backend Configuration

enum AppConfig {
    /// Configure API base URL in Info.plist using key `API_BASE_URL`.
    /// Example value for local LAN backend: `http://192.168.1.42:8000`
    static let backend: BackendMode = {
        let configuredURL = (Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if configuredURL.isEmpty {
            return .mock
        }
        return .live(configuredURL)
    }()

    enum BackendMode {
        case mock
        case live(String)
    }

    /// Returns the correct API client for the current mode.
    static var apiClient: APIClientProtocol {
        switch backend {
        case .mock:
            return MockBackend()
        case .live(let baseURL):
            return RealAPIClient(baseURL: baseURL)
        }
    }

    static var isMockMode: Bool {
        if case .mock = backend { return true }
        return false
    }
}
