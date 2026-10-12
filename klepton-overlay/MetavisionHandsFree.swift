// MetavisionHandsFree.swift — play with eyes and voice, no hands.
//
// Copied into Klepton's app by tools/metavision-overlay and wired into
// KleptonControllers.swift by two small patches there.
//
// Klepton builds its synthetic Touch controllers from tracked hands. With no
// hand in view the guest gets no controller pose, so a title's laser points
// nowhere and a select lands on nothing. Three input modes:
//
//   auto       (default) hands when a hand is in view, hands-free when not
//   hands      Klepton's own behaviour only; no speech recognition
//   handsfree  always hands-free, ignoring tracked hands — for involuntary
//              movement, tremor or spasticity, where a hand the headset sees
//              would otherwise take control or click by accident
//
// The mode is chosen in the launcher (remembered), by voice ("auto mode",
// "hands mode", "hands-free mode"), or with MV_INPUT_MODE. Hands-free supplies
// both controllers whenever no hand or Sense controller tracks them:
//
//   * pose:   right: a pointer just below the eyes, aimed at the point 2 m
//             along the head's forward direction (where the reticle the
//             compositor draws sits); for a moment after any system
//             select (Dwell Control, Voice Control, a pinch), aimed along the
//             gaze ray visionOS reports with that select instead.
//             left: below and left of the head, aimed along
//             the head's forward direction. Both are published as tracked, so
//             titles that want two controllers present (OVRPlugin and OpenXR
//             alike) have them
//   * select: the system's select, or the spoken word "select" ("click",
//             "okay", "tap", "press"), recognised on device. A short tick
//             says a command was heard.
//   * voice:  the other buttons by name, on device:
//               select | click | okay      tap the right trigger
//               grab | grip                tap the right grip
//               hold ... release | drop    hold trigger + grip until released
//               confirm | accept           tap A
//               back | cancel              tap B
//               menu | pause               tap Menu (left controller)
//               recenter                   recenter the view
//               auto | hands | hands-free mode   switch input mode
//               exit title | close title | go home | quit metavision ...
//                                          asks "Leave this title? Say confirm.";
//                                          "confirm" or "yes" within 5 s leaves
//                                          (the app ends; reopen it for the
//                                          launcher), "back" or silence stays
//               Siri                       lets go of the microphone for
//                                          MV_SIRI_PAUSE s (20), so saying
//                                          "Siri" again reaches Siri
//             the left controller:
//               left select | left trigger | left click   tap the left trigger
//               left grab | left grip      tap the left grip
//               X button | X               tap X
//               Y button | Y               tap Y
//               both hold ... release      hold both hands' trigger + grip
//             moving (left stick walks and strafes, right stick turns):
//               forward | go | walk        left stick forward
//               back up | backward | reverse | go back   left stick back
//               left | right               left stick sideways (strafe)
//               turn left | turn right     right stick flicked (snap turn)
//               keep going                 the last move held until "stop"
//               stop | halt                sticks released
//             A move holds its stick for MV_VOICE_MOVE seconds (1.5), a turn
//             for MV_VOICE_TURN (0.25: a flick, as snap turning wants).
//             Collisions are resolved by the longer phrase: "back" alone is
//             B, "back up" moves; "left" alone strafes, "left select" is the
//             left trigger; "hold" is the right hand, "both hold" both.
//             Moving and left-hand phrases (everyday words) count only as a
//             short phrase of their own: after a pause or another command and
//             followed by one, so conversation does not move the player.
//
// Switches (environment or Documents/klepton.env):
//   MV_INPUT_MODE=auto|hands|handsfree   overrides the remembered mode
//   MV_VOICE=0                           no speech recognition in any mode
//   MV_HANDS_FREE=0                      same as MV_INPUT_MODE=hands (older name)
//   MV_VOICE_MOVE=<seconds>              how long a spoken move holds the stick (1.5)
//   MV_VOICE_TURN=<seconds>              how long a spoken turn holds it (0.25)
//   MV_VOICE_HINT=confirmation|search|dictation|unspecified   the recogniser's
//                                        task hint (confirmation: short commands)
//   MV_VOICE_LM=0                        no custom language model for the commands
//   MV_VOICE_CUE=0                       no sound when a command is heard
//   MV_VOICE_LOG=<n>                     transcripts/restarts logged in full (400),
//                                        then every 25th
//   MV_SIRI_PAUSE=<seconds>              how long "Siri" lets go of the microphone (20)
//
// The recogniser (MetavisionVoice) logs every microphone (re)build with its
// format and route, each transcript it hears, each task restart and error,
// and a health line every 30 s (buffers/s, peak level, counts), so a user's
// log shows whether the microphone delivered audio and what was heard.
import AVFoundation
import Foundation
import Speech
import UIKit
import simd

final class MetavisionHandsFree {
    static let shared = MetavisionHandsFree()

    enum Mode: String, CaseIterable { case auto, hands, handsfree }

    private let lock = NSLock()
    private var currentMode: Mode
    private var gaze: (origin: SIMD3<Float>, direction: SIMD3<Float>, at: TimeInterval)?
    private var tapUntil: [String: TimeInterval] = [:]   // button -> release time
    private var holding = false          // "hold": the right hand
    private var holdingBoth = false      // "both hold": both hands
    // Spoken movement: the left stick (walk, strafe) and the right stick's x
    // (turn), each held until its time runs out or "stop".
    private var moveStick = SIMD2<Float>(0, 1)
    private var moveUntil: TimeInterval = 0
    private var turnX: Float = 0
    private var turnUntil: TimeInterval = 0
    private var lastWasTurn = false
    private var heardAt: TimeInterval = 0
    private var exitAskedAt: TimeInterval?
    /// How long "exit title" waits for "confirm": the spoken question takes
    /// about 2 s (and is not listened to), then 5 s to answer.
    private let exitWindow: TimeInterval = 7

    /// How long a select's gaze ray keeps aiming the pointer.
    private let gazeHold: TimeInterval = 0.6
    /// How long a spoken tap holds its button down.
    private let voicePress: TimeInterval = 0.25
    /// How long a spoken move holds the left stick (MV_VOICE_MOVE).
    private let moveFor: TimeInterval = MetavisionHandsFree.seconds("MV_VOICE_MOVE", default: 1.5)
    /// How long a spoken turn holds the right stick: a flick, which is what
    /// snap turning reacts to (MV_VOICE_TURN).
    private let turnFor: TimeInterval = MetavisionHandsFree.seconds("MV_VOICE_TURN", default: 0.25)

    private static func seconds(_ name: String, default def: TimeInterval) -> TimeInterval {
        guard let v = env(name), let d = TimeInterval(v), d > 0, d.isFinite else { return def }
        return d
    }

    private static let defaultsKey = "metavision.inputMode"

