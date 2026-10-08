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
// the right controller whenever no Sense controller tracks it:
//
//   * pose:   a pointer just below and right of the head, aimed along the
//             head's forward direction; for a moment after any system select
//             (Dwell Control, Voice Control, a pinch), aimed along the gaze
//             ray visionOS reports with that select instead
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
//
// Switches (environment or Documents/klepton.env):
//   MV_INPUT_MODE=auto|hands|handsfree   overrides the remembered mode
//   MV_VOICE=0                           no speech recognition in any mode
//   MV_HANDS_FREE=0                      same as MV_INPUT_MODE=hands (older name)
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
    private var holding = false

    /// How long a select's gaze ray keeps aiming the pointer.
    private let gazeHold: TimeInterval = 0.6
    /// How long a spoken tap holds its button down.
    private let voicePress: TimeInterval = 0.25

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

    /// Change the mode now and remember it (launcher picker, voice).
    func setMode(_ m: Mode) {
        lock.lock(); currentMode = m; lock.unlock()
        Self.remember(m)
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
        switch cmd {
        case .select:   tapUntil["trigger"] = now() + voicePress
        case .grab:     tapUntil["grip"] = now() + voicePress
        case .confirm:  tapUntil["a"] = now() + voicePress
        case .back:     tapUntil["b"] = now() + voicePress
        case .menu:     tapUntil["menu"] = now() + voicePress
        case .hold:     holding = true
        case .release:  holding = false
        case .recenter: KleptonCompositor.pendingRecenter = true
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

    /// What voice is pressing on one controller right now.
    struct Pressed { var buttons: UInt32 = 0; var trigger = false; var grip = false }

    func pressed(hand: Int) -> Pressed {
        lock.lock(); defer { lock.unlock() }
        let t = now()
        func down(_ k: String) -> Bool { (tapUntil[k] ?? 0) > t }
        var p = Pressed()
        if hand == 1 {
            p.trigger = down("trigger") || holding
            p.grip = down("grip") || holding
            if p.trigger { p.buttons |= OVRPRawButton.rIndexTrigger }
            if p.grip { p.buttons |= OVRPRawButton.rHandTrigger }
            if down("a") { p.buttons |= OVRPRawButton.a }
            if down("b") { p.buttons |= OVRPRawButton.b }
        } else {
            if down("menu") { p.buttons |= OVRPRawButton.start }
        }
        return p
    }

    /// The pointer controller's pose in the tracking space kl_ovrp uses for the
    /// head, or nil when there is no head pose yet.
    func pointerPose() -> (SIMD3<Float>, simd_quatf)? {
        var px: Float = 0, py: Float = 0, pz: Float = 0
        var qx: Float = 0, qy: Float = 0, qz: Float = 0, qw: Float = 1
        kl_ovrp_get_head_pose(&px, &py, &pz, &qx, &qy, &qz, &qw)
        let head = SIMD3<Float>(px, py, pz)
        let headQ = simd_quatf(ix: qx, iy: qy, iz: qz, r: qw)
        if !(headQ.real.isFinite) { return nil }

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
    enum Command: String {
        case select, grab, hold, release, confirm, back, menu, recenter
        case modeAuto, modeHands, modeHandsFree
    }
    private static let words_: [String: Command] = [
        "select": .select, "click": .select, "okay": .select, "ok": .select,
        "grab": .grab, "grip": .grab,
        "hold": .hold, "release": .release, "drop": .release,
        "confirm": .confirm, "accept": .confirm,
        "back": .back, "cancel": .back,
        "menu": .menu, "pause": .menu,
        "recenter": .recenter, "re-center": .recenter,
    ]
    private var heard = 0              // commands already acted on in this task
    // Auto-play's speech: synthesised samples that replace the microphone's.
    private let synth = AVSpeechSynthesizer()
    private let feedLock = NSLock()
    private var feed: [Float] = []
    private var tapFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var onCommand: ((Command) -> Void)?
    private var running = false

    /// Words, in order, to commands: single command words, and "<x> mode" phrases.
    static func commands(in words: [String]) -> [Command] {
        var out: [Command] = []
        for (i, w) in words.enumerated() {
            if w == "mode" {
                let p1 = i > 0 ? words[i - 1] : "", p2 = i > 1 ? words[i - 2] : ""
                if p1 == "hands-free" || p1 == "handsfree" || (p1 == "free" && (p2 == "hands" || p2 == "hand")) {
                    out.append(.modeHandsFree)
                } else if p1 == "hands" || p1 == "hand" {
                    out.append(.modeHands)
                } else if p1 == "auto" || p1 == "automatic" {
                    out.append(.modeAuto)
                }
            } else if let c = words_[w] {
                out.append(c)
            }
        }
        return out
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
                let words = result.bestTranscription.segments.map {
                    $0.substring.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "-")))
                }
                let cmds = Self.commands(in: words)
                while self.heard < cmds.count {
                    self.onCommand?(cmds[self.heard])
                    self.heard += 1
                }
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
