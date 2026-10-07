# Compatibility: what titles need, and how to find out

Klepton runs a Quest title's own code. When a title stops, it is almost always
because it asked for something a Quest has and a Vision Pro does not — a
library of the Quest's OS, an OVRPlugin entry point, an older handshake. This
page lists what metavision supplies on top of Klepton, how to diagnose a title
that will not start, and what is still open.

## What metavision adds (and how many archived titles each one reaches)

| Problem | Symptom | Fix | Where |
|---|---|---|---|
| bionic/NDK functions Klepton lacks | link-time gaps (`metavision-gaps`) | 60 shims: `ptrace`, `android_dlopen_ext`, fortify `*_chk`, pthread barriers, the NativeActivity input queue, … | `shims/mv_shims.c` |
| **Older Oculus XR Plugin** (1.x, Unity 2019.4) takes its display surface through `OculusUnity.initComplete(Surface)`, not `surfaceCreated(Surface)` | black picture: ten OVRPlugin calls, then no `SetupDisplayObjects`, no frames | fall back to `initComplete` (same signature) — **6 titles** | `tools/metavision-overlay`, step 5b |
| **Meta Interaction SDK** loads `libossdk.oculus.so` (Quest OS telemetry) and calls the handler it never got | a few hundred frames, then `SIGSEGV at 0x0` in `TelemetrySender::TelemetrySender` | a stand-in library: every symbol returns a harmless object; nothing is sent — **32 titles** | `shims/mv_shims.c` (dlopen/dlsym wrappers) |
| OVRPlugin capability questions Klepton does not implement (`ovrp_GetHandTrackingEnabled`, body/face tracking, environment depth, …) | `fatal: guest called unimplemented OVRPlugin entry point …` | answer the 19 "is X enabled / supported?" questions with success + **no**, which sends titles down their controller path — `GetHandTrackingEnabled` alone is in **37 titles** | `shims/mv_shims.c` |
| a hand-launched app has no environment, and every Klepton diagnostic is an environment switch | — | `Documents/klepton.env`, read before configure | `tools/metavision-overlay`, `metavision-device env` |

Every other unknown OVRPlugin call still **stops the title by name**, on
purpose: a guessed answer can be worse than a clear stop.
`tools/metavision-gaps --ovrp` lists what titles reference and nothing
implements (299 names today, most of them older API names Unity's C# bindings
declare but rarely call).

## Diagnosing a title

On the headset: open the title, wait ~30 s, close it. Then on Linux:

```bash
sudo tools/metavision-device logs mv_<title> --launcher     # -> build/logs/mv_<title>/
```

`klepton-boot.log` is the runtime's log; `klepton-crash.log` is written only on
a fault (an old one stays until the next fault — check its time). What to look
for:

| Line | Means |
|---|---|
| `N with a picture` (in `[cp] alive:`) | frames reached the display — 0 means black |
| `fatal: guest called unimplemented …` | the entry point to implement next |
| `fault: signal 11 at 0x…, pc <lib>+0x…` | a crash; symbolize the pc against the library's own symbols |
| `no Java_…surfaceCreated export` | an XR plugin handshake the runtime does not know |
| `guest dlopen("…") FAILED` | a library the title expects from the Quest's OS |

Turn on tracing for the next launch (clear it afterwards with no arguments):

```bash
sudo tools/metavision-device env mv_<title> --launcher KL_OVRP_TRACE=all KL_OVRP_VERBOSE=1
```

`KL_OVRP_TRACE=1` shows only frame and display calls; `=all` shows every
OVRPlugin call in order — the step where a title stops is the last one.
`vendor/klepton/DEBUG_ENV_VARS.md` documents the rest.

## Open issues

- **Squashed picture** in at least one title: frames render, the
  view looks compressed. Under test: foveated rendering (`KL_VRR=0`), then a
  unified eye frustum (`KL_OVRP_UNIFY_FRUSTUM=1`).
- **The boot window stays open** beside the immersive scene after a title
  starts. Harmless; the launcher should hide it once a title is drawing.
- **Unreal titles** (3 in the archive) are untested past build.
- **Dwell Control inside an immersive title** is untested (see ACCESSIBILITY.md).
- Titles whose code is 32-bit only, Flutter, Quill's own engine or Unreal 5 are
  not generated (8 of 54 in the archive).
