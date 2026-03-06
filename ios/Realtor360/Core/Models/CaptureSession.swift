import Foundation

// MARK: - Enums

enum CaptureStatus: String, Codable {
    case draft
    case uploading
    case processing
    case complete
    case failed
}

enum CaptureType: String, Codable {
    case multiPhoto16
    case panorama360
}

// MARK: - CaptureSession

// MARK: - Splats URLs

struct SplatsUrls: Codable {
    var low: String?       // 100k
    var medium: String?    // 500k
    var full: String?      // full_res
}

// MARK: - CaptureSession

struct CaptureSession: Identifiable, Codable {
    var id: String
    var name: String
    var createdAt: Date
    var status: CaptureStatus
    var captureType: CaptureType
    var localImagePaths: [String]
    var remoteImageRefs: [String]
    var panoramaURL: String?
    var previewURL: String?
    var errorMessage: String?
    var generatedAt: Date?

    // World Labs
    var worldUrl: String?
    var thumbnailUrl: String?
    var splatsUrls: SplatsUrls?
    var colliderMeshUrl: String?

    init(name: String, captureType: CaptureType) {
        self.id = UUID().uuidString
        self.name = name
        self.createdAt = Date()
        self.status = .draft
        self.captureType = captureType
        self.localImagePaths = []
        self.remoteImageRefs = []
    }

    var timeAgoText: String {
        let interval = Date().timeIntervalSince(generatedAt ?? createdAt)
        let minutes = Int(interval / 60)
        if minutes < 1 { return "Just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) hr ago" }
        let days = hours / 24
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }
}

// MARK: - SessionStore

@MainActor
class SessionStore: ObservableObject {
    @Published var sessions: [CaptureSession] = []

    private var fileURL: URL {
        FileHelper.documentsDirectory.appendingPathComponent("sessions.json")
    }

    init() {
        load()
    }

    func save(_ session: CaptureSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
        persist()
    }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            sessions = try decoder.decode([CaptureSession].self, from: data)
        } catch {
            print("SessionStore load error: \(error)")
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(sessions)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("SessionStore save error: \(error)")
        }
    }
}
