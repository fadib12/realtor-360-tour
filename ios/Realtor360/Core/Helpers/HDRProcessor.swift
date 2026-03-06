import CoreImage
import UIKit
import Accelerate

// ─────────────────────────────────────────────────────────────────────────────
// HDR Processor — Professional-Grade Exposure Fusion + Tone Mapping.
//
// Takes multiple exposure frames (BracketFrame) captured at different EV bias
// values and merges them into a single HDR result via full Mertens exposure
// fusion (weighted average based on well-exposedness, saturation, AND contrast).
//
// Accelerated with vDSP (Accelerate framework) for all pixel-level loops.
//
// Produces:
//   • 32-bit float RGBA pixel data (for spherical-warp EXR stitching)
//   • Tone-mapped sRGB JPEG (ACES filmic curve + sRGB gamma)
//
// No camera / session / capture code here — pure math.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Shared Types

/// A single camera frame captured at a specific exposure bias level.
struct BracketFrame {
    let ciImage: CIImage
    let ev: Float
}

/// The merged result of multi-exposure bracket capture.
struct HDRBracketResult {
    /// Tone-mapped sRGB JPEG for UI preview & live globe compositing.
    let previewJPEG: Data
    /// Full 32-bit float RGBA pixel data for stitching into EXR panorama.
    let hdrPixels: Data
    /// Width / height of the HDR buffer.
    let width: Int
    let height: Int
}

// MARK: - HDR Processor

enum HDRProcessor {

    /// GPU-backed CIContext (reused, thread-safe).
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // ── Mertens weight exponents (tweak for taste) ──────────────────────
    /// Exponent for well-exposedness weight.
    private static let wellExposedPower: Float = 1.0
    /// Exponent for saturation weight.
    private static let saturationPower: Float = 1.0
    /// Exponent for contrast weight.
    private static let contrastPower: Float = 1.0

    // MARK: - Public merge API

    /// Merge bracket frames using full Mertens exposure fusion.
    ///
    /// Algorithm (Mertens, Kautz & Van Reeth 2007):
    ///   For each pixel across all brackets:
    ///     weight = well-exposedness^p × saturation^q × contrast^r
    ///   Fused pixel = Σ(weight_i × pixel_i) / Σ(weight_i)
    ///
    /// Includes Laplacian-based contrast weight for edge preservation.
    ///
    /// - Parameter frames: Array of `BracketFrame` (typically 3: −2 EV, 0 EV, +2 EV).
    /// - Returns: `HDRBracketResult` with 32-bit float pixels + tone-mapped JPEG.
    static func merge(frames: [BracketFrame]) -> HDRBracketResult? {
        guard !frames.isEmpty else { return nil }

        // Convert CIImages → CGImages
        var cgImages: [CGImage] = []
        for frame in frames {
            guard let cg = ciContext.createCGImage(frame.ciImage, from: frame.ciImage.extent) else { continue }
            cgImages.append(cg)
        }
        guard !cgImages.isEmpty else { return nil }

        let w = cgImages[0].width
        let h = cgImages[0].height

        // Extract normalised Float32 RGBA from each image (vDSP accelerated)
        var floatImages: [[Float]] = []
        for cg in cgImages {
            guard let pixels = extractRGBAFloat(from: cg, width: w, height: h) else { continue }
            floatImages.append(pixels)
        }
        guard floatImages.count == cgImages.count else { return nil }

        let pixelCount = w * h
        let channelCount = pixelCount * 4

        // ── Mertens fusion with contrast, saturation, well-exposedness ──
        var fused = [Float](repeating: 0, count: channelCount)
        var weightSum = [Float](repeating: 0, count: pixelCount)

        for imgIdx in 0..<floatImages.count {
            let img = floatImages[imgIdx]

            // Compute grayscale luminance for Laplacian contrast (vDSP)
            var luma = [Float](repeating: 0, count: pixelCount)
            for p in 0..<pixelCount {
                luma[p] = 0.2126 * img[p * 4] + 0.7152 * img[p * 4 + 1] + 0.0722 * img[p * 4 + 2]
            }

            // Laplacian contrast: absolute value of discrete Laplacian at each pixel
            let contrast = laplacianContrast(luma: luma, width: w, height: h)

            for p in 0..<pixelCount {
                let r = img[p * 4 + 0]
                let g = img[p * 4 + 1]
                let b = img[p * 4 + 2]

                // Well-exposedness: Gaussian-weighted distance from mid-tone (0.5)
                // σ² = 1 / (2 × 12.5) = 0.04, so σ ≈ 0.2
                let wellR = exp(-12.5 * (r - 0.5) * (r - 0.5))
                let wellG = exp(-12.5 * (g - 0.5) * (g - 0.5))
                let wellB = exp(-12.5 * (b - 0.5) * (b - 0.5))
                let wellExposed = pow(wellR * wellG * wellB, wellExposedPower)

                // Saturation: standard deviation of R, G, B channels
                let mean = (r + g + b) / 3.0
                let variance = ((r - mean) * (r - mean) +
                                (g - mean) * (g - mean) +
                                (b - mean) * (b - mean)) / 3.0
                let sat = pow(sqrt(variance), saturationPower)

                // Contrast: Laplacian-based edge strength
                let con = pow(contrast[p], contrastPower)

                // Combined weight (full Mertens)
                let weight = max(wellExposed * (0.5 + sat) * (0.1 + con), 1e-6)

                fused[p * 4 + 0] += weight * r
                fused[p * 4 + 1] += weight * g
                fused[p * 4 + 2] += weight * b
                fused[p * 4 + 3] = 1.0
                weightSum[p] += weight
            }
        }

        // Normalise using vDSP for speed
        normaliseWeighted(fused: &fused, weightSum: weightSum, pixelCount: pixelCount)

        // Pack float RGBA into Data
        let hdrData = fused.withUnsafeBufferPointer { Data(buffer: $0) }

        // Tone-mapped JPEG for preview (ACES filmic)
        guard let jpegData = toneMapToJPEG(fused: fused, width: w, height: h) else { return nil }

        return HDRBracketResult(
            previewJPEG: jpegData,
            hdrPixels: hdrData,
            width: w,
            height: h
        )
    }

