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
//   * pose:   right: a pointer just below and right of the head, aimed along
//             the head's forward direction; for a moment after any system
//             select (Dwell Control, Voice Control, a pinch), aimed along the
//             gaze ray visionOS reports with that select instead.
//             left: the mirror image, below and left of the head, aimed along
//             the head's forward direction. Both are published as tracked, so
//             titles that want two controllers present (OVRPlugin and OpenXR
//             alike) have them
//   * select: the system's select, or the spoken word "select" ("click",
//             "okay"), recognised on device
//   * voice:  the other buttons by name, on device:
//               select | click | okay      tap the right trigger
//               grab | grip                tap the right grip
//               hold ... release | drop    hold trigger + grip until released
//               confirm | accept           tap A
//               back | cancel              tap B
//               menu | pause               tap Menu (left controller)
//               recenter                   recenter the view
//               auto | hands | hands-free mode   switch input mode
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
import AVFoundation
import Foundation
import Speech
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

    /// A command as if spoken (MetavisionAutoplay's hands-free script).
    func inject(_ cmd: MetavisionVoice.Command) { voice(cmd) }

    private func voice(_ cmd: MetavisionVoice.Command) {
        lock.lock()
        let t = now()
        switch cmd {
        case .select:   tapUntil["trigger"] = t + voicePress
        case .grab:     tapUntil["grip"] = t + voicePress
        case .confirm:  tapUntil["a"] = t + voicePress
        case .back:     tapUntil["b"] = t + voicePress
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
        switch cmd {
        case .modeAuto:      setMode(.auto)
        case .modeHands:     setMode(.hands)
        case .modeHandsFree: setMode(.handsfree)
        default: break
        }
        NSLog("[mv] voice: %@", "\(cmd)")
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

        // A held controller sits below and to the right of the eyes.
        let position = head + headQ.act(SIMD3<Float>(0.12, -0.20, -0.15))

        var forward = headQ.act(SIMD3<Float>(0, 0, -1))
        lock.lock()
        if let g = gaze, now() - g.at < gazeHold {
            // Aim from the controller to the point the user looked at, about
            // two metres out along the gaze ray.
            let target = g.origin + g.direction * 2.0
            forward = simd_normalize(target - position)
        }
        lock.unlock()
        let q = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: forward)
        return (position, q)
    }
}

/// Continuous on-device speech recognition for a few command words.
final class MetavisionVoice {
    static let shared = MetavisionVoice()

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// The raw value is what the log says ("[mv] voice: moveForward").
    enum Command: String {
        case select, grab, hold, release, confirm, back, menu, recenter
        case modeAuto, modeHands, modeHandsFree
        // Moving: the left stick walks and strafes, the right stick turns.
        case moveForward, moveBack, strafeLeft, strafeRight, turnLeft, turnRight, keepGoing, stop
        // The left controller, and both hands at once.
        case leftSelect, leftGrab, buttonX, buttonY, bothHold

        /// The words that say it (what auto-play speaks).
        var phrase: String {
            switch self {
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
        "select": .select, "click": .select, "okay": .select, "ok": .select,
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
    ]
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

    private var heard = 0              // commands already acted on in this task
    // The latest transcription and where its phrases break; touched on the
    // main queue only (the recogniser's queue and the settle timer).
    private var lastWords: [String] = []
    private var lastBreaks: [Bool] = []
    private var settledAt: Set<Int> = []   // word indices a settle put a pause before
    private var generation = 0
    // Auto-play's speech: synthesised samples that replace the microphone's.
    private let synth = AVSpeechSynthesizer()
    private let feedLock = NSLock()
    private var feed: [Float] = []
    private var tapFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var onCommand: ((Command) -> Void)?
    private var running = false

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

    /// Act on the commands in the latest transcription beyond those already
    /// acted on; when the last phrase is pending, look again once it settles.
    private func act(settled: Bool) {
        let (cmds, pending) = Self.commands(in: lastWords, breakBefore: lastBreaks, settled: settled)
        while heard < cmds.count {
            onCommand?(cmds[heard])
            heard += 1
        }
        generation += 1
        guard pending else { return }
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleAfter) { [weak self] in
            guard let self, self.running, self.generation == g else { return }
            // Nothing new was heard: a pause follows the last word, for good.
            self.settledAt.insert(self.lastWords.count)
            self.act(settled: true)
        }
    }

