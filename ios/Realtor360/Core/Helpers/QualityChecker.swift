import CoreImage
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// Quality Checker — Professional image quality analysis for 360° capture.
//
// Checks performed:
//   • Sharpness (blur detection via CIEdges + CIAreaAverage)
//   • Brightness (underexposure via average luminance)
//   • Overexposure (blown highlights via highlight area ratio)
//   • Contrast (dynamic range via luminance histogram spread)
//
// All checks run on a downscaled 600px proxy for speed.
// ─────────────────────────────────────────────────────────────────────────────

struct ImageQuality {
    let sharpnessScore: Double       // 0–1, higher = sharper
    let brightnessScore: Double      // 0–1, higher = brighter
    let highlightRatio: Double       // 0–1, fraction of overexposed pixels
    let contrastScore: Double        // 0–1, higher = more dynamic range

    /// Too blurry — reject if sharpness < 0.14 (tighter than 0.12)
    var isBlurry: Bool { sharpnessScore < 0.14 }
    /// Too dark — reject if brightness < 0.13
    var isDark: Bool { brightnessScore < 0.13 }
    /// Overexposed — reject if > 15% of pixels are blown highlights
    var isOverexposed: Bool { highlightRatio > 0.15 }
    /// Low contrast — warn only (don't reject)
    var isLowContrast: Bool { contrastScore < 0.15 }
}

enum QualityChecker {

    /// Analyse a JPEG Data blob for quality issues (runs off-main OK).
    static func analyze(_ imageData: Data) async -> ImageQuality {
        guard let ciImage = CIImage(data: imageData) else {
            return ImageQuality(sharpnessScore: 1, brightnessScore: 0.5,
                                highlightRatio: 0, contrastScore: 0.5)
        }
        let ctx = CIContext(options: [.useSoftwareRenderer: false])

        // Down-scale for speed
        let maxDim = max(ciImage.extent.width, ciImage.extent.height)
        let scale  = min(1.0, 600.0 / maxDim)
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let brightness = averageBrightness(of: scaled, context: ctx)
        let sharpness  = edgeSharpness(of: scaled, context: ctx)
        let highlights = highlightAnalysis(of: scaled, context: ctx)
        let contrast   = contrastAnalysis(of: scaled, context: ctx)

        return ImageQuality(
            sharpnessScore: sharpness,
            brightnessScore: brightness,
            highlightRatio: highlights,
            contrastScore: contrast
        )
    }

    // MARK: – Average Brightness

    private static func averageBrightness(of image: CIImage, context: CIContext) -> Double {
        guard let avg = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            "inputExtent": CIVector(cgRect: image.extent)
        ])?.outputImage else { return 0.5 }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(avg, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())

        let r = Double(pixel[0]) / 255.0
        let g = Double(pixel[1]) / 255.0
        let b = Double(pixel[2]) / 255.0
        return 0.299 * r + 0.587 * g + 0.114 * b
    }

    // MARK: – Edge Sharpness

    private static func edgeSharpness(of image: CIImage, context: CIContext) -> Double {
        guard let edges = CIFilter(name: "CIEdges", parameters: [
            kCIInputImageKey: image,
            kCIInputIntensityKey: 1.0
        ])?.outputImage else { return 1.0 }

        guard let avg = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: edges,
            "inputExtent": CIVector(cgRect: edges.extent)
        ])?.outputImage else { return 1.0 }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(avg, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())

        let intensity = Double(pixel[0]) / 255.0
        return min(1.0, intensity / 0.04)   // empirical threshold
    }

    // MARK: – Overexposure / Blown Highlights

    /// Estimate the fraction of pixels that are overexposed (near white).
    /// Uses CIColorClamp to isolate near-white pixels, then measures their area.
    private static func highlightAnalysis(of image: CIImage, context: CIContext) -> Double {
        // Threshold: pixels where ALL channels > 240/255 ≈ 0.94
        // Use CIColorThreshold via manual approach — render and count
        let w = Int(image.extent.width)
        let h = Int(image.extent.height)
        guard w > 0, h > 0 else { return 0 }

        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: h * bytesPerRow)

        context.render(image, toBitmap: &pixels, rowBytes: bytesPerRow,
                       bounds: image.extent,
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())

        var overexposedCount = 0
        let threshold: UInt8 = 240
        let pixelCount = w * h

        for p in 0..<pixelCount {
            let r = pixels[p * 4 + 0]
            let g = pixels[p * 4 + 1]
            let b = pixels[p * 4 + 2]
            if r > threshold && g > threshold && b > threshold {
                overexposedCount += 1
            }
        }

        return Double(overexposedCount) / Double(pixelCount)
    }

    // MARK: – Contrast (Dynamic Range)

    /// Measure contrast as the difference between the 95th and 5th percentile
    /// luminance values. Higher = more dynamic range.
    private static func contrastAnalysis(of image: CIImage, context: CIContext) -> Double {
        let w = Int(image.extent.width)
        let h = Int(image.extent.height)
        guard w > 0, h > 0 else { return 0.5 }

        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: h * bytesPerRow)

        context.render(image, toBitmap: &pixels, rowBytes: bytesPerRow,
                       bounds: image.extent,
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())

        // Build luminance histogram (256 bins)
        var histogram = [Int](repeating: 0, count: 256)
        let pixelCount = w * h

        for p in 0..<pixelCount {
            let r = Int(pixels[p * 4 + 0])
            let g = Int(pixels[p * 4 + 1])
            let b = Int(pixels[p * 4 + 2])
            // BT.601 luminance
            let luma = (299 * r + 587 * g + 114 * b) / 1000
            histogram[min(255, luma)] += 1
        }

        // Find 5th and 95th percentile
        let p5Target = pixelCount * 5 / 100
        let p95Target = pixelCount * 95 / 100
        var cumulative = 0
        var p5: Int = 0
        var p95: Int = 255

        for bin in 0..<256 {
            cumulative += histogram[bin]
            if cumulative >= p5Target && p5 == 0 {
                p5 = bin
            }
            if cumulative >= p95Target {
                p95 = bin
                break
            }
        }

        return Double(p95 - p5) / 255.0
    }
}