    /// The mode the app starts in: MV_INPUT_MODE, else the remembered choice, else auto.
    static var startupMode: Mode {
        if let v = env("MV_INPUT_MODE"), let m = Mode(rawValue: v.lowercased().replacingOccurrences(of: "-", with: "")) { return m }
        if !envOn("MV_HANDS_FREE", default: true) { return .hands }
        if let v = UserDefaults.standard.string(forKey: defaultsKey), let m = Mode(rawValue: v) { return m }
        return .auto
    }

    private init() {
        currentMode = Self.startupMode
        applyVoice()
        NSLog("[mv] input mode %@", currentMode.rawValue)
    }

    var mode: Mode {
        lock.lock(); defer { lock.unlock() }
        return currentMode
    }

    /// Change the mode now and remember it (launcher picker, voice); auto-play's
    /// mode cycle changes it without remembering.
    func setMode(_ m: Mode, remember: Bool = true) {
        lock.lock(); currentMode = m; lock.unlock()
        if remember { Self.remember(m) }
        applyVoice()
        NSLog("[mv] input mode -> %@", m.rawValue)
    }

    /// For the launcher, before any title (and so before `shared`) exists.
    static func remember(_ m: Mode) { UserDefaults.standard.set(m.rawValue, forKey: defaultsKey) }

    /// Hands-free branches may supply controllers (auto and handsfree).
    var enabled: Bool { mode != .hands }
    /// Tracked hands are not used at all (handsfree).
    var ignoresHands: Bool { mode == .handsfree }

    private func applyVoice() {
        if mode != .hands && Self.envOn("MV_VOICE", default: true) {
            MetavisionVoice.shared.start { [weak self] cmd in self?.voice(cmd) }
        } else {
            MetavisionVoice.shared.stop()
        }
    }

    /// Read by KleptonAudio (via the overlay) before it configures the session.
    static var voiceWanted: Bool { startupMode != .hands && envOn("MV_VOICE", default: true) }

