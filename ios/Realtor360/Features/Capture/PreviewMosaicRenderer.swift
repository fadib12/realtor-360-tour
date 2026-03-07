import UIKit
import ImageIO

/// Real-time low-resolution equirectangular mosaic that builds up as photos
/// are captured. Each accepted capture is spherically warped (gnomonic →
/// equirectangular) using its actual yaw/pitch/roll and blended into a
/// persistent preview canvas. The resulting UIImage is mapped onto a SceneKit
/// sphere to create a "filling-in" background behind the scanner UI.
///
/// Kept intentionally separate from the final full-resolution `PanoramaStitcher`.
@MainActor
final class PreviewMosaicRenderer: ObservableObject {

    static let width  = 4096
    static let height = 2048
    static let liveW  = 2048
    static let liveH  = 1024

    private var canvas: [UInt8]
    private var weights: [Float]
    private var liveCanvas: [UInt8]

    @Published private(set) var mosaicImage: UIImage?
    @Published private(set) var liveImage: UIImage?
    @Published private(set) var shotCount: Int = 0

    init() {
        canvas  = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
        weights = [Float](repeating: 0, count: Self.width * Self.height)
        liveCanvas = [UInt8](repeating: 0, count: Self.liveW * Self.liveH * 4)
    }

    func reset() {
        canvas  = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
        weights = [Float](repeating: 0, count: Self.width * Self.height)
        liveCanvas = [UInt8](repeating: 0, count: Self.liveW * Self.liveH * 4)
        mosaicImage = nil
        liveImage = nil
        shotCount = 0
    }

    // MARK: - Live camera → sphere texture (initialLock only)

    func updateLivePreview(
        image: UIImage,
        yawDeg: Double, pitchDeg: Double, rollDeg: Double,
        hfovDeg: Double, vfovDeg: Double
    ) {
        guard let cg = image.cgImage else { return }
        let small = resizeForLive(cg, maxPx: 384)
        guard let pixels = extractRGBA(from: small) else { return }

        liveCanvas.withUnsafeMutableBufferPointer { ptr in
            _ = memset(ptr.baseAddress!, 0, ptr.count)
        }

        warpLive(
            photo: pixels, pw: small.width, ph: small.height,
            yawDeg: yawDeg, pitchDeg: pitchDeg, rollDeg: rollDeg,
            hfovDeg: hfovDeg, vfovDeg: vfovDeg
        )

        rebuildLiveImage()
    }

    func clearLive() {
        liveImage = nil
    }

