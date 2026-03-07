import Foundation
import UIKit
import ImageIO

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

    @discardableResult
    static func saveCaptureMetadata<T: Encodable>(_ metadata: T, sessionId: String, step: Int) -> URL? {
        let dir = sessionDirectory(for: sessionId)
        let filename = String(format: "step_%02d.json", step)
        let url = dir.appendingPathComponent(filename)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(metadata)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            print("Failed to save capture metadata: \(error)")
            return nil
        }
    }

    @discardableResult
    static func saveScanSummaryMetadata<T: Encodable>(_ metadata: T, sessionId: String) -> URL? {
        let dir = sessionDirectory(for: sessionId)
        let url = dir.appendingPathComponent("scan_summary.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(metadata)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            print("Failed to save scan summary metadata: \(error)")
            return nil
        }
    }

    @discardableResult
    static func saveManifest<T: Encodable>(_ manifest: T, sessionId: String) -> URL? {
        let dir = sessionDirectory(for: sessionId)
        let url = dir.appendingPathComponent("manifest.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(manifest)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            print("Failed to save manifest: \(error)")
            return nil
        }
    }

    static func embedEXIFUserComment(in jpegData: Data, userComment: String) -> Data {
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let imageType = CGImageSourceGetType(source),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return jpegData
        }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, imageType, 1, nil) else {
            return jpegData
        }

        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        var exif = (properties[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        exif[kCGImagePropertyExifUserComment] = userComment
        properties[kCGImagePropertyExifDictionary] = exif

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return jpegData
        }

        return mutableData as Data
    }
}
