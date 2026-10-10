// Screenshots for test passes: with MV_AUTOPLAY=1 (or MV_SHOTS=1) the left-eye
// image the title drew is saved every 15 s as Documents/shots/shot_NN.png,
// about 768 px wide, and each one is logged with how bright and how varied it
// is ([mv-shot]), so a pass can tell "drew frames" from "drew something":
// metavision-device test pulls the PNGs beside the logs and metavision-triage
// flags runs whose every shot is black or flat.
//
// Called by KleptonCompositor once per frame with the eye texture it is about
// to composite (wired in by tools/metavision-overlay). The copy is a blit into
// a shared buffer on the compositor's own queue; scaling and PNG encoding run
// off the render thread when the GPU is done.
import Foundation
import ImageIO
import Metal

enum MetavisionShots {
    static let enabled: Bool = getenv("MV_AUTOPLAY").map { String(cString: $0) == "1" } ?? false
        || getenv("MV_SHOTS") != nil
    /// MV_HIDDEN=1 (the test pass's default): the title runs and is captured
    /// as usual, but nothing is shown or heard — the compositor draws no eye
    /// and no panels over passthrough, and the audio output is silenced — so
    /// the headset can be worn for other things while a pass runs.
    static let hidden: Bool = getenv("MV_HIDDEN").map { String(cString: $0) != "0" } ?? false
    private static let every: Double = 15
    private static let width = 768
    nonisolated(unsafe) private static var last: Double = 0
    nonisolated(unsafe) private static var count = 0
    nonisolated(unsafe) private static var busy = false
    nonisolated(unsafe) private static var saidFormat = false
    private static let lock = NSLock()

    private static var dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shots")
    }

    static func offer(_ tex: MTLTexture, slice: Int, flipY: Bool, queue: MTLCommandQueue?) {
        guard enabled, let queue else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if last == 0 {
            // First picture: start the folder afresh; the first shot comes 5 s in.
            last = now - every + 5
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        guard !busy, now - last >= every else { lock.unlock(); return }
        last = now; busy = true; count += 1
        let index = count
        lock.unlock()

        let bgra: Bool
        switch tex.pixelFormat {
        case .bgra8Unorm, .bgra8Unorm_srgb: bgra = true
        case .rgba8Unorm, .rgba8Unorm_srgb: bgra = false
        default:
            if !saidFormat { saidFormat = true; NSLog("[mv-shot] eye format %lu not captured", tex.pixelFormat.rawValue) }
            done(); return
        }
        let w = tex.width, h = tex.height, bpr = w * 4
        guard let buf = queue.device.makeBuffer(length: bpr * h, options: .storageModeShared),
              let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { done(); return }
        blit.copy(from: tex, sourceSlice: slice, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: buf, destinationOffset: 0, destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
        blit.endEncoding()
        let flip = !flipY                // GL storage is bottom-up; a PNG is top-down
        nonisolated(unsafe) let b = buf
        cb.addCompletedHandler { _ in
            DispatchQueue.global(qos: .utility).async {
                write(b, w: w, h: h, bpr: bpr, bgra: bgra, flip: flip, index: index)
                done()
            }
        }
        cb.commit()
    }

    private static func done() { lock.lock(); busy = false; lock.unlock() }

    private static func write(_ buf: MTLBuffer, w: Int, h: Int, bpr: Int, bgra: Bool, flip: Bool, index: Int) {
        let step = max(1, w / width)
        let ow = w / step, oh = h / step
        let src = buf.contents().assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 255, count: ow * oh * 4)
        var sum = 0.0, sumSq = 0.0, lit = 0
        for y in 0..<oh {
            let sy = flip ? (h - 1 - y * step) : y * step
            for x in 0..<ow {
                let p = src + sy * bpr + x * step * 4
                let r = Int(bgra ? p[2] : p[0]), g = Int(p[1]), bl = Int(bgra ? p[0] : p[2])
                let o = (y * ow + x) * 4
                out[o] = UInt8(r); out[o + 1] = UInt8(g); out[o + 2] = UInt8(bl)
                let luma = 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(bl)
                sum += luma; sumSq += luma * luma
                if luma > 24 { lit += 1 }
            }
        }
        let n = Double(ow * oh)
        let mean = sum / n, spread = max(0, sumSq / n - mean * mean).squareRoot()   // rounding can dip below 0: NaN
        let url = dir.appendingPathComponent(String(format: "shot_%02d.png", index))
        out.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: ow, height: oh, bitsPerComponent: 8,
                                      bytesPerRow: ow * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let img = ctx.makeImage(),
                  let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
        NSLog("[mv-shot] %@ mean %.0f spread %.0f lit %.0f%%", url.lastPathComponent as NSString,
              mean, spread, 100 * Double(lit) / n)
    }
}