    private func warpLive(
        photo: [UInt8], pw: Int, ph: Int,
        yawDeg: Double, pitchDeg: Double, rollDeg: Double,
        hfovDeg: Double, vfovDeg: Double
    ) {
        let w = Self.liveW, h = Self.liveH
        let hfov = hfovDeg * .pi / 180.0
        let vfov = vfovDeg * .pi / 180.0

        let fx = Double(pw) / (2.0 * tan(hfov / 2.0))
        let fy = Double(ph) / (2.0 * tan(vfov / 2.0))
        let cx = Double(pw) / 2.0
        let cy = Double(ph) / 2.0

        let y  =  yawDeg   * .pi / 180.0
        let p  = -pitchDeg * .pi / 180.0
        let rl =  rollDeg  * .pi / 180.0

        let cY = cos(y); let sY = sin(y)
        let cP = cos(p); let sP = sin(p)
        let cR = cos(rl); let sR = sin(rl)

        let r00 = cY*cR + sY*sP*sR
        let r01 = cP*sR
        let r02 = -sY*cR + cY*sP*sR
        let r10 = -cY*sR + sY*sP*cR
        let r11 = cP*cR
        let r12 = sY*sR + cY*sP*cR
        let r20 = sY*cP
        let r21 = -sP
        let r22 = cY*cP

        let maxAngle = max(hfov, vfov) * 0.6 + 0.15
        var centreYaw = atan2(r20, r22)
        if centreYaw < 0 { centreYaw += 2.0 * .pi }
        let centrePitch = asin(min(1, max(-1, r21)))
        let cyDeg = centreYaw * 180.0 / .pi
        let cpDeg = centrePitch * 180.0 / .pi
        let halfDeg = maxAngle * 180.0 / .pi

        let uMinRaw = Int((cyDeg - halfDeg) / 360.0 * Double(w)) - 2
        let uMaxRaw = Int((cyDeg + halfDeg) / 360.0 * Double(w)) + 2
        let vMin = max(0, Int((90.0 - cpDeg - halfDeg) / 180.0 * Double(h)) - 2)
        let vMax = min(h - 1, Int((90.0 - cpDeg + halfDeg) / 180.0 * Double(h)) + 2)

        var ranges: [(Int, Int)] = []
        if uMinRaw < 0 {
            ranges.append((0, min(uMaxRaw, w - 1)))
            ranges.append((max(w + uMinRaw, 0), w - 1))
        } else if uMaxRaw >= w {
            ranges.append((uMinRaw, w - 1))
            ranges.append((0, min(uMaxRaw - w, w - 1)))
        } else {
            ranges.append((max(uMinRaw, 0), min(uMaxRaw, w - 1)))
        }

        let photoWd = Double(pw), photoHd = Double(ph)

        for range in ranges {
            guard range.0 <= range.1 else { continue }
            for v in vMin...vMax {
                let phi = (.pi / 2.0) - (Double(v) + 0.5) / Double(h) * .pi
                for u in range.0...range.1 {
                    let lam = (Double(u) + 0.5) / Double(w) * 2.0 * .pi

                    let wx = cos(phi) * sin(lam)
                    let wy = sin(phi)
                    let wz = cos(phi) * cos(lam)

                    let lx = r00*wx + r01*wy + r02*wz
                    let ly = r10*wx + r11*wy + r12*wz
                    let lz = r20*wx + r21*wy + r22*wz
                    guard lz > 0.01 else { continue }

                    let ppx = fx * (lx / lz) + cx
                    let ppy = cy - fy * (ly / lz)

                    guard ppx >= 0.5, ppx < photoWd - 0.5,
                          ppy >= 0.5, ppy < photoHd - 0.5 else { continue }

                    let (sr, sg, sb) = bilinear(photo, pw: pw, ph: ph, x: ppx, y: ppy)

                    let idx = v * w + u
                    let ci  = idx * 4
                    liveCanvas[ci + 0] = UInt8(clamped: sr)
                    liveCanvas[ci + 1] = UInt8(clamped: sg)
                    liveCanvas[ci + 2] = UInt8(clamped: sb)
                    liveCanvas[ci + 3] = 255
                }
            }
        }
    }

    private func resizeForLive(_ source: CGImage, maxPx: Int) -> CGImage {
        let sw = source.width, sh = source.height
        guard max(sw, sh) > maxPx else { return source }
        let scale = Double(maxPx) / Double(max(sw, sh))
        let nw = Int(Double(sw) * scale)
        let nh = Int(Double(sh) * scale)
        guard let ctx = CGContext(
            data: nil, width: nw, height: nh,
            bitsPerComponent: 8, bytesPerRow: nw * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return source }
        ctx.interpolationQuality = .low
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage() ?? source
    }

    private func rebuildLiveImage() {
        let w = Self.liveW, h = Self.liveH
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        if let dest = ctx.data {
            let ptr = dest.bindMemory(to: UInt8.self, capacity: w * h * 4)
            liveCanvas.withUnsafeBufferPointer { src in
                ptr.update(from: src.baseAddress!, count: w * h * 4)
            }
        }
        if let cg = ctx.makeImage() {
            liveImage = UIImage(cgImage: cg)
        }
    }

    // MARK: - Public: blend one capture into the mosaic

