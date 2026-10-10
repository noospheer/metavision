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
// MV_AUTOPLAY_CYCLE=<seconds> runs all three in one launch instead — hands,
// then hands-free, then auto, that long each (start in auto so the audio
// session has the microphone) — so a test pass boots each title once.
//
// Either way it aims at what looks pressable in the picture the title drew —
// text, icons, buttons, found by MetavisionTargets every 1.5 s — resting on
// each before a click, least-tried first, so a menu's buttons are actually
// pressed rather than hit by chance. One step in four (and every step while
// nothing is found) it sweeps instead: a dense 7.5-degree scan of where menus
// sit, then a wider grid, alternating between aiming from where the title
// started (menus placed in the world) and from where the head faces now (menus
// that follow the head). Other buttons and both thumbsticks run on their own
// periods.
//
// After the first 30 s — when menus are up — the head moves too
// (MV_AUTOPLAY_HEAD=0 holds it still): the pose the title sees looks left and
// right, up and down, turns right round once a minute,
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
    static let cycle: Double = getenv("MV_AUTOPLAY_CYCLE").flatMap { Double(String(cString: $0)) } ?? 0
    private static let cycleModes: [MetavisionHandsFree.Mode] = [.hands, .handsfree, .auto]
    /// A hands-only title (MV_HANDS_ONLY, set by the launcher from its manifest)
    /// is opened with a two-hand start gesture first: such titles commonly wait
    /// for both hands near the face, or for both hands' thumb and index tips
    /// touching, held for seconds, before they start what they draw.
    private static var handsOnly: Bool { getenv("MV_HANDS_ONLY").map { String(cString: $0) == "1" } ?? false }
    private static let gestureFrom = 1.0, gestureLen = 22.0
    private static var gestureSaid = false
    private static var headNow_ = ""
    private static let headLock = NSLock()
    /// Written on the render thread, read on the controller thread.
    private static var headNow: String {
        get { headLock.lock(); defer { headLock.unlock() }; return headNow_ }
        set { headLock.lock(); headNow_ = newValue; headLock.unlock() }
    }

    // Where to aim, degrees (yaw, pitch) from forward. First a dense scan of
    // where menus sit — 7.5 degree steps (a button 2 m away spans about 8),
    // centre outwards — then a wider grid for what is further out.
    private static let aims: [(Float, Float)] = {
        var dense: [(Float, Float)] = []
        for p: Float in [-5, 2.5, -12.5, 10, -20, -27.5] {
            for y in stride(from: Float(-30), through: 30, by: 7.5) { dense.append((y, p)) }
        }
        dense.sort { abs($0.0) + abs($0.1 + 5) < abs($1.0) + abs($1.1 + 5) }
        var wide: [(Float, Float)] = []
        for p: Float in [-5, -22, 12] { for y: Float in [-45, 45, -60, 60] { wide.append((y, p)) } }
        return dense + wide
    }()
    /// Seconds per aim: about 0.35 s of hover before the click, as a pointer
    /// has to rest on a control before a press counts.
    private static let period = 0.7
    /// Where the title started, levelled: menus are placed in front of that, and
    /// the scripted head motion must not carry the aim away from them.
    nonisolated(unsafe) private static var origin: (SIMD3<Float>, simd_quatf)?
    /// The head holds still this long first — when a title's menus are up.
    private static let headHold: Float = 30
    nonisolated(unsafe) private static var headSaid = false
    /// The target this step aims at (origin, direction), held for the whole step.
    nonisolated(unsafe) private static var target: (SIMD3<Float>, SIMD3<Float>, String)?
    /// How often each 4-degree patch of directions has been pressed.
    nonisolated(unsafe) private static var tried: [Int: Int] = [:]
    nonisolated(unsafe) private static var sweepStep = 0

    private static func yawPitch(_ d: SIMD3<Float>) -> (Float, Float) {
        (atan2f(-d.x, -d.z) * 180 / .pi, asinf(max(-1, min(1, d.y))) * 180 / .pi)
    }

    /// At a step's start: the least-pressed of the latest targets, or nil to sweep.
    private static func pickTarget(step: Int) -> (SIMD3<Float>, SIMD3<Float>, String)? {
        let ts = MetavisionTargets.latest()
        guard !ts.isEmpty, step % 4 != 3 else { return nil }
        func key(_ d: SIMD3<Float>) -> Int {
            let (y, p) = yawPitch(d)
            return Int((y + 360).rounded() / 4) * 1000 + Int((p + 90).rounded() / 4)
        }
        let best = ts.enumerated().min { a, b in
            let ca = tried[key(a.element.dir)] ?? 0, cb = tried[key(b.element.dir)] ?? 0
            return ca != cb ? ca < cb : a.offset < b.offset
        }!.element
        tried[key(best.dir), default: 0] += 1
        return (best.origin, best.dir, best.kind)
    }

    static func drive() {
        guard enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if start == 0 {
            start = now
            NSLog("[mv-autoplay] on: scripted input every %.1f s, input mode %@", period,
                  MetavisionHandsFree.shared.mode.rawValue as NSString)
        }
        let t = now - start
        let step = Int(t / period)
        let phase = t - Double(step) * period

        var px: Float = 0, py: Float = 1.6, pz: Float = 0
        var hx: Float = 0, hy: Float = 0, hz: Float = 0, hw: Float = 1
        kl_ovrp_get_head_pose(&px, &py, &pz, &hx, &hy, &hz, &hw)
        let hp = SIMD3<Float>(px, py, pz)
        var head = simd_quatf(ix: hx, iy: hy, iz: hz, r: hw)
        if !head.real.isFinite { head = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        // Level the head's heading: aim relative to where the user faces, not
        // to how their head happens to be tilted.
        let fwd = head.act(SIMD3<Float>(0, 0, -1))
        let facing = simd_quatf(angle: atan2f(-fwd.x, -fwd.z), axis: SIMD3<Float>(0, 1, 0))
        if origin == nil { origin = (hp, facing) }
        // Alternate sweeps: from where the title started (menus placed in the
        // world), then from where the head now faces (menus that follow the head).
        if step != lastStep {
            target = pickTarget(step: step)
            if target == nil { sweepStep += 1 }
        }
        let fromStart = (sweepStep / aims.count) % 2 == 0
        var (base, heading) = fromStart ? origin! : (hp, facing)
        var (yaw, pitch) = aims[sweepStep % aims.count]
        var aim = heading * simd_quatf(angle: yaw * .pi / 180, axis: SIMD3<Float>(0, 1, 0))
                          * simd_quatf(angle: pitch * .pi / 180, axis: SIMD3<Float>(1, 0, 0))
        var aimFrom: SIMD3<Float>? = nil
        if let tg = target {
            let o = tg.0, d = tg.1
            // Aimed in world terms, from just below the eye the frame was drawn
            // from, so the ray lands where the region was seen.
            (yaw, pitch) = yawPitch(d)
            aim = simd_quatf(angle: yaw * .pi / 180, axis: SIMD3<Float>(0, 1, 0))
                * simd_quatf(angle: pitch * .pi / 180, axis: SIMD3<Float>(1, 0, 0))
            base = o
            heading = simd_quatf(angle: yaw * .pi / 180, axis: SIMD3<Float>(0, 1, 0))
            aimFrom = o + SIMD3<Float>(0, -0.04, 0)
        }

        let gesture = handsOnly && t >= gestureFrom && t < gestureFrom + gestureLen
        if cycle > 0 {
            // The start gesture's time comes before the cycle, so every mode keeps its share.
            let tc = handsOnly ? max(0, t - gestureFrom - gestureLen) : t
            let m = cycleModes[min(Int(tc / cycle), cycleModes.count - 1)]
            if MetavisionHandsFree.shared.mode != m {
                MetavisionHandsFree.shared.setMode(m, remember: false)
                NSLog("[mv-autoplay] t=%.1fs mode cycle: %@", t, m.rawValue as NSString)
            }
        }
        let viaHandsFree: Bool
        switch MetavisionHandsFree.shared.mode {
        case .hands:     viaHandsFree = false
        case .handsfree: viaHandsFree = true
        case .auto:      viaHandsFree = Int(t / (cycle > 0 ? 5 : 20)) % 2 == 1   // faster inside a cycle
        }
        let path = viaHandsFree ? "hands-free" : "controllers+hands"
        if path != lastPath { lastPath = path; NSLog("[mv-autoplay] input path: %@", path as NSString) }

        let what = gesture
            ? twoHandGesture(head: hp, heading: facing, now: now)
            : viaHandsFree
            ? handsFree(step: step, head: base, aim: aim)
            : controllersAndHands(step: step, phase: phase, now: now, head: base, heading: heading, aim: aim,
                                  rightAt: aimFrom)
        if step != lastStep {
            lastStep = step
            let src = target.map { "target (" + $0.2 + ")" } ?? (fromStart ? "start" : "head")
            NSLog("[mv-autoplay] t=%.1fs step %ld: aim %.1f,%.1f from %@%@%@", t, step, yaw, pitch,
                  src as NSString, what as NSString, headNow as NSString)
        }
    }

    // MARK: head motion

    /// The head pose the title is given: the real one, moved by the script.
    /// Called by KleptonCompositor where it publishes the head (patched in by
    /// tools/metavision-overlay); returns the pose unchanged when not moving.
    static func moveHead(_ pose: (SIMD3<Float>, simd_quatf)) -> (SIMD3<Float>, simd_quatf) {
        guard movesHead else { return pose }
        let now = ProcessInfo.processInfo.systemUptime
        if headStart == 0 { headStart = now }
        let held = Float(now - headStart)
        if held < headHold { headNow = "; head still"; return pose }
        if !headSaid { headSaid = true; NSLog("[mv-autoplay] head motion on") }
        let t = held - headHold
        let ease = min(1, t / 3)                 // ease in, no jump
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
        let ry = simd_quatf(angle: ease * yaw * .pi / 180, axis: SIMD3<Float>(0, 1, 0))
        let rx = simd_quatf(angle: ease * pitch * .pi / 180, axis: SIMD3<Float>(1, 0, 0))
        let np = p + heading.act(ease * SIMD3<Float>(side, -crouch, -fwd))
        headNow = String(format: "; head yaw %.0f pitch %.0f, at %+.2f,%+.2f%@", yaw, pitch, side, -fwd,
                         crouch > 0.1 ? ", crouching" : "")
        return (np, ry * q * rx)
    }

    // MARK: hands mode — controllers and Meta hand skeletons

    private static func controllersAndHands(step: Int, phase: Double, now: Double, head hp: SIMD3<Float>,
                                            heading: simd_quatf, aim rq: simd_quatf,
                                            rightAt: SIMD3<Float>? = nil) -> String {
        let rp = rightAt ?? hp + heading.act(SIMD3<Float>(0.18, -0.30, -0.25))
        let lq = heading * simd_quatf(angle: -10 * .pi / 180, axis: SIMD3<Float>(1, 0, 0))
        let lp = hp + heading.act(SIMD3<Float>(-0.18, -0.30, -0.25))

        var rb: UInt32 = 0, lb: UInt32 = 0
        var rTrig: Float = 0, rGrip: Float = 0, lTrig: Float = 0, lGrip: Float = 0
        var rStick = SIMD2<Float>(0, 0), lStick = SIMD2<Float>(0, 0)
        var what = " + trigger/pinch"
        let click = phase > 0.35 && phase < 0.5
        let phaseLate = phase > 0.2
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
    /// Both hands up in front of the face, palms down, no pinch, held still:
    /// middle knuckles about 0.33 m from the eye, thumb tips 3.4 cm and index
    /// tips 3.0 cm apart (publishHand's hand model) — inside the common gates of
    /// "hands within 0.4 m of the head" and "fingertips within 5 cm".
    private static func twoHandGesture(head hp: SIMD3<Float>, heading q: simd_quatf, now: Double) -> String {
        let d: Float = 0.035
        let rp = hp + q.act(SIMD3<Float>( d, -0.15, -0.20))
        let lp = hp + q.act(SIMD3<Float>(-d, -0.15, -0.20))
        kl_ovrp_set_hand_motion(1, rp.x, rp.y, rp.z, q.imag.x, q.imag.y, q.imag.z, q.real, 0, 0, 0, 0, 0, 0)
        kl_ovrp_set_hand_motion(0, lp.x, lp.y, lp.z, q.imag.x, q.imag.y, q.imag.z, q.real, 0, 0, 0, 0, 0, 0)
        kl_ovrp_set_controller_input(1, 0, 0, 0, 0, 0, 0)
        kl_ovrp_set_controller_input(0, 0, 0, 0, 0, 0, 0)
        publishHand(1, at: rp, q, pinch: 0, grip: false, now: now)
        publishHand(0, at: lp, q, pinch: 0, grip: false, now: now)
        if !gestureSaid { gestureSaid = true; NSLog("[mv-autoplay] two-hand start gesture for a hands-only title (%.0f s)", gestureLen) }
        return " + two-hand gesture (hands at face, thumb and index tips touching)"
    }

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
        // A spoken phrase every other aim: speech takes about as long as an aim.
        guard step != lastStep, step % 2 == 0 else { return what }
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
