// Auto-play for unattended test passes: with MV_AUTOPLAY=1 a fixed script
// pushes a title past its first screen (menus pressed, experiences started) so
// its log shows what happens there, not only that it booted.
//
// The script goes in through the input path of the current input mode, so
// each mode's own code is what gets exercised:
//
//   hands      synthetic Touch controllers AND synthetic Meta hand skeletons
//              (pinching on each click), so controller titles and hand-tracking
//              titles both get input
//   handsfree  no controllers or hands touched: a gaze select (as visionOS
//              reports one) plus spoken commands — select, grab, confirm, back,
//              menu, hold/release — into MetavisionHandsFree, which turns them
//              into the pointer and buttons as it does for a user
//   auto       the two alternating every 20 s, as a hand coming into and
//              leaving view would
//
// Either way it aims at a grid of directions around the head's forward view, a
// click at each, with other buttons and both thumbsticks on their own periods.
//
// The head moves too (MV_AUTOPLAY_HEAD=0 holds it still): the pose the title
// sees looks left and right, up and down, turns right round once a minute,
// steps forward, back and sideways and crouches — for titles that react to
// where the user looks or goes. The display is not moved, so anyone wearing
// the headset during a pass sees the picture swing.
//
// In hands-free mode the commands are spoken: synthesised speech replaces the
// microphone's input (MetavisionVoice.say), so the recogniser itself is
// tested; the log records each phrase said and each command heard. Without
// speech permission (or MV_AUTOPLAY_SPEECH=0) they are handed over directly.
// Every action is logged ([mv-autoplay]) so a fault lines up with what was
// pressed just before it.
//
// Called at the end of KleptonControllers.update (wired in by
// tools/metavision-overlay), so it overrides whatever the hands produced.
import Foundation
import simd

@_silgen_name("mv_hands_publish")
private func mv_hands_publish_ap(_ hand: Int32, _ tracked: Int32,
                                 _ model: UnsafePointer<Float>?, _ root: UnsafePointer<Float>?,
                                 _ pointer: UnsafePointer<Float>?, _ pinch: UnsafePointer<Float>?,
                                 _ time: Double)

enum MetavisionAutoplay {
    static let enabled: Bool = getenv("MV_AUTOPLAY").map { String(cString: $0) == "1" } ?? false
    private static var start: Double = 0
    private static var lastStep = -1
    private static var lastPath = ""
    static let movesHead: Bool = enabled && (getenv("MV_AUTOPLAY_HEAD").map { String(cString: $0) != "0" } ?? true)
    static let speaks: Bool = enabled && (getenv("MV_AUTOPLAY_SPEECH").map { String(cString: $0) != "0" } ?? true)
    private static var headStart: Double = 0
    private static var headNow_ = ""
    private static let headLock = NSLock()
    /// Written on the render thread, read on the controller thread.
    private static var headNow: String {
        get { headLock.lock(); defer { headLock.unlock() }; return headNow_ }
        set { headLock.lock(); headNow_ = newValue; headLock.unlock() }
    }

    // 5 x 3 grid, degrees from the head's forward: centre first, where menus usually are.
    private static let aims: [(Float, Float)] = {
        var a: [(Float, Float)] = [(0, -5)]
        for p: Float in [-5, -22, 12] { for y: Float in [0, -20, 20, -40, 40] where !(y == 0 && p == -5) { a.append((y, p)) } }
        return a
    }()

    static func drive() {
        guard enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if start == 0 {
            start = now
            NSLog("[mv-autoplay] on: scripted input every 1.2 s, input mode %@",
                  MetavisionHandsFree.shared.mode.rawValue as NSString)
        }
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
        let aim = heading * simd_quatf(angle: yaw * .pi / 180, axis: SIMD3<Float>(0, 1, 0))
                          * simd_quatf(angle: pitch * .pi / 180, axis: SIMD3<Float>(1, 0, 0))

        let viaHandsFree: Bool
        switch MetavisionHandsFree.shared.mode {
        case .hands:     viaHandsFree = false
        case .handsfree: viaHandsFree = true
        case .auto:      viaHandsFree = Int(t / 20) % 2 == 1
        }
        let path = viaHandsFree ? "hands-free" : "controllers+hands"
        if path != lastPath { lastPath = path; NSLog("[mv-autoplay] input path: %@", path as NSString) }

        let what = viaHandsFree
            ? handsFree(step: step, head: hp, aim: aim)
            : controllersAndHands(step: step, phase: phase, now: now, head: hp, heading: heading, aim: aim)
        if step != lastStep {
            lastStep = step
            NSLog("[mv-autoplay] t=%.1fs step %ld: aim %ld,%ld%@%@", t, step, Int(yaw), Int(pitch), what as NSString,
                  headNow as NSString)
        }
    }