    func blendCapture(
        imageData: Data,
        yawDeg: Double,
        pitchDeg: Double,
        rollDeg: Double,
        hfovDeg: Double,
        vfovDeg: Double
    ) {
        guard let thumb = decodeThumbnail(imageData, maxPx: 1024) else { return }
        guard let pixels = extractRGBA(from: thumb) else { return }

        warpIntoCanvas(
            photo: pixels,
            pw: thumb.width, ph: thumb.height,
            yawDeg: yawDeg, pitchDeg: pitchDeg, rollDeg: rollDeg,
            hfovDeg: hfovDeg, vfovDeg: vfovDeg
        )

        rebuildImage()
        shotCount += 1
    }

    // MARK: - Spherical warp (gnomonic → equirectangular)

    private func warpIntoCanvas(
        photo: [UInt8], pw: Int, ph: Int,
        yawDeg: Double, pitchDeg: Double, rollDeg: Double,
        hfovDeg: Double, vfovDeg: Double
    ) {
        let w = Self.width
        let h = Self.height
        let hfov = hfovDeg * .pi / 180.0
        let vfov = vfovDeg * .pi / 180.0

        let fx = Double(pw) / (2.0 * tan(hfov / 2.0))
        let fy = Double(ph) / (2.0 * tan(vfov / 2.0))
        let cx = Double(pw) / 2.0
        let cy = Double(ph) / 2.0

        // R_inv = R^T  where  R = Ry(yaw) · Rx(-pitch) · Rz(roll)
        let y  =  yawDeg   * .pi / 180.0
        let p  = -pitchDeg * .pi / 180.0
        let rl =  rollDeg  * .pi / 180.0

        let cY = cos(y); let sY = sin(y)
        let cP = cos(p); let sP = sin(p)
        let cR = cos(rl); let sR = sin(rl)

        let r00 = cY*cR + sY*sP*sR
        let r01 = cP*sR
        let r02 = -sY*cR + cY*sP*sR
        let r10 = -cY*sR + sY*sP*cR
        let r11 = cP*cR
        let r12 = sY*sR + cY*sP*cR
        let r20 = sY*cP
        let r21 = -sP
        let r22 = cY*cP

        // Bounding box on the equirectangular canvas
        let maxAngle = max(hfov, vfov) * 0.6 + 0.15
        var centreYaw = atan2(r20, r22)
        if centreYaw < 0 { centreYaw += 2.0 * .pi }
        let centrePitch = asin(min(1, max(-1, r21)))
        let cyDeg = centreYaw * 180.0 / .pi
        let cpDeg = centrePitch * 180.0 / .pi
        let halfDeg = maxAngle * 180.0 / .pi

        let uMinRaw = Int((cyDeg - halfDeg) / 360.0 * Double(w)) - 2
        let uMaxRaw = Int((cyDeg + halfDeg) / 360.0 * Double(w)) + 2
        let vMin = max(0, Int((90.0 - cpDeg - halfDeg) / 180.0 * Double(h)) - 2)
        let vMax = min(h - 1, Int((90.0 - cpDeg + halfDeg) / 180.0 * Double(h)) + 2)

        var ranges: [(Int, Int)] = []
        if uMinRaw < 0 {
            ranges.append((0, min(uMaxRaw, w - 1)))
            ranges.append((max(w + uMinRaw, 0), w - 1))
        } else if uMaxRaw >= w {
            ranges.append((uMinRaw, w - 1))
            ranges.append((0, min(uMaxRaw - w, w - 1)))
        } else {
            ranges.append((max(uMinRaw, 0), min(uMaxRaw, w - 1)))
        }

        let photoWd = Double(pw)
        let photoHd = Double(ph)

        for range in ranges {
            guard range.0 <= range.1 else { continue }
            for v in vMin...vMax {
                let phi = (.pi / 2.0) - (Double(v) + 0.5) / Double(h) * .pi

                for u in range.0...range.1 {
                    let lam = (Double(u) + 0.5) / Double(w) * 2.0 * .pi

                    let wx = cos(phi) * sin(lam)
                    let wy = sin(phi)
                    let wz = cos(phi) * cos(lam)

                    let lx = r00*wx + r01*wy + r02*wz
                    let ly = r10*wx + r11*wy + r12*wz
                    let lz = r20*wx + r21*wy + r22*wz
                    guard lz > 0.01 else { continue }

                    let px = fx * (lx / lz) + cx
                    let py = cy - fy * (ly / lz)

                    guard px >= 0.5, px < photoWd - 0.5,
                          py >= 0.5, py < photoHd - 0.5 else { continue }

                    let (sr, sg, sb) = bilinear(photo, pw: pw, ph: ph, x: px, y: py)

                    let cosA = Float(lz / sqrt(lx*lx + ly*ly + lz*lz))
                    let wt   = cosA * cosA
                    guard wt > 0.01 else { continue }

                    let idx  = v * w + u
                    let ci   = idx * 4
                    let oldW = weights[idx]
                    let newW = oldW + wt

                    canvas[ci + 0] = UInt8(clamped: (Float(canvas[ci + 0]) * oldW + sr * wt) / newW)
                    canvas[ci + 1] = UInt8(clamped: (Float(canvas[ci + 1]) * oldW + sg * wt) / newW)
                    canvas[ci + 2] = UInt8(clamped: (Float(canvas[ci + 2]) * oldW + sb * wt) / newW)
                    canvas[ci + 3] = 255
                    weights[idx] = newW
                }
            }
        }
    }