    static func env(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name] ?? getenv(name).map { String(cString: $0) }
    }

    static func envOn(_ name: String, default def: Bool) -> Bool {
        guard let v = env(name) else { return def }
        return !(v == "0" || v.lowercased() == "false" || v.lowercased() == "off")
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// From KleptonControllers.handleSpatialEvents: every select carries the
    /// direction the user was looking.
    func noteSelection(origin: SIMD3<Float>, direction: SIMD3<Float>) {
        guard simd_length(direction) > 0.001 else { return }
        lock.lock()
        gaze = (origin, simd_normalize(direction), now())
        lock.unlock()
    }

    /// A system select (Dwell Control, Voice Control, a pinch) in the last
    /// quarter second: every select reports its gaze ray (noteSelection).
    /// Auto-play reports a look every frame, so it never counts as one there.
    var systemSelect: Bool {
        guard !MetavisionAutoplay.enabled else { return false }
        lock.lock(); defer { lock.unlock() }
        return gaze.map { now() - $0.at < 0.25 } ?? false
    }

    /// The hands-free pointer was last asked for (KleptonControllers, every
    /// frame it supplies the pointer): the compositor draws the reticle while
    /// this is recent.
    nonisolated(unsafe) static var pointerAt: TimeInterval = 0
    static var pointerInUse: Bool { ProcessInfo.processInfo.systemUptime - pointerAt < 0.25 }

    /// A command as if spoken (MetavisionAutoplay's hands-free script).
    func inject(_ cmd: MetavisionVoice.Command) { voice(cmd) }

    private func voice(_ cmd: MetavisionVoice.Command) {
        lock.lock()
        let t = now()
        heardAt = t
        // While "exit title" waits for its answer, "confirm" or "yes" leaves
        // and "back" or "cancel" stays; neither presses a button.
        let asking = exitAskedAt.map { t - $0 < exitWindow } ?? false
        if asking && (cmd == .confirm || cmd == .yes || cmd == .back) {
            exitAskedAt = nil
            lock.unlock()
            if cmd == .back {
                NSLog("[mv] voice: exit called off — staying")
                MetavisionVoice.shared.cue(.cancelled)
            } else {
                leave()
            }
            return
        }
        switch cmd {
        case .select:   tapUntil["trigger"] = t + voicePress
        case .grab:     tapUntil["grip"] = t + voicePress
        case .confirm:  tapUntil["a"] = t + voicePress
        case .back:     tapUntil["b"] = t + voicePress
        case .yes:      break
        case .siri:     break
        case .exitTitle: exitAskedAt = t
        case .menu:     tapUntil["menu"] = t + voicePress
        case .hold:     holding = true
        case .bothHold: holdingBoth = true
        case .release:  holding = false; holdingBoth = false
        case .recenter: KleptonCompositor.pendingRecenter = true
        case .leftSelect: tapUntil["ltrigger"] = t + voicePress
        case .leftGrab:   tapUntil["lgrip"] = t + voicePress
        case .buttonX:    tapUntil["x"] = t + voicePress
        case .buttonY:    tapUntil["y"] = t + voicePress
        case .moveForward: move(SIMD2(0, 1), t)
        case .moveBack:    move(SIMD2(0, -1), t)
        case .strafeLeft:  move(SIMD2(-1, 0), t)
        case .strafeRight: move(SIMD2(1, 0), t)
        case .turnLeft:    turn(-1, t)
        case .turnRight:   turn(1, t)
        case .keepGoing:
            // The last move (or turn) again, held until "stop"; forward when
            // nothing has moved yet (moveStick starts forward).
            if lastWasTurn && turnX != 0 { turnUntil = .infinity } else { moveUntil = .infinity }
        case .stop:     moveUntil = 0; turnUntil = 0
        case .modeAuto, .modeHands, .modeHandsFree: break
        }
        lock.unlock()
        NSLog("[mv] voice: %@", "\(cmd)")
        switch cmd {
        case .modeAuto:      setMode(.auto)
        case .modeHands:     setMode(.hands)
        case .modeHandsFree: setMode(.handsfree)
        case .siri:          MetavisionVoice.shared.releaseForSiri()
        case .exitTitle:
            MetavisionVoice.shared.cue(.ask)
            MetavisionVoice.shared.prompt("Leave this title? Say confirm.")
            let asked = t
            DispatchQueue.main.asyncAfter(deadline: .now() + exitWindow + 0.1) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let stillAsking = self.exitAskedAt == asked
                if stillAsking { self.exitAskedAt = nil }
                self.lock.unlock()
                if stillAsking {
                    NSLog("[mv] voice: exit not confirmed within %.0f s — staying", self.exitWindow)
                    MetavisionVoice.shared.cue(.cancelled)
                }
            }
        case .yes:           break
        default:             MetavisionVoice.shared.cue(.heard)
        }
    }

    /// When the last command was heard (the reticle flashes).
    var lastHeard: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return heardAt
    }

    /// Whether "exit title" is waiting for its answer.
    var exitAsked: Bool {
        lock.lock(); defer { lock.unlock() }
        return exitAskedAt.map { now() - $0 < exitWindow + 0.2 } ?? false
    }

    /// Leave the title: the app ends, as when it is sent to the background
    /// (KleptonApp's Lifecycle: every launch is the first). A process boots
    /// one title, so the launcher comes back when the app is opened again —
    /// "Siri, open metavision", which works once this app no longer holds
    /// the microphone. Auto-play never leaves (it only tests the question).
    private func leave() {
        if MetavisionAutoplay.enabled {
            NSLog("[mv] voice: exit confirmed — auto-play run, so not leaving")
            return
        }
        NSLog("[mv] voice: exit confirmed — leaving the title")
        MetavisionVoice.shared.stopNow()
        fflush(nil)
        exit(0)
    }

    // Called with the lock held.
    private func move(_ v: SIMD2<Float>, _ t: TimeInterval) { moveStick = v; moveUntil = t + moveFor; lastWasTurn = false }
    private func turn(_ x: Float, _ t: TimeInterval) { turnX = x; turnUntil = t + turnFor; lastWasTurn = true }

    /// What voice is pressing on one controller right now.
    struct Pressed {
        var buttons: UInt32 = 0; var trigger = false; var grip = false
        var stick = SIMD2<Float>(0, 0)
    }

    func pressed(hand: Int) -> Pressed {
        lock.lock(); defer { lock.unlock() }
        let t = now()
        func down(_ k: String) -> Bool { (tapUntil[k] ?? 0) > t }
        var p = Pressed()
        if hand == 1 {
            p.trigger = down("trigger") || holding || holdingBoth
            p.grip = down("grip") || holding || holdingBoth
            if p.trigger { p.buttons |= OVRPRawButton.rIndexTrigger }
            if p.grip { p.buttons |= OVRPRawButton.rHandTrigger }
            if down("a") { p.buttons |= OVRPRawButton.a }
            if down("b") { p.buttons |= OVRPRawButton.b }
            if turnUntil > t {
                p.stick = SIMD2(turnX, 0)
                p.buttons |= turnX < 0 ? OVRPRawButton.rThumbstickLeft : OVRPRawButton.rThumbstickRight
            }
        } else {
            p.trigger = down("ltrigger") || holdingBoth
            p.grip = down("lgrip") || holdingBoth
            if p.trigger { p.buttons |= OVRPRawButton.lIndexTrigger }
            if p.grip { p.buttons |= OVRPRawButton.lHandTrigger }
            if down("x") { p.buttons |= OVRPRawButton.x }
            if down("y") { p.buttons |= OVRPRawButton.y }
            if down("menu") { p.buttons |= OVRPRawButton.start }
            if moveUntil > t {
                // The analog stick, and the direction bits OVRPlugin titles
                // also read (a Sense controller's stick sets both).
                p.stick = moveStick
                if moveStick.y > 0.5 { p.buttons |= OVRPRawButton.lThumbstickUp }
                if moveStick.y < -0.5 { p.buttons |= OVRPRawButton.lThumbstickDown }
                if moveStick.x < -0.5 { p.buttons |= OVRPRawButton.lThumbstickLeft }
                if moveStick.x > 0.5 { p.buttons |= OVRPRawButton.lThumbstickRight }
            }
        }
        return p
    }

    /// The left controller's pose: the pointer's mirror image, below and left
    /// of the head, aimed along the head's forward direction (never the gaze:
    /// that aims the right). Nil when there is no head pose yet.
    func leftPose() -> (SIMD3<Float>, simd_quatf)? {
        guard let h = headPose() else { return nil }
        let (head, headQ) = h
        let position = head + headQ.act(SIMD3<Float>(-0.12, -0.20, -0.15))
        let q = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: headQ.act(SIMD3<Float>(0, 0, -1)))
        return (position, q)
    }

    /// Where the pointer ray and the reticle meet, metres along the head ray.
    static let pointerDepth: Float = 2.0

    private func headPose() -> (SIMD3<Float>, simd_quatf)? {
        var px: Float = 0, py: Float = 0, pz: Float = 0
        var qx: Float = 0, qy: Float = 0, qz: Float = 0, qw: Float = 1
        kl_ovrp_get_head_pose(&px, &py, &pz, &qx, &qy, &qz, &qw)
        let headQ = simd_quatf(ix: qx, iy: qy, iz: qz, r: qw)
        if !(headQ.real.isFinite) { return nil }
        return (SIMD3<Float>(px, py, pz), headQ)
    }

    /// The pointer controller's pose in the tracking space kl_ovrp uses for the
    /// head, or nil when there is no head pose yet.
    func pointerPose() -> (SIMD3<Float>, simd_quatf)? {
        guard let h = headPose() else { return nil }
        let (head, headQ) = h
        Self.pointerAt = now()

        // Just below the eyes on the head's centre line, out of view: the ray
        // then runs (nearly) along the line of sight, so it lands where the
        // user faces — where the reticle is drawn. It used to start 12 cm
        // right and 20 cm down and run PARALLEL to the head ray, landing
        // about 23 cm below and right of whatever was faced, at any distance.
        let position = head + headQ.act(SIMD3<Float>(0, -0.08, -0.02))

        // Aim at the point faced, `pointerDepth` out: exact there, and within
        // a few centimetres from 1 to 4 m.
        var target = head + headQ.act(SIMD3<Float>(0, 0, -1)) * Self.pointerDepth
        lock.lock()
        if let g = gaze, now() - g.at < gazeHold {
            // The point the user looked at with a system select.
            target = g.origin + g.direction * Self.pointerDepth
        }
        lock.unlock()
        let forward = simd_normalize(target - position)
        let q = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: forward)
        return (position, q)
    }
}

