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
the right controller:

- **Pointing.** The controller is aimed by your **head**. When you make a
  system select, it snaps to **where you were looking** — visionOS reports the
  gaze direction with every select, and only then (apps never see continuous
  eye position).
- **Selecting.** The trigger is pressed by any system select —
  **Dwell Control** (hold your gaze), **Voice Control**, or a pinch — or by
  saying **"select"**.
- **Everything else, by voice.** Apple's speech recognition turns speech into
  words — on the headset whenever it supports the language (English does),
  over Apple's servers only if it cannot — and metavision maps a fixed set of
  words to controller buttons. The title itself never hears audio:

| Say | Does |
|---|---|
| select / click / okay | tap the right trigger |
| grab / grip | tap the right grip |
| hold … release / drop | hold trigger and grip until released (dragging, carrying) |
| confirm / accept | tap A |
| back / cancel | tap B |
| menu / pause | tap Menu (left controller) |
| recenter | recenter the view, like holding the Meta button on a Quest |
| auto mode / hands mode / hands-free mode | switch input mode |

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
sudo tools/metavision-device env mv_<title>                           # clear: back to the remembered mode
```

`MV_INPUT_MODE` overrides the mode chosen in the launcher for as long as it is
set. `MV_HANDS_FREE=0`, the older switch, means the same as `MV_INPUT_MODE=hands`.

## What does not work yet

- **Moving around with a thumbstick**, and two-handed interactions.
- **Titles that track real hands** (hand-gesture pieces) get the Vision Pro's
  hand tracking in Auto and Hands modes, but see no hands in Hands-free mode,
  by design.
- **Voice Control's numbers and grid** cannot reach inside a title: a Quest
  title draws its menus as pixels in a 3D scene, so visionOS cannot see its
  buttons. Aim with your head and say "select" instead.
- In **Hands-free** mode, a system select made by an involuntary pinch still
  counts as a select; telling a pinch apart from a Dwell Control select needs
  testing on the headset.
- Titles built only on **OpenXR** take controller input through a separate path
  in the runtime; the hands-free pointer is confirmed only for OVRPlugin titles
  (most Unity and Unreal titles).

## Next

- A **numbered aiming grid** for targets that are hard to reach with the head:
  say "grid", then a number to jump the pointer there.
- **Auto-start** for linear experiences, so they need no input at all.
- **Per-title phrases** ("start experience") for titles with known menus.

## How it is built

`klepton-overlay/MetavisionHandsFree.swift` is copied into Klepton's app at
build time; `tools/metavision-overlay` wires it into `KleptonControllers.swift`
(the merge of hands and Sense controllers into synthetic Touch controllers)
and lets the audio session record when voice is on, the same way Klepton's own
microphone toggle does. Nothing in `vendor/klepton` is committed changed.
