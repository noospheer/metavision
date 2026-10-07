import Foundation

/// One record as emitted by `tools/metavision-triage`.
struct TitleRecord: Codable, Identifiable, Hashable {
    var id: String { pkg }

    let pkg: String
    var name: String?
    var status: Status
    var backend: String?
    var xr: XRRuntime?
    var gfx: String?
    var gaze: GazeModel?
    var jit: String?
    var note: String?

    /// Triage verdict. `noasset` is resolved at runtime, not by the script:
    /// it is the one failure a user can fix without a rebuild.
    enum Status: String, Codable {
        case ok      = "OK"
        case wip     = "WIP"
        case jit     = "JIT"
        case arch32  = "ARCH32"
        case isa     = "ISA"
        case abandon = "ABANDON"
        case noasset = "NOASSET"

        var isRunnable: Bool { self == .ok || self == .wip }
    }

    enum XRRuntime: String, Codable {
        case openxr = "OPENXR"
        case vrapi  = "VRAPI"
        case none   = "NONE"
    }

    /// How gaze reaches this title. Determined by the render path, not by choice.
    enum GazeModel: String, Codable {
        /// Entity-composited. HoverEffectComponent(.shader) feeds continuous
        /// intensity to a ShaderGraphMaterial. Never leaves the compositor.
        case shader = "SHADER"
        /// Gaze resolved once at pinch-down; hand delta drives it thereafter.
        case pinch  = "PINCH"
        /// Consumed inside a Foveated Streaming session, never exposed.
        case fovea  = "FOVEA"
        /// Raw framebuffer submit. No entity tree, so no hover path at all.
        case none   = "NONE"

        var summary: String {
            switch self {
            case .shader: "continuous intensity in-material"
            case .pinch:  "single sample at pinch-down"
            case .fovea:  "consumed in-session, never exposed"
            case .none:   "unavailable on this render path"
            }
        }

        /// Rows whose gaze model is `.none` get no hover affordance, so the UI
        /// tells the truth about what the title can actually do.
        var respondsToHover: Bool { self != .none }
    }

    var displayName: String { name ?? pkg }
}

struct Manifest: Codable {
    var titles: [TitleRecord]
}
