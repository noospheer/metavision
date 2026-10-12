# Accessibility: playing without hands

Quest titles assume two hand controllers. On a Vision Pro, metavision lets
them be played with **eyes, head and voice alone** — no hand movement at all —
and it does this once, in the runtime every title shares, so every title gets
it without being changed.

This matters most for people who cannot use their hands.

## Input modes

| Mode | What controls a title | For |
|---|---|---|
| **Auto** (default) | Your hands when one is in view; hands-free when none is | most people |
| **Hands** | Hands and PS VR2 Sense controllers only; no microphone | people who play with their hands |
| **Hands-free** | Always hands-free — **tracked hands are ignored** | involuntary movement, tremor or spasticity, where a hand the headset sees would otherwise take control or click by accident |

Choose the mode in the **launcher** (the *Input* control above the library —
remembered between sessions), **by voice** inside a title ("auto mode",
"hands mode", "hands-free mode"), or from a computer with
`MV_INPUT_MODE=auto|hands|handsfree` (see [Turning parts off](#turning-parts-off)).
Hands mode stops speech recognition, so switch back from it in the launcher.

A PS VR2 Sense controller, when paired, is used in every mode: holding one is
deliberate.

## How hands-free works

In hands-free (and in Auto whenever no hand is in view), metavision supplies
both controllers. The right one is the pointer; the left one is held just
below and left of your head, facing where you face, so titles that want two
controllers present have them:

- **Pointing.** The right controller is aimed by your **head**: its ray runs
  from just below your eyes to the point 2 m straight ahead of your face, and
  metavision draws a small **white dot** there (the *reticle*) so you can see
  where a select will land. When you make a system select, it snaps to
  **where you were looking** — visionOS reports the gaze direction with every
  select, and only then (apps never see continuous eye position).
- **Selecting.** The right trigger is pressed by any system select —
  **Dwell Control** (hold your gaze), **Voice Control**, or a pinch — or by
  saying **"select"** (or "click", "okay", "tap", "press"). When metavision
  hears a command it plays a short **tick** and the dot **flashes green**, so
  you know you were heard.
- **Everything else, by voice.** Apple's speech recognition turns speech into
  words — on the headset whenever it supports the language (English does),
  over Apple's servers only if it cannot — and metavision maps a fixed set of
  words to controller buttons. The title itself never hears audio:

| Say | Does |
|---|---|
| select / click / okay / tap / press | tap the right trigger |
| grab / grip | tap the right grip |
| hold … release / drop | hold trigger and grip until released (dragging, carrying) |
| confirm / accept | tap A |
| back / cancel | tap B |
| menu / pause | tap Menu (left controller) |
| recenter | recenter the view, like holding the Meta button on a Quest |
| auto mode / hands mode / hands-free mode | switch input mode |
| exit title / close title / go home / quit metavision | ask to leave the title: say **confirm** (or **yes**) within 5 seconds of the question to leave; **back** or silence stays |
| Siri | let go of the microphone for 20 seconds so Siri can hear you: say "Siri" again, then your request |
| **Left hand** | |
| left select / left trigger / left click | tap the left trigger |
| left grab / left grip | tap the left grip |
| X button (or X) | tap X |
| Y button (or Y) | tap Y |
| both hold … release / drop | hold trigger and grip on both hands until released (two-handed lifting) |
| **Moving** | |
| forward / go / walk | walk forward (left stick) |
| back up / backward / reverse / go back | walk backward |
| left / right (or step left / step right) | step sideways |
| turn left / turn right | turn: a quick flick of the right stick, as snap turning expects |
| keep going / keep moving | keep doing the last move (or turn) until you say "stop" |
| stop / halt | stop moving |

A move lasts 1.5 seconds and a turn is a 0.25-second flick, then the stick
lets go by itself; say it again to go further, or "keep going" to keep moving
until "stop". You can turn while walking.

**Words that sound alike are settled by the longer phrase:**

- "back" alone is the B button; "back up" (or "backward", "reverse", "go
  back") walks backward. After "back", metavision waits about half a second
  to hear whether "up" follows.
- "left" alone steps left; "left select", "left grab" and the like are the
  left controller. "turn left" turns.
- "hold" holds the right hand; "both hold" holds both. "release" lets go of
  everything held.
- "stop" stops moving; it does not let go of anything held ("release" does).
- Y on its own is often heard as "why": say "Y button".

**Moving and left-hand commands must be said as a short phrase of their
own** — after a pause or another command, and followed by a pause or another
command — so ordinary talk ("I want to go there", "that's right") does not
move you. They count about half a second after you finish saying them.

## Leaving a title, and Siri

Leaving a title normally takes the Digital Crown. Hands-free, say **"exit
title"** (or "close title", "go home", "quit metavision"). metavision plays a
rising tone and asks *"Leave this title? Say confirm."*; say **"confirm"** (or
**"yes"**) within 5 seconds after the question and the title closes. Saying
"back", or nothing, keeps you in it (a falling tone). The question itself is
not listened to, so it cannot answer itself.

A metavision app runs one title per launch, so leaving closes the app. Open it
again for the library: **"Siri, open metavision"**.

**Siri while a title runs.** visionOS does not listen for "Siri" while an app
is using the microphone, and hands-free voice uses it the whole time. So
metavision listens for the word itself: when it hears **"Siri"** it lets go of
the microphone for 20 seconds (a falling three-note tone) — say **"Siri"
again** and Siri answers. Voice commands come back on their own afterwards. If
a title uses the microphone itself (voice chat), metavision cannot let go of
it; use "exit title" instead. *Whether visionOS then hears "Siri" without the
app being closed still needs checking on the headset; "exit title" always
works.*

## Setting it up

1. Turn on visionOS accessibility features hands-free: say **"Siri, turn on
   Voice Control"** or **"Siri, turn on Dwell Control"** (Settings →
   Accessibility has both, plus Pointer Control for a head- or eye-driven
   pointer in the rest of visionOS).
2. The first launch of a metavision app asks for **speech recognition** and
   **microphone** permission; allow both (look at *Allow* and dwell, or say
   "tap Allow").
3. In the metavision launcher, Voice Control works directly: "show numbers",
   then "tap 3" to open a title.

Fitting the headset and charging still need another person; everything after
that does not.

## Turning parts off

From the Linux machine, for a title's app (add `--launcher` for the launcher):

```bash
sudo tools/metavision-device env mv_<title> MV_INPUT_MODE=handsfree   # start in a mode
sudo tools/metavision-device env mv_<title> MV_VOICE=0               # no speech recognition
sudo tools/metavision-device env mv_<title> MV_VOICE_MOVE=3         # each spoken move lasts 3 s (1.5)
sudo tools/metavision-device env mv_<title> MV_VOICE_TURN=0.6       # a longer turn, for smooth turning (0.25)
sudo tools/metavision-device env mv_<title> MV_RETICLE=0            # no pointer dot
sudo tools/metavision-device env mv_<title> MV_VOICE_CUE=0          # no tick when a command is heard
sudo tools/metavision-device env mv_<title> MV_VOICE_LM=0           # the standard speech model, not the one built for the commands
sudo tools/metavision-device env mv_<title> MV_VOICE_HINT=dictation  # recogniser hint: confirmation (default), search, dictation, unspecified
sudo tools/metavision-device env mv_<title> MV_SIRI_PAUSE=40        # how long "Siri" frees the microphone (20 s)
sudo tools/metavision-device env mv_<title>                           # clear: back to the remembered mode
```

`MV_INPUT_MODE` overrides the mode chosen in the launcher for as long as it is
set. `MV_HANDS_FREE=0`, the older switch, means the same as `MV_INPUT_MODE=hands`.

## What does not work yet

- **Pointing with the left hand.** The left controller faces where your
  head faces; only the right one follows your gaze. A two-handed action that
  needs the hands in different places (a bow, a steering wheel) cannot be
  done.
- **Analog movement.** Moves are full-stick and in four directions; there is
  no "walk slowly" or diagonal.
- **Titles that track real hands** (hand-gesture pieces) get the Vision Pro's
  hand tracking in Auto and Hands modes. In Hands-free mode they see no real
  hands, by design; a title that accepts **only** hands (no controllers) is
  given one stand-in right hand at the head pointer instead, which pinches on
  "select". Titles that read the fingers in detail (gestures, a poke) cannot be
  played this way.
- **Voice Control's numbers and grid** cannot reach inside a title: a Quest
  title draws its menus as pixels in a 3D scene, so visionOS cannot see its
  buttons. Aim with your head and say "select" instead.
- In **Hands-free** mode, a system select made by an involuntary pinch still
  counts as a select; telling a pinch apart from a Dwell Control select needs
  testing on the headset.
- Titles built only on **OpenXR** read the same controller state as OVRPlugin
  titles (both controllers are published as tracked, so OpenXR sees them
  present, with their buttons and sticks), but hands-free play has been
  confirmed on the headset only for OVRPlugin titles (most Unity and Unreal
  titles).

## Next

- A **numbered aiming grid** for targets that are hard to reach with the head:
  say "grid", then a number to jump the pointer there.
- **Auto-start** for linear experiences, so they need no input at all.
- **Per-title phrases** ("start experience") for titles with known menus.

## When voice does not work: reading the log

Every title's log (`Documents/logs/<title>/klepton-boot.log`, pulled with
`metavision-device`) says what the microphone and the recogniser did:

| Line | Means |
|---|---|
| `[mv] voice: microphone permission DENIED` | visionOS Settings → Privacy & Security → Microphone: allow metavision |
| `[mv] voice: microphone #1 (start): 48000 Hz, 1 ch float -> 1 ch, route MicrophoneBuiltIn, ...` | the microphone was opened (again for #2, #3: after an interruption, a route change or the title's own audio starting) |
| `[mv] voice: heard "select" [task 4]` | what the recogniser heard (the first 400, then every 25th) |
| `[mv] voice: select` | a command acted on |
| `[mv] voice: task 5 (utterance over)` | recognition restarted (after each phrase, a final result, an error, or 50 s) |
| `[mv] voice: health — microphone on ..., 47 buffers/s, peak -31 dBFS; ...` | every 30 s: audio is arriving and how loud; `DIGITAL SILENCE` means no permission or a muted input |
| `[mv] voice: rebuilding the microphone: ...` | the microphone stopped (the engine's configuration changed, no audio for 3 s, an interruption) and was reopened |

`tools/metavision-triage` summarises these per title.

Unattended test passes (auto-play) speak the first six hands-free phrases
**out of the headset's loudspeaker**, so the real microphone hears them over
the title's own sound — the path a user's voice takes — and triage reports
them apart ("microphone (loudspeaker) test: 6 said, N heard"); the rest are
fed into the recogniser directly. Each pass also says "exit title" once and
never confirms it: the question must time out and the title stay.

## How it is built

`klepton-overlay/MetavisionHandsFree.swift` is copied into Klepton's app at
build time. Its recogniser opens the microphone with a fresh audio engine,
reopens it whenever the engine stops itself (another audio unit starting, a
route change, an interruption, a media-services reset, or 3 s without audio),
starts a new recognition task after every phrase so a transcript never grows
or is revised under a later command, and gives the recogniser the command
words as contextual strings, the short-command task hint and, on device, a
language model built for them. The overlay draws the reticle in the
compositor (step 181); `tools/metavision-overlay` wires it into `KleptonControllers.swift`
(the merge of hands and Sense controllers into synthetic Touch controllers)
and lets the audio session record when voice is on, the same way Klepton's own
microphone toggle does. Both hands-free controllers are published through the
same call a tracked hand uses (overlay step 125), which is the state OVRPlugin
answers from and OpenXR's `xrSyncActions` and `xrLocateSpace` read, so every
title sees the same two controllers. Nothing in `vendor/klepton` is committed
changed.

## The microphone

Titles that ask for the microphone in their Android manifest (`RECORD_AUDIO`)
get it — visionOS asks once — and other titles do not. Hands-free voice
commands use the microphone in every title, independently of this.