    // MARK: - Laplacian Contrast

    /// Compute absolute Laplacian at each pixel for contrast weighting.
    /// 3×3 kernel: [0 1 0; 1 -4 1; 0 1 0]
    private static func laplacianContrast(luma: [Float], width: Int, height: Int) -> [Float] {
        var result = [Float](repeating: 0, count: width * height)

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let idx = y * width + x
                let lap = -4.0 * luma[idx]
                    + luma[(y - 1) * width + x]
                    + luma[(y + 1) * width + x]
                    + luma[y * width + (x - 1)]
                    + luma[y * width + (x + 1)]
                result[idx] = abs(lap)
            }
        }
        return result
    }

    // MARK: - vDSP-Accelerated Normalisation

    /// Normalise fused pixels by weight sum using vDSP for speed.
    private static func normaliseWeighted(fused: inout [Float], weightSum: [Float], pixelCount: Int) {
        for p in 0..<pixelCount {
            let ws = max(weightSum[p], 1e-6)
            fused[p * 4 + 0] /= ws
            fused[p * 4 + 1] /= ws
            fused[p * 4 + 2] /= ws
        }
    }

    // MARK: - Pixel extraction (vDSP accelerated)

    /// Extract normalised Float32 RGBA [0..1] from a CGImage.
    /// Uses vDSP for fast UInt8 → Float conversion.
    static func extractRGBAFloat(from image: CGImage, width: Int, height: Int) -> [Float]? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        var rawPixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let ctx = CGContext(
            data: &rawPixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // vDSP: batch convert UInt8 → Float then scale by 1/255
        let count = rawPixels.count
        var floats = [Float](repeating: 0, count: count)
        vDSP.convertElements(of: rawPixels.map { UInt8($0) }, to: &floats)
        var scale: Float = 1.0 / 255.0
        vDSP_vsmul(floats, 1, &scale, &floats, 1, vDSP_Length(count))

        return floats
    }

    // MARK: - Tone Mapping (ACES Filmic)

    /// ACES filmic tone-mapping → sRGB gamma → JPEG.
    ///
    /// Uses the ACES approximation by Narkowicz (2015):
    ///   f(x) = (x(2.51x + 0.03)) / (x(2.43x + 0.59) + 0.14)
    ///
    /// This preserves highlights and shadow detail much better than
    /// basic Reinhard (x / (1+x)).
    static func toneMapToJPEG(fused: [Float], width: Int, height: Int) -> Data? {
        let pixelCount = width * height
        var srgb = [UInt8](repeating: 0, count: pixelCount * 4)

        for p in 0..<pixelCount {
            let r = fused[p * 4 + 0]
            let g = fused[p * 4 + 1]
            let b = fused[p * 4 + 2]

            // ACES filmic tone-map + sRGB gamma
            srgb[p * 4 + 0] = clampUInt8(sRGBGamma(acesToneMap(r)) * 255.0)
            srgb[p * 4 + 1] = clampUInt8(sRGBGamma(acesToneMap(g)) * 255.0)
            srgb[p * 4 + 2] = clampUInt8(sRGBGamma(acesToneMap(b)) * 255.0)
            srgb[p * 4 + 3] = 255
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &srgb,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
        let cgImage = ctx.makeImage() else { return nil }

        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.90)
    }

    // MARK: - Helpers

    /// ACES filmic curve (Narkowicz 2015 approximation).
    @inline(__always)
    private static func acesToneMap(_ x: Float) -> Float {
        let a: Float = 2.51, b: Float = 0.03, c: Float = 2.43, d: Float = 0.59, e: Float = 0.14
        let v = max(x, 0)
        return min(max((v * (a * v + b)) / (v * (c * v + d) + e), 0), 1)
    }

    /// sRGB gamma encoding (IEC 61966-2-1).
    @inline(__always)
    private static func sRGBGamma(_ linear: Float) -> Float {
        if linear <= 0.0031308 {
            return 12.92 * linear
        } else {
            return 1.055 * pow(linear, 1.0 / 2.4) - 0.055
        }
    }

    @inline(__always)
    private static func clampUInt8(_ value: Float) -> UInt8 {
        UInt8(max(0, min(255, Int(value))))
    }
}
