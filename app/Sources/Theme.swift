import SwiftUI

/// Phosphor CRT palette. Vision Pro is video passthrough on an opaque display,
/// so black renders as true black — this design would fail on an optical
/// see-through headset, where the ground would be transparent.
enum Phosphor {
    static let ground = Color(red: 0.02, green: 0.03, blue: 0.04)
    static let panel  = Color(red: 0.03, green: 0.05, blue: 0.06)
    /// #4AF626 — full #00FF00 blooms on these displays and fatigues quickly.
    static let green  = Color(red: 0.29, green: 0.96, blue: 0.15)
    static let dim    = Color(red: 0.25, green: 0.66, blue: 0.17)
    static let ghost  = Color(red: 0.09, green: 0.23, blue: 0.07)
    static let amber  = Color(red: 1.00, green: 0.69, blue: 0.00)
    static let fault  = Color(red: 1.00, green: 0.37, blue: 0.34)
    static let fovea  = Color(red: 0.31, green: 0.84, blue: 0.88)

    static let mono = Font.system(.body, design: .monospaced)
    static func label(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }
}

extension TitleRecord.Status {
    var tint: Color {
        switch self {
        case .ok:      Phosphor.dim
        case .wip:     Phosphor.amber
        case .noasset: Phosphor.amber
        default:       Phosphor.fault
        }
    }
}

extension TitleRecord.GazeModel {
    var tint: Color {
        switch self {
        case .shader: Phosphor.green
        case .pinch:  Phosphor.dim
        case .fovea:  Phosphor.fovea
        case .none:   Phosphor.ghost
        }
    }
}
