import Foundation
import UIKit

enum FileHelper {
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var capturesDirectory: URL {
        let dir = documentsDirectory.appendingPathComponent("Captures")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func sessionDirectory(for sessionId: String) -> URL {
        let dir = capturesDirectory.appendingPathComponent(sessionId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    static func saveCapture(_ data: Data, sessionId: String, step: Int) -> URL {
        let dir = sessionDirectory(for: sessionId)
        let filename = String(format: "step_%02d.jpg", step)
        let url = dir.appendingPathComponent(filename)
        try? data.write(to: url)
        return url
    }

    static func loadCapture(sessionId: String, step: Int) -> Data? {
        let dir = sessionDirectory(for: sessionId)
        let filename = String(format: "step_%02d.jpg", step)
        let url = dir.appendingPathComponent(filename)
        return try? Data(contentsOf: url)
    }

    @discardableResult
    static func savePanorama(_ data: Data, sessionId: String) -> URL {
        let dir = sessionDirectory(for: sessionId)
        let url = dir.appendingPathComponent("panorama.jpg")
        try? data.write(to: url)
        return url
    }

    static func loadPanorama(sessionId: String) -> Data? {
        let dir = sessionDirectory(for: sessionId)
        let url = dir.appendingPathComponent("panorama.jpg")
        return try? Data(contentsOf: url)
    }

    @discardableResult
    static func savePanoramaEXR(_ data: Data, sessionId: String) -> URL {
        let dir = sessionDirectory(for: sessionId)
        let url = dir.appendingPathComponent("panorama.exr")
        try? data.write(to: url)
        return url
    }

    static func firstCaptureImage(sessionId: String) -> UIImage? {
        guard let data = loadCapture(sessionId: sessionId, step: 1) else { return nil }
        return UIImage(data: data)
    }
}