    // MARK: head motion

    /// The head pose the title is given: the real one, moved by the script.
    /// Called by KleptonCompositor where it publishes the head (patched in by
    /// tools/metavision-overlay); returns the pose unchanged when not moving.
    static func moveHead(_ pose: (SIMD3<Float>, simd_quatf)) -> (SIMD3<Float>, simd_quatf) {
        guard movesHead else { return pose }
        let now = ProcessInfo.processInfo.systemUptime
        if headStart == 0 { headStart = now; NSLog("[mv-autoplay] head motion on") }
        let t = Float(now - headStart)
        let tau: Float = 2 * .pi
        let m = t.truncatingRemainder(dividingBy: 60)
        func ramp(_ a: Float, _ b: Float) -> Float { min(1, max(0, (m - a) / (b - a))) }
        // Look around; once a minute (40-50 s) turn right round and back.
        let turn = ramp(40, 42) - ramp(48, 50)
        let yaw = 75 * sinf(tau * t / 16) * (1 - turn) + 180 * turn
        let pitch = 25 * sinf(tau * t / 7)
        // Walk about a metre each way, sidestep, and crouch at 20-26 s.
        let fwd = 0.6 * sinf(tau * t / 30), side = 0.3 * sinf(tau * t / 22)
        let crouch = 0.35 * (ramp(20, 21) - ramp(25, 26))

        let (p, q) = pose
        let f = q.act(SIMD3<Float>(0, 0, -1))
        let heading = simd_quatf(angle: atan2f(-f.x, -f.z), axis: SIMD3<Float>(0, 1, 0))
        let ry = simd_quatf(angle: yaw * .pi / 180, axis: SIMD3<Float>(0, 1, 0))
        let rx = simd_quatf(angle: pitch * .pi / 180, axis: SIMD3<Float>(1, 0, 0))
        let np = p + heading.act(SIMD3<Float>(side, -crouch, -fwd))
        headNow = String(format: "; head yaw %.0f pitch %.0f, at %+.2f,%+.2f%@", yaw, pitch, side, -fwd,
                         crouch > 0.1 ? ", crouching" : "")
        return (np, ry * q * rx)
    }

    // MARK: hands mode — controllers and Meta hand skeletons

    private static func controllersAndHands(step: Int, phase: Double, now: Double, head hp: SIMD3<Float>,
                                            heading: simd_quatf, aim rq: simd_quatf) -> String {
        let rp = hp + heading.act(SIMD3<Float>(0.18, -0.30, -0.25))
        let lq = heading * simd_quatf(angle: -10 * .pi / 180, axis: SIMD3<Float>(1, 0, 0))
        let lp = hp + heading.act(SIMD3<Float>(-0.18, -0.30, -0.25))

        var rb: UInt32 = 0, lb: UInt32 = 0
        var rTrig: Float = 0, rGrip: Float = 0, lTrig: Float = 0, lGrip: Float = 0
        var rStick = SIMD2<Float>(0, 0), lStick = SIMD2<Float>(0, 0)
        var what = " + trigger/pinch"
        let click = phase > 0.6 && phase < 0.8
        let phaseLate = phase > 0.3
        if click { rb |= OVRPRawButton.rIndexTrigger; rTrig = 1 }
        if step % 8 == 5 && click { rb |= OVRPRawButton.a; what += ", A" }
        if step % 13 == 9 && click { rb |= OVRPRawButton.b; what += ", B" }
        if step % 11 == 7 && phaseLate { rb |= OVRPRawButton.rHandTrigger; rGrip = 1; what += ", grip held" }
        let leftClick = step % 10 == 3 && click
        if leftClick { lb |= OVRPRawButton.lIndexTrigger | OVRPRawButton.x; lTrig = 1; what += ", left trigger/pinch + X" }
        if step % 12 == 6 && phaseLate { lb |= OVRPRawButton.lHandTrigger; lGrip = 1; what += ", left grip" }
        if step % 7 == 4 { rStick = SIMD2(0, 1); lStick = SIMD2(0, 1); what += ", sticks forward" }
        if step % 9 == 2 { rStick = SIMD2(1, 0); what += ", right stick turn" }
        if step % 29 == 17 && click { lb |= OVRPRawButton.start; what += ", MENU" }

        kl_ovrp_set_hand_motion(1, rp.x, rp.y, rp.z, rq.imag.x, rq.imag.y, rq.imag.z, rq.real, 0, 0, 0, 0, 0, 0)
        kl_ovrp_set_controller_input(1, rb, rb, rTrig, rGrip, rStick.x, rStick.y)
        kl_ovrp_set_hand_motion(0, lp.x, lp.y, lp.z, lq.imag.x, lq.imag.y, lq.imag.z, lq.real, 0, 0, 0, 0, 0, 0)
        kl_ovrp_set_controller_input(0, lb, lb, lTrig, lGrip, lStick.x, lStick.y)

        // The same two hands as Meta hand skeletons, pinching where the
        // controllers click; a grip is a full fist-like pinch of every finger.
        publishHand(1, at: rp, rq, pinch: click ? 1 : 0, grip: rGrip > 0, now: now)
        publishHand(0, at: lp, lq, pinch: leftClick ? 1 : 0, grip: lGrip > 0, now: now)
        return what
    }