    func stop() {
        DispatchQueue.main.async {
            guard self.running else { return }
            self.running = false
            self.engine.stop()
            self.engine.inputNode.removeTap(onBus: 0)
            self.request?.endAudio()
            self.task?.cancel()
            self.task = nil; self.request = nil
            NSLog("[mv] voice: stopped")
        }
    }

    func start(onCommand: @escaping (Command) -> Void) {
        self.onCommand = onCommand
        guard !running else { return }
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                NSLog("[mv] voice: speech recognition not authorised (%d)", status.rawValue)
                return
            }
            DispatchQueue.main.async { self.begin() }
        }
    }

    private func begin() {
        running = true
        guard let recognizer, recognizer.isAvailable else {
            NSLog("[mv] voice: recogniser unavailable"); return
        }
        // The audio session is Klepton's (KleptonAudio.swift): the overlay makes it
        // choose .playAndRecord when voice is wanted, exactly as for its own
        // microphone toggle, so nothing here reconfigures it under the guest's audio.
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        heard = 0
        lastWords = []; lastBreaks = []; settledAt = []; generation += 1
        recognizer.queue = .main   // the result handler and act() share the main queue

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        tapFormat = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buf, _ in
            self?.overwrite(buf)
            req.append(buf)
        }
        engine.prepare()
        do { try engine.start() } catch {
            NSLog("[mv] voice: engine: %@", "\(error)"); return
        }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                // Partial results re-deliver the whole utterance each time, so act
                // only on commands beyond the ones already handled.
                let trim = CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "-"))
                var words: [String] = [], breaks: [Bool] = []
                var lastEnd: TimeInterval = -1
                let timed = result.bestTranscription.segments.contains { $0.timestamp > 0 || $0.duration > 0 }
                for seg in result.bestTranscription.segments {
                    // A pause before this segment, where timings are given.
                    let gap = timed && lastEnd >= 0 && seg.timestamp - lastEnd > Self.pauseGap
                    lastEnd = seg.timestamp + seg.duration
                    for (k, part) in seg.substring.lowercased().split(separator: " ").enumerated() {
                        let w = part.trimmingCharacters(in: trim)
                        if w.isEmpty { continue }
                        breaks.append(k == 0 && gap || self.settledAt.contains(words.count))
                        words.append(w)
                    }
                }
                self.lastWords = words
                self.lastBreaks = breaks
                self.act(settled: result.isFinal)
            }
            // Recognition tasks end on their own (silence, time limit); start
            // another so the command words keep working.
            if self.running && (error != nil || (result?.isFinal ?? false)) {
                self.restart()
            }
        }
        NSLog("[mv] voice: listening (on device: %@)", req.requiresOnDeviceRecognition ? "yes" : "no")
    }

    /// Speak `text` into the recogniser in place of the microphone (auto-play):
    /// the words go through the same tap, request and recogniser as a voice.
    /// False when nothing is listening, so the caller can hand commands over.
    func say(_ text: String) -> Bool {
        guard running, let fmt = tapFormat, fmt.commonFormat == .pcmFormatFloat32,
              let mono = AVAudioFormat(standardFormatWithSampleRate: fmt.sampleRate, channels: 1) else { return false }
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

    /// Replace a microphone buffer with queued synthetic speech, if any.
    private func overwrite(_ buf: AVAudioPCMBuffer) {
        feedLock.lock(); defer { feedLock.unlock() }
        guard !feed.isEmpty, let ch = buf.floatChannelData else { return }
        let n = Int(buf.frameLength), k = min(n, feed.count)
        let chans = Int(buf.format.channelCount), st = buf.stride
        for i in 0..<n {
            let v: Float = i < k ? feed[i] : 0
            if buf.format.isInterleaved {
                for c in 0..<chans { ch[0][i * st + c] = v }
            } else {
                for c in 0..<chans { ch[c][i] = v }
            }
        }
        feed.removeFirst(k)
    }

    private func restart() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil; request = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if self.running { self.begin() } }
    }
}