    // MARK: - Bilinear sampling (UInt8 → Float)

    @inline(__always)
    private func bilinear(
        _ p: [UInt8], pw: Int, ph: Int, x: Double, y: Double
    ) -> (Float, Float, Float) {
        let ix = Int(x); let iy = Int(y)
        let fx = Float(x - Double(ix))
        let fy = Float(y - Double(iy))

        let x0 = min(max(ix, 0), pw - 1)
        let x1 = min(x0 + 1, pw - 1)
        let y0 = min(max(iy, 0), ph - 1)
        let y1 = min(y0 + 1, ph - 1)

        let w00 = (1 - fx) * (1 - fy)
        let w10 = fx * (1 - fy)
        let w01 = (1 - fx) * fy
        let w11 = fx * fy

        let i00 = (y0 * pw + x0) * 4
        let i10 = (y0 * pw + x1) * 4
        let i01 = (y1 * pw + x0) * 4
        let i11 = (y1 * pw + x1) * 4

        let r = w00*Float(p[i00])   + w10*Float(p[i10])   + w01*Float(p[i01])   + w11*Float(p[i11])
        let g = w00*Float(p[i00+1]) + w10*Float(p[i10+1]) + w01*Float(p[i01+1]) + w11*Float(p[i11+1])
        let b = w00*Float(p[i00+2]) + w10*Float(p[i10+2]) + w01*Float(p[i01+2]) + w11*Float(p[i11+2])
        return (r, g, b)
    }

    // MARK: - Helpers

    private func decodeThumbnail(_ data: Data, maxPx: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPx,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    private func extractRGBA(from image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &buf, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }

    private func rebuildImage() {
        let w = Self.width, h = Self.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        if let dest = ctx.data {
            let ptr = dest.bindMemory(to: UInt8.self, capacity: w * h * 4)
            canvas.withUnsafeBufferPointer { src in
                ptr.update(from: src.baseAddress!, count: w * h * 4)
            }
        }
        if let cg = ctx.makeImage() {
            mosaicImage = UIImage(cgImage: cg)
        }
    }
}

// MARK: - UInt8 clamped init

private extension UInt8 {
    init(clamped value: Float) {
        if value <= 0 { self = 0 }
        else if value >= 255 { self = 255 }
        else { self = UInt8(value) }
    }
}
