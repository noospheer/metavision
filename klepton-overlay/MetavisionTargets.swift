// Targets for auto-play: what in the picture looks pressable, as directions in
// the title's own tracking space, so MetavisionAutoplay aims at buttons and
// panels instead of sweeping a grid that rarely lands on one.
//
// Every 1.5 s (with MV_AUTOPLAY=1) the left eye the title drew is shrunk on the
// GPU to a 128-pixel-wide luminance map, cropped to that eye's render viewport.
// On the CPU, two kinds of region are picked out of it:
//
//   detail   where edges are dense — text, icons, the outline of a button
//   bright   compact patches clearly lighter (or darker) than the frame —
//            a lit button on a dark menu, a dark one on a pale menu
//
// Each region's centre becomes a direction through the frustum the title
// rendered that frame with (tangents and head pose from the frame record), so
// it stays right when the head moves. Whole-screen and one-pixel regions are
// dropped. The best eight, by how much detail they hold, are published; the
// log line [mv-target] lists them.
//
// Called by KleptonCompositor beside MetavisionShots (wired in by
// tools/metavision-overlay); everything after the GPU pass runs off the render
// thread.
import Foundation
import Metal
import simd

struct MetavisionTarget {
    let origin: SIMD3<Float>     // the head the frame was rendered from
    let dir: SIMD3<Float>        // unit direction, tracking space
    let score: Float
    let kind: String
}

enum MetavisionTargets {
    static let enabled: Bool = getenv("MV_AUTOPLAY").map { String(cString: $0) == "1" } ?? false
    private static let every: Double = 1.5
    private static let ow = 128
    nonisolated(unsafe) private static var last: Double = 0
    nonisolated(unsafe) private static var busy = false
    nonisolated(unsafe) private static var pipeline: MTLComputePipelineState?
    nonisolated(unsafe) private static var failed = false
    nonisolated(unsafe) private static var current: [MetavisionTarget] = []
    nonisolated(unsafe) private static var stamp: Double = 0
    nonisolated(unsafe) private static var said = 0
    private static let lock = NSLock()