    /// A plausible open hand in its wrist frame (metres; palm down, fingers
    /// along -Z), in OVR bone order; the thumb tip closes on the index tip as
    /// `pinch` goes to 1.
    private static func publishHand(_ hand: Int, at p: SIMD3<Float>, _ q: simd_quatf,
                                    pinch: Float, grip: Bool, now: Double) {
        let s: Float = hand == 1 ? 1 : -1          // left hand: mirrored across X
        let indexTip = SIMD3<Float>(-0.02, 0, -0.18)
        let pinched = indexTip + SIMD3<Float>(0, -0.005, 0.005)
        let thumbTip = simd_mix(SIMD3<Float>(-0.052, 0, -0.105), pinched, SIMD3<Float>(repeating: pinch))
        func v(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> { SIMD3<Float>(x, y, z) }
        let pin = SIMD3<Float>(repeating: pinch)
        var pts = [SIMD3<Float>]()
        pts.append(v(0, 0, 0)); pts.append(v(0, 0, 0.03))                              // wrist, forearm
        pts.append(v(-0.02, 0, -0.02)); pts.append(v(-0.035, 0, -0.04))                 // thumb 0, 1
        pts.append(simd_mix(v(-0.045, 0, -0.065), thumbTip, pin * 0.3))                 // thumb 2
        pts.append(simd_mix(v(-0.05, 0, -0.085), thumbTip, pin * 0.6))                  // thumb 3
        for x: Float in [-0.02, 0, 0.02] {                                              // index, middle, ring 1-3
            let l: Float = x == 0 ? 0.005 : 0
            pts.append(v(x, 0, -0.09 - l)); pts.append(v(x, 0, -0.13 - l)); pts.append(v(x, 0, -0.155 - l))
        }
        pts.append(v(0.02, 0, -0.03)); pts.append(v(0.035, 0, -0.08))                   // little 0-3
        pts.append(v(0.035, 0, -0.11)); pts.append(v(0.035, 0, -0.13))
        pts.append(thumbTip); pts.append(indexTip)                                      // tips
        pts.append(v(0, 0, -0.19)); pts.append(v(0.02, 0, -0.18)); pts.append(v(0.035, 0, -0.15))
        var model = [Float](); model.reserveCapacity(24 * 7)
        for b in pts { model += [0, 0, 0, 1, b.x * s, b.y, b.z] }
        let pose: [Float] = [q.imag.x, q.imag.y, q.imag.z, q.real, p.x, p.y, p.z]
        let g: Float = grip ? 1 : 0
        let strength: [Float] = [pinch, pinch, g, g, g]
        model.withUnsafeBufferPointer { m in pose.withUnsafeBufferPointer { r in
            strength.withUnsafeBufferPointer { st in
                mv_hands_publish_ap(Int32(hand), 1, m.baseAddress, r.baseAddress, r.baseAddress, st.baseAddress, now)
            }
        }}
    }

    // MARK: hands-free mode — gaze selects and spoken commands

    private static func handsFree(step: Int, head: SIMD3<Float>, aim: simd_quatf) -> String {
        let hf = MetavisionHandsFree.shared
        // A look in the aim direction, refreshed every frame: visionOS reports
        // the gaze only with a select, so this is what Dwell Control would give.
        hf.noteSelection(origin: head, direction: aim.act(SIMD3<Float>(0, 0, -1)))
        var what = " (gaze)"
        guard step != lastStep else { return what }
        // Spoken commands fire once per step, at the step's start.
        var cmds: [MetavisionVoice.Command] = [.select]
        if step % 8 == 5 { cmds.append(.confirm) }
        if step % 13 == 9 { cmds.append(.back) }
        if step % 11 == 7 { cmds.append(.grab) }
        if step % 29 == 17 { cmds.append(.menu) }
        if step % 17 == 11 { cmds.append(.hold) }
        if step % 17 == 13 { cmds.append(.release) }
        let words = cmds.map { $0.rawValue }.joined(separator: ", ")
        if speaks && MetavisionVoice.shared.say(words) {
            what += " + say \"" + words + "\""
        } else {
            for c in cmds { hf.inject(c) }
            what += " + command " + words
        }
        return what
    }
}
