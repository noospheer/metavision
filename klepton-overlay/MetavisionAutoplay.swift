// Auto-play for unattended test passes: MV_AUTOPLAY=1 drives both synthetic
// Touch controllers from a fixed script, so a title is pushed past its first
// screen — menus pressed, experiences started — and its log shows what happens
// there, not only that it booted.
//
// The right controller sweeps a grid of directions around the head's forward
// view, a trigger click at each; grip, A, B, X, menu and both thumbsticks are
// mixed in on their own periods. Every action is logged ([mv-autoplay]) so a
// fault can be lined up with what was pressed just before it.
//
// Called at the end of KleptonControllers.update (wired in by
// tools/metavision-overlay), so it overrides whatever the hands produced.
import Foundation
import simd

enum MetavisionAutoplay {
    static let enabled: Bool = getenv("MV_AUTOPLAY").map { String(cString: $0) == "1" } ?? false
    private static var start: Double = 0
    private static var lastStep = -1

    // 5 x 3 grid, degrees from the head's forward: centre first, where menus usually are.
    private static let aims: [(Float, Float)] = {
        var a: [(Float, Float)] = [(0, -5)]
        for p: Float in [-5, -22, 12] { for y: Float in [0, -20, 20, -40, 40] where !(y == 0 && p == -5) { a.append((y, p)) } }
        return a
    }()

    static func drive() {
        guard enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if start == 0 { start = now; NSLog("[mv-autoplay] on: scripted controller input every 1.2 s") }
        let t = now - start
        let step = Int(t / 1.2)
        let phase = t - Double(step) * 1.2

        var px: Float = 0, py: Float = 1.6, pz: Float = 0
        var hx: Float = 0, hy: Float = 0, hz: Float = 0, hw: Float = 1
        kl_ovrp_get_head_pose(&px, &py, &pz, &hx, &hy, &hz, &hw)
        let hp = SIMD3<Float>(px, py, pz)
        var head = simd_quatf(ix: hx, iy: hy, iz: hz, r: hw)
        if !head.real.isFinite { head = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        // Level the head's heading: aim relative to where the user faces, not
        // to how their head happens to be tilted.
        let fwd = head.act(SIMD3<Float>(0, 0, -1))
        let heading = simd_quatf(angle: atan2f(-fwd.x, -fwd.z), axis: SIMD3<Float>(0, 1, 0))

        let (yaw, pitch) = aims[step % aims.count]
        let rq = heading * simd_quatf(angle: yaw * .pi / 180, axis: SIMD3<Float>(0, 1, 0))
                         * simd_quatf(angle: pitch * .pi / 180, axis: SIMD3<Float>(1, 0, 0))
        let rp = hp + heading.act(SIMD3<Float>(0.18, -0.30, -0.25))
        let lq = heading * simd_quatf(angle: -10 * .pi / 180, axis: SIMD3<Float>(1, 0, 0))
        let lp = hp + heading.act(SIMD3<Float>(-0.18, -0.30, -0.25))

        let click = phase > 0.6 && phase < 0.8
        var rb: UInt32 = 0, lb: UInt32 = 0
        var rTrig: Float = 0, rGrip: Float = 0, lTrig: Float = 0, lGrip: Float = 0
        var rStick = SIMD2<Float>(0, 0), lStick = SIMD2<Float>(0, 0)
        var what = "aim \(Int(yaw)),\(Int(pitch)) + trigger"
        if click { rb |= OVRPRawButton.rIndexTrigger; rTrig = 1 }
        if step % 8 == 5 && click { rb |= OVRPRawButton.a; what += ", A" }
        if step % 13 == 9 && click { rb |= OVRPRawButton.b; what += ", B" }
        if step % 11 == 7 && phase > 0.3 { rb |= OVRPRawButton.rHandTrigger; rGrip = 1; what += ", grip held" }
        if step % 10 == 3 && click { lb |= OVRPRawButton.lIndexTrigger | OVRPRawButton.x; lTrig = 1; what += ", left trigger + X" }
        if step % 12 == 6 && phase > 0.3 { lb |= OVRPRawButton.lHandTrigger; lGrip = 1; what += ", left grip" }
        if step % 7 == 4 { rStick = SIMD2(0, 1); lStick = SIMD2(0, 1); what += ", sticks forward" }
        if step % 9 == 2 { rStick = SIMD2(1, 0); what += ", right stick turn" }
        if step % 29 == 17 && click { lb |= OVRPRawButton.start; what += ", MENU" }

        if step != lastStep {
            lastStep = step
            NSLog("[mv-autoplay] t=%.1fs step %ld: %@", t, step, what as NSString)
        }
        kl_ovrp_set_hand_motion(1, rp.x, rp.y, rp.z, rq.imag.x, rq.imag.y, rq.imag.z, rq.real, 0, 0, 0, 0, 0, 0)
        kl_ovrp_set_controller_input(1, rb, rb, rTrig, rGrip, rStick.x, rStick.y)
        kl_ovrp_set_hand_motion(0, lp.x, lp.y, lp.z, lq.imag.x, lq.imag.y, lq.imag.z, lq.real, 0, 0, 0, 0, 0, 0)
        kl_ovrp_set_controller_input(0, lb, lb, lTrig, lGrip, lStick.x, lStick.y)
    }
}