    /// The latest targets, if they are fresh (under 4 s old).
    static func latest() -> [MetavisionTarget] {
        lock.lock(); defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime - stamp < 4 ? current : []
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct P { float4 vp; uint ow; uint oh; uint slice; uint pad; };
    kernel void mv_targets(texture2d_array<float, access::sample> t [[texture(0)]],
                           device float *out [[buffer(0)]],
                           constant P &p [[buffer(1)]],
                           uint2 g [[thread_position_in_grid]]) {
        if (g.x >= p.ow || g.y >= p.oh) return;
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 size = float2(t.get_width(), t.get_height());
        float2 cell = p.vp.zw / float2(p.ow, p.oh);
        float acc = 0;
        for (int j = 0; j < 3; j++) for (int i = 0; i < 3; i++) {
            float2 c = p.vp.xy + (float2(g) + (float2(i, j) + 0.5) / 3.0) * cell;
            acc += dot(t.sample(s, c / size, p.slice).rgb, float3(0.299, 0.587, 0.114));
        }
        out[g.y * p.ow + g.x] = acc / 9.0;
    }
    """

    private struct Params { var vp: SIMD4<Float>; var ow: UInt32; var oh: UInt32; var slice: UInt32; var pad: UInt32 }

    /// `viewport` is the eye's render viewport in texture pixels (x, y, w, h;
    /// zero width = the whole texture), `tangents` its left, right, top, bottom
    /// tangents, `pose` the head (position, orientation) it was rendered from.
    static func offer(_ tex: MTLTexture, slice: Int, flipY: Bool, queue: MTLCommandQueue?,
                      viewport: SIMD4<Int32>, tangents: SIMD4<Float>,
                      pose: (SIMD3<Float>, simd_quatf)) {
        guard enabled, !failed, let queue, tex.textureType == .type2DArray else { return }
        guard tangents.x + tangents.y > 0, tangents.z + tangents.w > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard !busy, now - last >= every else { lock.unlock(); return }
        last = now; busy = true
        lock.unlock()

        let device = queue.device
        if pipeline == nil {
            do {
                let lib = try device.makeLibrary(source: source, options: nil)
                guard let f = lib.makeFunction(name: "mv_targets") else { throw NSError(domain: "mv", code: 1) }
                pipeline = try device.makeComputePipelineState(function: f)
            } catch {
                failed = true
                NSLog("[mv-target] no target finder: %@", "\(error)" as NSString)
                done(); return
            }
        }
        var vp = SIMD4<Float>(Float(viewport.x), Float(viewport.y), Float(viewport.z), Float(viewport.w))
        if vp.z <= 0 || vp.w <= 0 { vp = SIMD4(0, 0, Float(tex.width), Float(tex.height)) }
        let oh = max(16, min(256, Int(Float(ow) * vp.w / vp.z)))
        var p = Params(vp: vp, ow: UInt32(ow), oh: UInt32(oh), slice: UInt32(slice), pad: 0)
        guard let pipeline,
              let buf = device.makeBuffer(length: ow * oh * 4, options: .storageModeShared),
              let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { done(); return }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(tex, index: 0)
        enc.setBuffer(buf, offset: 0, index: 0)
        enc.setBytes(&p, length: MemoryLayout<Params>.stride, index: 1)
        let tg = MTLSize(width: 8, height: 8, depth: 1)
        enc.dispatchThreadgroups(MTLSize(width: (ow + 7) / 8, height: (oh + 7) / 8, depth: 1),
                                 threadsPerThreadgroup: tg)
        enc.endEncoding()
        nonisolated(unsafe) let b = buf
        let w = ow
        cb.addCompletedHandler { _ in
            DispatchQueue.global(qos: .utility).async {
                let found = find(b, w: w, h: oh, flipY: flipY, tangents: tangents, pose: pose)
                lock.lock(); current = found; stamp = ProcessInfo.processInfo.systemUptime; lock.unlock()
                if said < 40 || found.isEmpty == false && said % 10 == 0 {
                    let list = found.prefix(4).map { t -> String in
                        let yaw = atan2f(-t.dir.x, -t.dir.z) * 180 / .pi
                        let pitch = asinf(max(-1, min(1, t.dir.y))) * 180 / .pi
                        return String(format: "%@ %.0f,%.0f (%.0f)", t.kind, yaw, pitch, t.score)
                    }.joined(separator: "; ")
                    NSLog("[mv-target] %ld target(s)%@%@", found.count, found.isEmpty ? "" : ": ", list as NSString)
                }
                said += 1
                done()
            }
        }
        cb.commit()
    }

    private static func done() { lock.lock(); busy = false; lock.unlock() }

    /// Regions worth pressing in a w x h luminance map (row 0 = bottom unless
    /// `flipY`), as directions.
    private static func find(_ buf: MTLBuffer, w: Int, h: Int, flipY: Bool,
                             tangents tg: SIMD4<Float>, pose: (SIMD3<Float>, simd_quatf)) -> [MetavisionTarget] {
        let L = Array(UnsafeBufferPointer(start: buf.contents().assumingMemoryBound(to: Float.self), count: w * h))
        let n = Float(w * h)
        let mean = L.reduce(0, +) / n
        let sd = (L.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n).squareRoot()
        if sd < 0.01 { return [] }                         // a flat frame: nothing to press

        // Edge density: gradient magnitude, box-blurred over 5 x 5.
        var e = [Float](repeating: 0, count: w * h)
        for y in 0..<(h - 1) { for x in 0..<(w - 1) {
            let i = y * w + x
            e[i] = abs(L[i + 1] - L[i]) + abs(L[i + w] - L[i])
        }}
        let d = blur(e, w: w, h: h, r: 2)
        let dm = d.reduce(0, +) / n
        let dsd = (d.reduce(0) { $0 + ($1 - dm) * ($1 - dm) } / n).squareRoot()
        let detail = d.map { $0 > max(dm + 1.5 * dsd, 0.04) }
        // Patches standing out from the frame's own level, either way.
        let lb = blur(L, w: w, h: h, r: 1)
        let bright = lb.map { abs($0 - mean) > max(1.5 * sd, 0.08) }

        var out: [MetavisionTarget] = []
        for (mask, kind) in [(detail, "detail"), (bright, "bright")] {
            for c in components(mask, w: w, h: h) {
                let area = Float(c.count)
                guard area >= 4, area < n * 0.2 else { continue }
                var sx: Float = 0, sy: Float = 0, score: Float = 0
                for i in c { sx += Float(i % w); sy += Float(i / w); score += d[i] }
                let cx = (sx / area + 0.5) / Float(w)
                let cyMem = (sy / area + 0.5) / Float(h)
                let up = flipY ? 1 - cyMem : cyMem          // 0 = bottom of the eye
                let xt = -tg.x + cx * (tg.x + tg.y)
                let yt = -tg.w + up * (tg.z + tg.w)
                let dir = simd_normalize(pose.1.act(SIMD3<Float>(xt, yt, -1)))
                out.append(MetavisionTarget(origin: pose.0, dir: dir,
                                            score: score * 100 * (kind == "bright" ? 0.7 : 1), kind: kind))
            }
        }
        out.sort { $0.score > $1.score }
        // One target per 4 degrees: a region found both ways is one place.
        var kept: [MetavisionTarget] = []
        for t in out where !kept.contains(where: { simd_dot($0.dir, t.dir) > cosf(4 * .pi / 180) }) {
            kept.append(t)
            if kept.count == 8 { break }
        }
        return kept
    }

    private static func blur(_ a: [Float], w: Int, h: Int, r: Int) -> [Float] {
        var t = [Float](repeating: 0, count: w * h), o = t
        for y in 0..<h { for x in 0..<w {
            var s: Float = 0, k: Float = 0
            for dx in -r...r where x + dx >= 0 && x + dx < w { s += a[y * w + x + dx]; k += 1 }
            t[y * w + x] = s / k
        }}
        for y in 0..<h { for x in 0..<w {
            var s: Float = 0, k: Float = 0
            for dy in -r...r where y + dy >= 0 && y + dy < h { s += t[(y + dy) * w + x]; k += 1 }
            o[y * w + x] = s / k
        }}
        return o
    }

    /// 4-connected regions of a mask, as pixel indices.
    private static func components(_ m: [Bool], w: Int, h: Int) -> [[Int]] {
        var seen = [Bool](repeating: false, count: w * h)
        var out: [[Int]] = []
        for s in 0..<(w * h) where m[s] && !seen[s] {
            var stack = [s], comp: [Int] = []
            seen[s] = true
            while let i = stack.popLast() {
                comp.append(i)
                let x = i % w, y = i / w
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && nx < w && ny >= 0 && ny < h {
                    let j = ny * w + nx
                    if m[j] && !seen[j] { seen[j] = true; stack.append(j) }
                }
            }
            out.append(comp)
        }
        return out
    }
}
