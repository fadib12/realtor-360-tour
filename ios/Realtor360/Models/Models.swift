import Foundation

// MARK: - API Response Models

struct TourResponse: Codable {
    let id: String
    let name: String
    let address: String?
    let notes: String?
    let status: TourStatus
    let publicSlug: String
    let panoUrl: String?
    let createdAt: String
    let completedAt: String?
    let webUrl: String
    let publicViewerUrl: String
    let captureUniversalLink: String
    let qrData: String
    
    enum CodingKeys: String, CodingKey {
        case id, name, address, notes, status
        case publicSlug = "public_slug"
        case panoUrl = "pano_url"
        case createdAt = "created_at"
        case completedAt = "completed_at"
        case webUrl = "web_url"
        case publicViewerUrl = "public_viewer_url"
        case captureUniversalLink = "capture_universal_link"
        case qrData = "qr_data"
    }
}

enum TourStatus: String, Codable {
    case waiting = "WAITING"
    case uploading = "UPLOADING"
    case processing = "PROCESSING"
    case ready = "READY"
    case failed = "FAILED"
}

struct UploadUrlsRequest: Codable {
    let count: Int
}

struct UploadUrlsResponse: Codable {
    let uploadUrls: [String]
    let frameKeys: [String]
    
    enum CodingKeys: String, CodingKey {
        case uploadUrls = "upload_urls"
        case frameKeys = "frame_keys"
    }
}

struct FrameMeta: Codable {
    let index: Int
    let yaw: Double?
    let pitch: Double?
}

struct CompleteUploadRequest: Codable {
    let frameKeys: [String]
    let framesMeta: [FrameMeta]?
    
    enum CodingKeys: String, CodingKey {
        case frameKeys = "frame_keys"
        case framesMeta = "frames_meta"
    }
}

struct CompleteUploadResponse: Codable {
    let status: TourStatus
}

// MARK: - Capture Models

struct CaptureTarget: Identifiable {
    let id: Int
    let yaw: Double    // degrees
    let pitch: Double  // degrees
    
    var description: String {
        let pitchLabel: String
        if pitch > 20 { return "UP" }
        else if pitch < -20 { return "DOWN" }
        else { return "MID" }
    }
}

struct CapturedFrame {
    let index: Int
    let fileURL: URL
    let yaw: Double
    let pitch: Double
    let timestamp: Date
}

// MARK: - Capture Target Map

/// 16 targets as specified:
/// - Row UP: pitch +35°, yaw = 0°, 90°, 180°, 270° (4 shots)
/// - Row MID: pitch 0°, yaw = 0°, 45°, 90°, 135°, 180°, 225°, 270°, 315° (8 shots)
/// - Row DOWN: pitch -35°, yaw = 0°, 90°, 180°, 270° (4 shots)
let captureTargets: [CaptureTarget] = {
    var targets: [CaptureTarget] = []
    var index = 0
    
    // Row UP (pitch +35°)
    for yaw in [0.0, 90.0, 180.0, 270.0] {
        targets.append(CaptureTarget(id: index, yaw: yaw, pitch: 35.0))
        index += 1
    }
    
    // Row MID (pitch 0°)
    for yaw in [0.0, 45.0, 90.0, 135.0, 180.0, 225.0, 270.0, 315.0] {
        targets.append(CaptureTarget(id: index, yaw: yaw, pitch: 0.0))
        index += 1
    }
    
    // Row DOWN (pitch -35°)
    for yaw in [0.0, 90.0, 180.0, 270.0] {
        targets.append(CaptureTarget(id: index, yaw: yaw, pitch: -35.0))
        index += 1
    }
    
    return targets
}()

// Tolerance: yaw ±7°, pitch ±7°
let yawTolerance: Double = 7.0
let pitchTolerance: Double = 7.0
let stabilityDuration: TimeInterval = 0.25  // 250ms