/// Continuous on-device speech recognition for a few command words.
final class MetavisionVoice: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = MetavisionVoice()

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    /// The raw value is what the log says ("[mv] voice: moveForward").
    enum Command: String {
        case select, grab, hold, release, confirm, back, menu, recenter
        case modeAuto, modeHands, modeHandsFree
        // Moving: the left stick walks and strafes, the right stick turns.
        case moveForward, moveBack, strafeLeft, strafeRight, turnLeft, turnRight, keepGoing, stop
        // The left controller, and both hands at once.
        case leftSelect, leftGrab, buttonX, buttonY, bothHold
        // Leaving: "exit title" asks, "confirm" (or "yes") within 5 s leaves.
        // "yes" means nothing else. "Siri" hands the microphone to Siri.
        case exitTitle, yes, siri

        /// The words that say it (what auto-play speaks).
        var phrase: String {
            switch self {
            case .exitTitle:     return "exit title"
            case .modeAuto:      return "auto mode"
            case .modeHands:     return "hands mode"
            case .modeHandsFree: return "hands-free mode"
            case .moveForward:   return "forward"
            case .moveBack:      return "back up"
            case .strafeLeft:    return "left"
            case .strafeRight:   return "right"
            case .turnLeft:      return "turn left"
            case .turnRight:     return "turn right"
            case .keepGoing:     return "keep going"
            case .leftSelect:    return "left select"
            case .leftGrab:      return "left grab"
            case .buttonX:       return "X button"
            case .buttonY:       return "Y button"
            case .bothHold:      return "both hold"
            default:             return rawValue
            }
        }

        /// Made of everyday words ("go", "left", "right", "X"), so it counts
        /// only as a short phrase of its own: preceded by a pause or another
        /// command, and followed by one. Talking does not move the player.
        var standsAlone: Bool {
            switch self {
            case .moveForward, .moveBack, .strafeLeft, .strafeRight, .turnLeft, .turnRight, .keepGoing,
                 .leftSelect, .leftGrab, .buttonX, .buttonY, .bothHold:
                return true
            default:
                return false   // the original words, and "stop": a stray stop is harmless
            }
        }
    }
    /// One word, one command.
    private static let words_: [String: Command] = [
        // "select" and the words a recogniser commonly hears for it, or that
        // people say instead.
        "select": .select, "selects": .select, "click": .select, "clicks": .select,
        "okay": .select, "ok": .select, "o.k": .select, "tap": .select, "press": .select,
        "yes": .yes, "siri": .siri,
        "grab": .grab, "grip": .grab,
        "hold": .hold, "release": .release, "drop": .release,
        "confirm": .confirm, "accept": .confirm,
        "back": .back, "cancel": .back,
        "menu": .menu, "pause": .menu,
        "recenter": .recenter, "re-center": .recenter,
        "forward": .moveForward, "forwards": .moveForward, "go": .moveForward, "walk": .moveForward,
        "backward": .moveBack, "backwards": .moveBack, "reverse": .moveBack, "backup": .moveBack,
        "left": .strafeLeft, "right": .strafeRight,
        "stop": .stop, "halt": .stop,
        "x": .buttonX, "x-button": .buttonX, "y": .buttonY, "y-button": .buttonY,
    ]
    /// Two words, one command. Where one of the words is a command alone, the
    /// pair wins ("back up" is not B then nothing).
    private static let pairs: [String: Command] = [
        "left select": .leftSelect, "left trigger": .leftSelect, "left click": .leftSelect,
        "left grab": .leftGrab, "left grip": .leftGrab,
        "turn left": .turnLeft, "turn right": .turnRight,
        "back up": .moveBack, "go back": .moveBack, "move back": .moveBack,
        "step back": .moveBack, "walk back": .moveBack,
        "go forward": .moveForward, "move forward": .moveForward,
        "walk forward": .moveForward, "step forward": .moveForward,
        "go left": .strafeLeft, "move left": .strafeLeft, "step left": .strafeLeft,
        "go right": .strafeRight, "move right": .strafeRight, "step right": .strafeRight,
        "keep going": .keepGoing, "keep moving": .keepGoing,
        "both hold": .bothHold,
        "x button": .buttonX, "ex button": .buttonX, "button x": .buttonX,
        "y button": .buttonY, "why button": .buttonY, "button y": .buttonY,
        "exit title": .exitTitle, "close title": .exitTitle, "leave title": .exitTitle,
        "quit title": .exitTitle, "exit game": .exitTitle, "close game": .exitTitle,
        "quit game": .exitTitle, "go home": .exitTitle, "exit app": .exitTitle,
        "close app": .exitTitle, "quit app": .exitTitle, "exit metavision": .exitTitle,
        "quit metavision": .exitTitle, "close metavision": .exitTitle,
    ]
    /// Every phrase the recogniser should expect (contextual strings, and the
    /// custom language model's phrases).
    static var vocabulary: [String] {
        Array(words_.keys) + Array(pairs.keys) + ["auto mode", "hands mode", "hands-free mode"]
    }
    /// First words of a pair that mean something else alone ("back", "left",
    /// "go"): at the end of what has been heard they wait for the next word,
    /// or a pause, before counting.
    private static let prefixes: Set<String> = Set(pairs.compactMap { (k, c) -> String? in
        let first = String(k.split(separator: " ")[0])
        guard let alone = words_[first], alone != c else { return nil }
        return first
    })
    /// A gap between words this long ends a phrase.
    private static let pauseGap: TimeInterval = 0.4
    /// With nothing new heard for this long, the last word is taken as said.
    private static let settleAfter: TimeInterval = 0.6

    // MARK: state
    //
    // Everything below runs on the main queue, except the microphone tap
    // (the audio thread), which touches only what its locks guard.

    private var onCommand: ((Command) -> Void)?
    private var running = false
    private var authorised = false

    // The engine: a fresh AVAudioEngine on every rebuild. An engine whose
    // configuration changed (another audio unit started, a route or rate
    // change, an interruption) stops itself and its tap goes quiet with no
    // error, so the recogniser waits for audio that never comes. Klepton's own
    // output unit is rebuilt several times while a title starts its sound.
    private var engine: AVAudioEngine?
    private var engineObserver: NSObjectProtocol?
    private var sessionObservers: [NSObjectProtocol] = []
    private var rebuildScheduled = false
    private var rebuilds = 0
    private var recentRebuilds: [TimeInterval] = []
    private var tapFormat: AVAudioFormat?
    private var micDetail = ""
    /// The microphone's input converted to one channel: what the recogniser
    /// gets, and what auto-play's synthetic speech is written into.
    private var monoFormat: AVAudioFormat?

    // The task: a new one after every utterance, a final result, an error or
    // 50 s, so transcripts stay short and a revised transcription never hides
    // a later command. The tap appends to whichever request is current.
    private let reqLock = NSLock()
    private var liveRequest: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var taskID = 0
    private var taskStarted: TimeInterval = 0
    private var lastResultAt: TimeInterval = 0
    private var errorsInARow = 0
    private var languageModel: SFSpeechLanguageModel.Configuration?   // once prepared
    private var offSince: TimeInterval = 0   // the engine has been torn down since

    // The current task's transcription and where its phrases break.
    private var heard = 0              // commands already acted on in this task
    private var lastWords: [String] = []
    private var lastBreaks: [Bool] = []
    private var settledAt: Set<Int> = []   // word indices a settle put a pause before
    private var pending = false
    private var generation = 0
    private var lastText = ""

    // Health, for the log: written by the tap, read by the watchdog.
    private let statLock = NSLock()
    private var buffers = 0
    private var buffersAtReport = 0
    private var peak: Float = 0
    private var lastBufferAt: TimeInterval = 0
    private var transcripts = 0
    private var restarts = 0
    private var errors = 0
    private var commandsHeard = 0
    private var lastHealth: TimeInterval = 0
    private var watchdog: Timer?
    /// Lines of transcripts, task restarts and errors written so far; after
    /// `logCap` only every 25th is (MV_VOICE_LOG=<n> to change the cap).
    private var logged = 0
    private let logCap = Int(MetavisionHandsFree.env("MV_VOICE_LOG") ?? "") ?? 400

    // Our own speech. Auto-play's synthesised samples replace the
    // microphone's (the feed); a prompt is spoken aloud, and what is heard
    // while it plays is ignored so it cannot answer itself; auto-play's
    // loudspeaker test is spoken aloud and heard by the real microphone.
    private let synth = AVSpeechSynthesizer()
    private let feedLock = NSLock()
    private var feed: [Float] = []
    private var converter: AVAudioConverter?
    private let promptSynth = AVSpeechSynthesizer()
    private let aloudSynth = AVSpeechSynthesizer()
    private var mutedUntil: TimeInterval = 0
    private var cuePlayer: AVAudioPlayer?

    // Siri: while this app records, visionOS does not listen for "Siri".
    // Hearing the word, the microphone is let go for MV_SIRI_PAUSE seconds.
    private var releasedForSiri = false
    private let siriPause = TimeInterval(MetavisionHandsFree.env("MV_SIRI_PAUSE") ?? "") ?? 20

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// A capped diagnostic line: the first `logCap` freely, then every 25th.
    private func note(_ s: String) {
        logged += 1
        if logged <= logCap || logged % 25 == 0 { NSLog("[mv] voice: %@", s) }
    }

    /// Words, in order, to commands: single command words, two-word phrases,
    /// and "<x> mode" phrases. `breakBefore[i]` marks a pause before word i.
    /// `settled`: nothing more follows the last word (a final result, or a
    /// pause after it). Unsettled, a last phrase that could still grow into a
    /// pair, or that must stand alone, is not counted yet: `pending` is then
    /// true, and the caller asks again once it settles.
    static func commands(in words: [String], breakBefore: [Bool] = [],
                         settled: Bool = true) -> (commands: [Command], pending: Bool) {
        var out: [Command] = []
        func brk(_ k: Int) -> Bool { k == 0 || (k < breakBefore.count && breakBefore[k]) }
        func pair(_ k: Int) -> Command? {
            k + 1 < words.count && !brk(k + 1) ? pairs[words[k] + " " + words[k + 1]] : nil
        }
        func startsCommand(_ k: Int) -> Bool {
            guard k < words.count else { return false }
            let w = words[k]
            return words_[w] != nil || pair(k) != nil || w == "mode"
                || (k + 1 < words.count && words[k + 1] == "mode")
                || (k + 2 < words.count && words[k + 2] == "mode")
        }
        var i = 0
        var afterCommand = false   // the word before i ended a command
        while i < words.count {
            let w = words[i]
            if w == "mode" {
                let p1 = i > 0 ? words[i - 1] : "", p2 = i > 1 ? words[i - 2] : ""
                var c: Command?
                if p1 == "hands-free" || p1 == "handsfree" || (p1 == "free" && (p2 == "hands" || p2 == "hand")) {
                    c = .modeHandsFree
                } else if p1 == "hands" || p1 == "hand" {
                    c = .modeHands
                } else if p1 == "auto" || p1 == "automatic" {
                    c = .modeAuto
                }
                if let c { out.append(c) }
                afterCommand = c != nil
                i += 1
                continue
            }
            let c: Command, n: Int
            if let p = pair(i) { c = p; n = 2 }
            else if let s = words_[w] { c = s; n = 1 }
            else { afterCommand = false; i += 1; continue }
            let end = i + n
            if end == words.count && !settled && (c.standsAlone || (n == 1 && prefixes.contains(w))) {
                return (out, true)
            }
            if c.standsAlone && !((brk(i) || afterCommand) && (end == words.count || brk(end) || startsCommand(end))) {
                afterCommand = false; i += 1; continue
            }
            out.append(c)
            afterCommand = true
            i = end
        }
        return (out, false)
    }

    private override init() {
        super.init()
        promptSynth.delegate = self
    }

    // MARK: acting on what was heard

    /// Act on the commands in the latest transcription beyond those already
    /// acted on; when the last phrase is pending, look again once it settles.
    private func act(settled: Bool) {
        let (cmds, isPending) = Self.commands(in: lastWords, breakBefore: lastBreaks, settled: settled)
        while heard < cmds.count {
            commandsHeard += 1
            onCommand?(cmds[heard])
            heard += 1
        }
        pending = isPending
        generation += 1
        guard isPending else { return }
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleAfter) { [weak self] in
            guard let self, self.running, self.generation == g else { return }
            // Nothing new was heard: a pause follows the last word, for good.
            self.settledAt.insert(self.lastWords.count)
            self.act(settled: true)
        }
    }

    /// One recognition result of the current task.
    private func handle(_ result: SFSpeechRecognitionResult) {
        lastResultAt = now()
        errorsInARow = 0
        let text = result.bestTranscription.formattedString
        if text != lastText || result.isFinal {
            lastText = text
            transcripts += 1
            let shown = text.count > 120 ? "..." + String(text.suffix(117)) : text
            let muted = now() < mutedUntil
            note("heard \"\(shown)\"\(result.isFinal ? " (final)" : "")\(muted ? " (our own prompt: ignored)" : "") [task \(taskID)]")
        }
        if now() < mutedUntil { return }
        // Partial results re-deliver the whole utterance each time, so act
        // only on commands beyond the ones already handled.
        let trim = CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "-."))
        let edge = CharacterSet.punctuationCharacters
        var words: [String] = [], breaks: [Bool] = []
        var lastEnd: TimeInterval = -1
        let timed = result.bestTranscription.segments.contains { $0.timestamp > 0 || $0.duration > 0 }
        for seg in result.bestTranscription.segments {
            // A pause before this segment, where timings are given.
            let gap = timed && lastEnd >= 0 && seg.timestamp - lastEnd > Self.pauseGap
            lastEnd = seg.timestamp + seg.duration
            for (k, part) in seg.substring.lowercased().split(separator: " ").enumerated() {
                var w = part.trimmingCharacters(in: trim)
                // "o.k." keeps its inner dots; a sentence's full stop goes.
                if w != "o.k." && w != "o.k" { w = w.trimmingCharacters(in: edge) } else { w = "o.k" }
                if w.isEmpty { continue }
                breaks.append(k == 0 && gap || settledAt.contains(words.count))
                words.append(w)
            }
        }
        lastWords = words
        lastBreaks = breaks
        act(settled: result.isFinal)
    }

    // MARK: starting and stopping

    /// On the main queue, at once when already there: start and stop keep
    /// the order they were called in (a mode switched off and on again).
    private func onMain(_ f: @escaping () -> Void) {
        if Thread.isMainThread { f() } else { DispatchQueue.main.async(execute: f) }
    }

    func stop() {
        onMain {
            guard self.running else { return }
            self.running = false
            self.watchdog?.invalidate(); self.watchdog = nil
            self.endTask()
            self.teardownEngine()
            NSLog("[mv] voice: stopped")
        }
    }

    /// Let go of the microphone at once (leaving the title).
    func stopNow() {
        running = false
        endTask()
        teardownEngine()
    }

    func start(onCommand: @escaping (Command) -> Void) {
        onMain { self.begin(onCommand) }
    }

    private func begin(_ onCommand: @escaping (Command) -> Void) {
        self.onCommand = onCommand
        guard !running else { return }
        running = true   // before authorisation: a stop() meanwhile is honoured
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                NSLog("[mv] voice: speech recognition not authorised (%d)", status.rawValue)
                return
            }
            // The microphone is a permission of its own. Without it the input
            // delivers silence — buffers keep coming, nothing is ever heard.
            AVAudioApplication.requestRecordPermission { granted in
                NSLog("[mv] voice: microphone permission %@", granted ? "granted" : "DENIED — nothing spoken can be heard (Settings > Privacy > Microphone)")
                DispatchQueue.main.async {
                    guard self.running else { return }
                    self.authorised = true
                    self.observeSession()
                    self.prepareLanguageModel()
                    self.watchdog?.invalidate()   // a start whose stop came first
                    self.watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
                    self.buildEngine(reason: "start")
                }
            }
        }
    }

    /// The microphone: a fresh engine, its input tapped and made mono.
    private func buildEngine(reason: String) {
        rebuildScheduled = false
        guard running, authorised, !releasedForSiri else { return }
        teardownEngine()
        guard let recognizer, recognizer.isAvailable else {
            NSLog("[mv] voice: recogniser unavailable — trying again in 5 s")
            scheduleRebuild("recogniser unavailable", after: 5); return
        }
        let session = AVAudioSession.sharedInstance()
        let e = AVAudioEngine()
        let input = e.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fmt.sampleRate,
                                       channels: 1, interleaved: false) else {
            NSLog("[mv] voice: no microphone input (category %@, input available %@, %.0f Hz %d ch) — trying again in 2 s",
                  session.category.rawValue, session.isInputAvailable ? "yes" : "no", fmt.sampleRate, Int(fmt.channelCount))
            scheduleRebuild("no input", after: 2); return
        }
        monoFormat = mono
        tapFormat = fmt
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            self?.tapped(buf)
        }
        e.prepare()
        do { try e.start() } catch {
            NSLog("[mv] voice: engine did not start: %@ — trying again in 2 s", "\(error)")
            input.removeTap(onBus: 0)
            scheduleRebuild("engine start failed", after: 2); return
        }
        engine = e
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: e, queue: .main) { [weak self] _ in
            self?.scheduleRebuild("audio engine configuration changed (the engine stopped itself)", after: 0.3)
        }
        statLock.lock(); lastBufferAt = now(); statLock.unlock()
        rebuilds += 1
        let route = session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        micDetail = String(format: "%.0f Hz, %d ch %@ -> 1 ch", fmt.sampleRate, Int(fmt.channelCount),
                           fmt.commonFormat == .pcmFormatFloat32 ? "float" : "int")
        NSLog("[mv] voice: microphone #%d (%@): %@, route %@, category %@ mode %@",
              rebuilds, reason, micDetail, route.isEmpty ? "none" : route,
              session.category.rawValue, session.mode.rawValue)
        newTask(reason: reason)
        if rebuilds == 1 { lastHealth = now() - 25 }   // first health line 5 s in
    }

    private func teardownEngine() {
        if let o = engineObserver { NotificationCenter.default.removeObserver(o) }
        engineObserver = nil
        guard let e = engine else { return }
        e.stop()
        e.inputNode.removeTap(onBus: 0)
        engine = nil
        offSince = now()
    }

    private func scheduleRebuild(_ why: String, after: TimeInterval) {
        guard running, !rebuildScheduled else { return }
        rebuildScheduled = true
        // Opening the microphone can itself change the audio configuration
        // (and Klepton then rebuilds its output unit, which changes it again):
        // more than five rebuilds in 30 s wait 10 s, so that never becomes a loop.
        let t = now()
        recentRebuilds = recentRebuilds.filter { t - $0 < 30 } + [t]
        var delay = after
        if recentRebuilds.count > 5 {
            delay = max(after, 10)
            NSLog("[mv] voice: %d microphone rebuilds in 30 s — waiting 10 s", recentRebuilds.count)
        }
        if engine != nil { NSLog("[mv] voice: rebuilding the microphone: %@", why) }
        endTask()
        teardownEngine()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.rebuildScheduled else { return }
            self.buildEngine(reason: why)
        }
    }

    /// A new recognition task on the running engine, the old one dropped.
    private func newTask(reason: String) {
        guard running, let recognizer, engine != nil else { return }
        if pending { act(settled: true) }   // a phrase still waiting counts now
        endTask()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        // Short commands, from a known list.
        req.contextualStrings = Self.vocabulary
        req.addsPunctuation = false
        switch (MetavisionHandsFree.env("MV_VOICE_HINT") ?? "confirmation").lowercased() {
        case "dictation": req.taskHint = .dictation
        case "search": req.taskHint = .search
        case "unspecified", "none": req.taskHint = .unspecified
        default: req.taskHint = .confirmation
        }
        if req.requiresOnDeviceRecognition, let lm = languageModel {
            req.customizedLanguageModel = lm
        }
        taskID += 1
        let id = taskID
        heard = 0
        lastWords = []; lastBreaks = []; settledAt = []; pending = false; generation += 1
        lastText = ""
        taskStarted = now(); lastResultAt = 0
        recognizer.queue = .main   // the result handler and act() share the main queue
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self, id == self.taskID else { return }   // a task already replaced
            if let result { self.handle(result) }
            if let error { self.taskFailed(error) }
            else if result?.isFinal ?? false { self.newTask(reason: "final result") }
        }
        reqLock.lock(); liveRequest = req; reqLock.unlock()
        restarts += 1
        if restarts == 1 {
            NSLog("[mv] voice: listening (on device: %@, hint %@, language model %@)",
                  req.requiresOnDeviceRecognition ? "yes" : "no", "\(req.taskHint.rawValue)",
                  req.customizedLanguageModel != nil ? "custom" : "standard")
        } else {
            note("task \(id) (\(reason))\(req.customizedLanguageModel != nil ? ", custom language model" : "")")
        }
    }

    private func endTask() {
        reqLock.lock(); let r = liveRequest; liveRequest = nil; reqLock.unlock()
        taskID += 1          // its late callbacks are ignored
        r?.endAudio()
        task?.cancel()
        task = nil
    }

    private func taskFailed(_ error: Error) {
        let e = error as NSError
        errors += 1
        errorsInARow += 1
        // 1110: no speech in a while; 216/301: cancelled. Neither is a fault.
        let quiet = e.code == 1110 || e.code == 216 || e.code == 301
        note("task \(taskID) ended: \(e.domain) \(e.code)\(quiet ? "" : " \(e.localizedDescription)")")
        let delay = quiet ? 0.05 : min(10, 0.3 * pow(2, Double(min(errorsInARow, 6))))
        let id = taskID
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running, self.taskID == id else { return }
            if self.engine == nil { return }   // a rebuild is on its way and starts a task
            self.newTask(reason: "after \(e.domain) \(e.code)")
        }
    }

    /// Once a second: is the microphone still delivering, is an utterance
    /// over (a new task then), and the health line every 30 s.
    private func tick() {
        guard running, authorised else { return }
        let t = now()
        statLock.lock(); let since = t - lastBufferAt; statLock.unlock()
        if engine != nil && since > 3 && !releasedForSiri {
            scheduleRebuild(String(format: "no microphone audio for %.0f s", since), after: 0.3)
            return
        }
        // Off for a while (an interruption whose end never came): try again.
        if engine == nil && !rebuildScheduled && !releasedForSiri && offSince > 0 && t - offSince > 10 {
            offSince = t
            scheduleRebuild("the microphone has been off for 10 s", after: 0.1)
            return
        }
        if task != nil && !pending && lastResultAt > 0 && t - lastResultAt > 1.2 {
            newTask(reason: "utterance over")
        } else if task != nil && t - taskStarted > 50 && (lastResultAt == 0 || t - lastResultAt > 0.8) {
            newTask(reason: "50 s")
        }
        if t - lastHealth >= 30 { health() }
    }

    private func health() {
        let t = now()
        let dt = max(0.001, t - lastHealth)
        lastHealth = t
        statLock.lock()
        let n = buffers - buffersAtReport, p = peak
        buffersAtReport = buffers; peak = 0
        statLock.unlock()
        let db = p > 0 ? 20 * log10(Double(p)) : -120
        NSLog("[mv] voice: health — microphone %@ %@, %.0f buffers/s, peak %.0f dBFS%@; %d transcript(s), %d command(s), %d task(s), %d error(s), %d rebuild(s)%@",
              engine == nil ? "OFF" : "on", micDetail, Double(n) / dt, db,
              engine != nil && n > 0 && p == 0 ? " (DIGITAL SILENCE: no permission, or the input is muted)" : "",
              transcripts, commandsHeard, restarts, errors, rebuilds,
              releasedForSiri ? ", let go for Siri" : "")
    }

    // MARK: the microphone tap (audio thread)

    private func tapped(_ buf: AVAudioPCMBuffer) {
        guard let mono = monoFormat, buf.frameLength > 0,
              let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buf.frameLength),
              let dst = out.floatChannelData?[0] else { return }
        let n = Int(buf.frameLength), st = buf.stride
        out.frameLength = buf.frameLength
        // Channel 0 only: the headset's microphones arrive already beamformed
        // towards the wearer's mouth, and summing channels can cancel.
        if let src = buf.floatChannelData {
            for i in 0..<n { dst[i] = src[0][i * st] }
        } else if let src = buf.int16ChannelData {
            for i in 0..<n { dst[i] = Float(src[0][i * st]) / 32768 }
        } else if let src = buf.int32ChannelData {
            for i in 0..<n { dst[i] = Float(src[0][i * st]) / 2147483648 }
        } else { return }
        var p: Float = 0
        for i in 0..<n { p = max(p, abs(dst[i])) }
        statLock.lock()
        buffers += 1; peak = max(peak, p); lastBufferAt = ProcessInfo.processInfo.systemUptime
        statLock.unlock()
        overwrite(dst, n)
        reqLock.lock(); let r = liveRequest; reqLock.unlock()
        r?.append(out)
    }

    /// Replace a microphone buffer with queued synthetic speech, if any.
    private func overwrite(_ dst: UnsafeMutablePointer<Float>, _ n: Int) {
        feedLock.lock(); defer { feedLock.unlock() }
        guard !feed.isEmpty else { return }
        let k = min(n, feed.count)
        for i in 0..<n { dst[i] = i < k ? feed[i] : 0 }
        feed.removeFirst(k)
    }

    // MARK: the session: interruptions, routes, resets

    private func observeSession() {
        guard sessionObservers.isEmpty else { return }
        let nc = NotificationCenter.default
        let s = AVAudioSession.sharedInstance()
        sessionObservers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: s, queue: .main) { [weak self] n in
            guard let self else { return }
            let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            if AVAudioSession.InterruptionType(rawValue: raw) == .began {
                NSLog("[mv] voice: audio interrupted (Siri, a call, another app) — listening paused")
                self.endTask(); self.teardownEngine()
            } else {
                // KleptonAudio reactivates the session on the same notification;
                // build after it has.
                self.scheduleRebuild("interruption ended", after: 0.5)
            }
        })
        sessionObservers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: s, queue: .main) { [weak self] n in
            guard let self, !self.releasedForSiri else { return }
            let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            switch AVAudioSession.RouteChangeReason(rawValue: raw) {
            case .newDeviceAvailable, .oldDeviceUnavailable, .categoryChange, .override, .routeConfigurationChange:
                // Reopen only when the change reached the microphone: the
                // engine stopped, or its input now has another format.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard self.running, self.authorised, !self.releasedForSiri else { return }
                    if let e = self.engine, e.isRunning, e.inputNode.outputFormat(forBus: 0) == self.tapFormat {
                        self.note("audio route changed (reason \(raw)); the microphone is unaffected")
                    } else if self.engine != nil {
                        self.scheduleRebuild("audio route changed (reason \(raw))", after: 0.1)
                    }
                }
            default: break
            }
        })
        sessionObservers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: s, queue: .main) { [weak self] _ in
            self?.engine = nil   // every audio object is invalid; do not touch it
            self?.scheduleRebuild("media services were reset", after: 1)
        })
        // Back from Siri, Control Center or a system alert.
        sessionObservers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.running, self.authorised, self.engine == nil, !self.releasedForSiri else { return }
            self.scheduleRebuild("app active again", after: 0.3)
        })
    }

    // MARK: Siri

    /// visionOS does not listen for "Siri" while an app records. Hearing the
    /// word, let the microphone go (session back to playback only, as when
    /// voice is off), so saying "Siri" again reaches Siri; take it back after
    /// MV_SIRI_PAUSE seconds (20).
    func releaseForSiri() {
        guard running, !releasedForSiri else { return }
        if KleptonMic.shared.settings.enabled {
            NSLog("[mv] voice: heard \"Siri\", but the title itself uses the microphone — not let go")
            return
        }
        releasedForSiri = true
        endTask(); teardownEngine()
        cue(.release)
        let s = AVAudioSession.sharedInstance()
        do { try s.setCategory(.playback, mode: .default) } catch {
            NSLog("[mv] voice: could not let go of the microphone: %@", "\(error)")
        }
        NSLog("[mv] voice: heard \"Siri\" — microphone let go for %.0f s; say \"Siri\" again now", siriPause)
        DispatchQueue.main.asyncAfter(deadline: .now() + siriPause) { [weak self] in
            guard let self, self.releasedForSiri else { return }
            self.releasedForSiri = false
            do {
                try KleptonAudio.setCategoryForMic(s, true)
                try s.setActive(true)
            } catch {
                NSLog("[mv] voice: could not take the microphone back: %@", "\(error)")
            }
            NSLog("[mv] voice: microphone taken back after Siri")
            self.scheduleRebuild("back from Siri", after: 0.5)
        }
    }

    // MARK: feedback

    enum Cue { case heard, ask, cancelled, release }

    /// A short sound: a tick when a command is heard, a rising pair for a
    /// question, a falling pair when something is called off or let go.
    func cue(_ c: Cue) {
        guard MetavisionHandsFree.envOn("MV_VOICE_CUE", default: true) else { return }
        let tones: [(Double, Double)]   // (Hz, seconds)
        switch c {
        case .heard:     tones = [(1500, 0.035)]
        case .ask:       tones = [(660, 0.09), (990, 0.12)]
        case .cancelled: tones = [(880, 0.08), (587, 0.12)]
        case .release:   tones = [(784, 0.08), (523, 0.08), (392, 0.12)]
        }
        DispatchQueue.main.async {
            guard let p = try? AVAudioPlayer(data: Self.wav(tones)) else { return }
            p.volume = 0.6
            p.play()
            self.cuePlayer = p   // kept alive until the next cue
        }
    }

    /// 16-bit mono PCM WAV of the tones, each with a quick fade in and out.
    private static func wav(_ tones: [(Double, Double)]) -> Data {
        let rate = 44100.0
        var pcm: [Int16] = []
        for (hz, len) in tones {
            let n = Int(rate * len)
            for i in 0..<n {
                let t = Double(i) / rate
                let env = min(1, Double(i) / 220) * min(1, Double(n - i) / 660)
                pcm.append(Int16(sin(2 * .pi * hz * t) * env * 0.5 * 32767))
            }
        }
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(pcm.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in pcm { u16(UInt16(bitPattern: s)) }
        return d
    }

    /// Speak to the user. What the microphone hears meanwhile (the prompt
    /// itself) is ignored, so a prompt can name the word that answers it.
    func prompt(_ text: String) {
        DispatchQueue.main.async {
            self.mutedUntil = .infinity
            let u = AVSpeechUtterance(string: text)
            u.voice = AVSpeechSynthesisVoice(language: "en-US")
            self.promptSynth.speak(u)
        }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { promptOver() }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { promptOver() }

    private func promptOver() {
        // Still muted for 0.6 s (the loudspeaker's tail), then a new task
        // clean of the prompt's words, and only then listening again: the old
        // task's transcript holds "confirm" and must never be acted on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.newTask(reason: "after our prompt")
            self.mutedUntil = 0
        }
    }

    // MARK: the custom language model

    /// On-device recognition can take a language model built for these
    /// phrases; short words like "select" are heard far more reliably. Built
    /// once, in the background; tasks use it from the next one on.
    /// MV_VOICE_LM=0 keeps the standard model.
    private func prepareLanguageModel() {
        guard MetavisionHandsFree.envOn("MV_VOICE_LM", default: true),
              recognizer?.supportsOnDeviceRecognition ?? false else { return }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("metavision-voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let asset = dir.appendingPathComponent("commands.bin")
        let lm = dir.appendingPathComponent("commands.lm")
        let vocab = dir.appendingPathComponent("commands.vocab")
        let phrases = Self.vocabulary
        // The phrases, weighted: "select" most of all.
        let data = SFCustomLanguageModelData(locale: Locale(identifier: "en_US"),
                                             identifier: "metavision.voice.commands", version: "2")
        for p in phrases {
            let w = p == "select" ? 400 : ["click", "okay", "confirm", "exit title", "back", "grab", "release"].contains(p) ? 100 : 40
            data.insert(phraseCount: SFCustomLanguageModelData.PhraseCount(phrase: p, count: w))
        }
        Task {
            do {
                try await data.export(to: asset)
            } catch {
                NSLog("[mv] voice: custom language model not built (%@) — standard model", "\(error)")
                return
            }
            let config = SFSpeechLanguageModel.Configuration(languageModel: lm, vocabulary: vocab)
            SFSpeechLanguageModel.prepareCustomLanguageModel(for: asset, configuration: config) { error in
                DispatchQueue.main.async {
                    if let error {
                        NSLog("[mv] voice: custom language model not available (%@) — standard model", "\(error)")
                        return
                    }
                    self.languageModel = config
                    NSLog("[mv] voice: custom language model ready (%d phrases); used from the next task", phrases.count)
                }
            }
        }
    }

    // MARK: auto-play's speech

    /// Speak `text` into the recogniser in place of the microphone (auto-play):
    /// the words go through the same tap, mono conversion, request and
    /// recogniser as a voice. False when nothing is listening, so the caller
    /// can hand commands over.
    func say(_ text: String) -> Bool {
        guard running, engine != nil, let mono = monoFormat else { return false }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        synth.write(u) { [weak self] buffer in
            guard let self, let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return }
            if self.converter?.inputFormat != pcm.format {
                self.converter = AVAudioConverter(from: pcm.format, to: mono)
            }
            guard let conv = self.converter else { return }
            let cap = AVAudioFrameCount(Double(pcm.frameLength) * mono.sampleRate / pcm.format.sampleRate) + 256
            guard let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: cap) else { return }
            var given = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, status in
                if given { status.pointee = .noDataNow; return nil }
                given = true; status.pointee = .haveData; return pcm
            }
            guard err == nil, let ch = out.floatChannelData else { return }
            let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
            self.feedLock.lock(); self.feed += samples; self.feedLock.unlock()
        }
        return true
    }

    /// Speak `text` out loud through the loudspeaker (auto-play's microphone
    /// test): the real microphone hears it, the whole path a user's voice
    /// takes. False when nothing is listening.
    func sayAloud(_ text: String) -> Bool {
        guard running, engine != nil else { return false }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        u.volume = 1
        DispatchQueue.main.async { self.aloudSynth.speak(u) }
        return true
    }

    /// Whether a prompt is being spoken (auto-play holds its own speech).
    var prompting: Bool { now() < mutedUntil }
}
