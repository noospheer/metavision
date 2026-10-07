// MetavisionHandsFree.swift — play with eyes and voice, no hands.
//
// Copied into Klepton's app by tools/metavision-overlay and wired into
// KleptonControllers.swift by two small patches there.
//
// Klepton builds its synthetic Touch controllers from tracked hands. With no
// hand in view the guest gets no controller pose, so a title's laser points
// nowhere and a select lands on nothing. This supplies the right controller
// whenever no hand (and no Sense controller) is tracking it:
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
//
// Switches (environment or Documents/klepton.env):
//   MV_HANDS_FREE=0   leave Klepton's own behaviour untouched
//   MV_VOICE=0        no speech recognition (no microphone/speech prompts)
import AVFoundation
import Foundation
import Speech
import simd

final class MetavisionHandsFree {
    static let shared = MetavisionHandsFree()

    let enabled: Bool
    private let lock = NSLock()
    private var gaze: (origin: SIMD3<Float>, direction: SIMD3<Float>, at: TimeInterval)?
    private var tapUntil: [String: TimeInterval] = [:]   // button -> release time
    private var holding = false

    /// How long a select's gaze ray keeps aiming the pointer.
    private let gazeHold: TimeInterval = 0.6
    /// How long a spoken tap holds its button down.
    private let voicePress: TimeInterval = 0.25

    private init() {
        enabled = Self.envOn("MV_HANDS_FREE", default: true)
        if enabled && Self.envOn("MV_VOICE", default: true) {
            MetavisionVoice.shared.start { [weak self] cmd in self?.voice(cmd) }
        }
        NSLog("[mv] hands-free %@, voice %@", enabled ? "on" : "off",
              (enabled && Self.envOn("MV_VOICE", default: true)) ? "on" : "off")
    }

    /// Read by KleptonAudio (via the overlay) before it configures the session.
    static var voiceWanted: Bool { envOn("MV_HANDS_FREE", default: true) && envOn("MV_VOICE", default: true) }

    static func envOn(_ name: String, default def: Bool) -> Bool {
        guard let v = ProcessInfo.processInfo.environment[name] ?? getenv(name).map({ String(cString: $0) }) else { return def }
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
        }
        lock.unlock()
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
    enum Command: String { case select, grab, hold, release, confirm, back, menu, recenter }
    private static let words: [String: Command] = [
        "select": .select, "click": .select, "okay": .select, "ok": .select,
        "grab": .grab, "grip": .grab,
        "hold": .hold, "release": .release, "drop": .release,
        "confirm": .confirm, "accept": .confirm,
        "back": .back, "cancel": .back,
        "menu": .menu, "pause": .menu,
        "recenter": .recenter, "re-center": .recenter,
    ]
    private var heard = 0              // commands already acted on in this task
    private var onCommand: ((Command) -> Void)?

    func start(onCommand: @escaping (Command) -> Void) {
        self.onCommand = onCommand
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                NSLog("[mv] voice: speech recognition not authorised (%d)", status.rawValue)
                return
            }
            DispatchQueue.main.async { self.begin() }
        }
    }

    private func begin() {
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
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in
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
                let cmds = result.bestTranscription.segments.compactMap {
                    Self.words[$0.substring.lowercased().trimmingCharacters(in: .punctuationCharacters)]
                }
                while self.heard < cmds.count {
                    self.onCommand?(cmds[self.heard])
                    self.heard += 1
                }
            }
            // Recognition tasks end on their own (silence, time limit); start
            // another so the command words keep working.
            if error != nil || (result?.isFinal ?? false) {
                self.restart()
            }
        }
        NSLog("[mv] voice: listening (on device: %@)", req.requiresOnDeviceRecognition ? "yes" : "no")
    }

    private func restart() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil; request = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.begin() }
    }
}
