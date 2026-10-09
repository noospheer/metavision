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
| OVRPlugin capability questions Klepton does not implement (`ovrp_GetHandTrackingEnabled`, body/face tracking, environment depth, …) | `fatal: guest called unimplemented OVRPlugin entry point …` | answer 18 "is X enabled / supported?" questions with success + **no**, which sends titles down their controller path — `GetHandTrackingEnabled` alone is in **37 titles** | `shims/mv_shims.c` |
| **Meta hand tracking** (`ovrp_GetHandState`, `GetSkeleton2/3`) — Klepton refuses it | hand-driven titles run but nothing responds to hands | the Vision Pro's hand skeleton mapped onto Meta's 24 bones, in Meta's struct layouts (offsets pinned by static asserts): wrist pose, bone rotations, pinch strengths, pointer ray; the rest skeleton is measured from the user's hand. Off in hands-free mode. Meta's hand *mesh* stays refused — titles draw no mesh hand | `shims/mv_hands.c`, `klepton-overlay/MetavisionHands.swift` |
| **Unity's texture-unit cap**: Unity limits units to 32 while Quest shaders bind samplers at 32-35, and refuses those binds | text drawn as boxes, wrong textures; `OpenGL Error: Invalid texture unit!` tens of thousands of times a run | `tools/metavision-unitycaps` measures every bundled libunity (cap field, singleton, Unity's own per-unit cache) from the binary at build time; the runtime raises the cap only where the guard's code bytes match | `tools/metavision-unitycaps`, overlay step 8 |
| **Java exceptions**: Klepton's JNI never has one pending | a call that throws on Android (a missing optional asset, a missing patch OBB) returns null, the title reads through it and crashes (`strlen(NULL)`) or logs a bogus OBB mismatch | a pending throwable per thread; `ExceptionCheck/Occurred/Clear`, `Throw`, `ThrowNew`; missing assets and zips throw `FileNotFoundException` | overlay step 9 |
| `dl_iterate_phdr` reports bare library names | Unity 2018 il2cpp crashes at start (`SIGSEGV` at `0xffffffffffffffff`): it opens its own library by that name and maps the result unchecked | full paths, as Android gives | overlay step 10 |
| `socket()`/`socketpair()` with Linux's `SOCK_NONBLOCK`/`SOCK_CLOEXEC` type bits | Rust/tokio networking (LiveKit, …) panics: `failed to create UnixStream` | strip the bits, apply them with `fcntl` | overlay step 11 |
| `Class.forName(String)`, `System.loadLibrary`, FMOD's `org.fmod.FMOD` | `NullReferenceException` every frame from `FMODUnity.RuntimeUtils`; plugins not loaded; FMOD banks in assets unreadable | bound to Klepton's existing class interning, guest dlopen + `JNI_OnLoad`, and the context's `AssetManager` | overlay steps 12-13 |
| **ELF TLS** (`R_AARCH64_TLSDESC`, relocation 1031) — libraries built for API 29+ | `translated dylib present but failed to load: unhandled relocation type 1031` (Meta Interaction SDK, Meta body tracking, …) | a TLS-descriptor resolver: each thread's own copy of the library's TLS block, from `PT_TLS`, offset from the thread pointer the guest reads | overlay step 14 |
| `libandroid.so` opened by name | `could not load libandroid.so` (Unreal, Unity probes) | a handle whose symbols are Klepton's own NDK functions | `shims/mv_shims.c` |
| Klepton presents **Android 10 (API 29)**; Unity 2022.3 accepts a Vulkan driver from a vendor it does not know (Apple, through MoltenVK) only from API 30 | Vulkan titles fall back to a GLES2 context: `Desired shader compiler platform 5 is not available in shader blob`, missing or broken rendering (every Unity 2022.3 + Oculus XR title) | present Android 12L (API 32), what a Quest on current firmware reports — Java `Build.VERSION`, the `ro.build.version.sdk` property and NativeActivity agree (needed with step 23 for an unknown GPU vendor to pass) | overlay step 15 |
| `Locale.toString()` unbound | `strlen(NULL)` at start | Java's `lang_COUNTRY` form | overlay step 16 |
| semaphore slots: re-`sem_init` of the same `sem_t` burned a slot each time (1024 total) | `Failed to open a semaphore (No space left on device)`, then a crash | the same `sem_t` reuses its slot; 16384 slots | overlay step 18 |
| `statfs` / `truncate` / `symlink` saw the guest's `/sdcard` paths unmapped | `Unable to reserve header in the archive file`, `Failed to decompress data for the AssetBundle` | map them like their siblings | overlay step 19 |
| `GL_EXT_texture_norm16` never advertised | `Failed to create RenderTexture with RGBA16 UNorm` | forwarded when ANGLE offers it | overlay step 20 |
| compute shaders in **Unreal** titles (ANGLE is ES 3.0) | `glLinkProgram FAILED — No compiled shaders` (`FailedComputeProgramLink`), then a crash | a no-op stand-in so the program links; GPU-compute effects are missing | overlay step 21 |
| OpenXR action states (`ovrp_GetActionState*`) an SDK helper defines (stylus profiles) | `Error getting action name` every frame | success + inactive value, as a Quest with no such device answers | `shims/mv_shims.c` |
| Meta XR Audio's plugin: refused by Klepton (it trips visionOS AMFI) | `DllNotFoundException: MetaXRAudioUnity` every frame | a stand-in answering 0 everywhere: audio plays unspatialised | `shims/mv_shims.c` |
| the guest **microphone** was off for every title, and `AudioManager.getDevices` listed no input | a title taking `Microphone.devices[0]` throws every frame; voice features hear nothing | the launcher arms the microphone for titles whose manifest asks for `RECORD_AUDIO` (off for the rest, set on every pick), and the device list shows one built-in mic while it is armed; hands-free voice keeps its input either way | overlay step 22 |
| `ovrp_GetDisplayAdapterId2` answered a pointer to the GPU's LUID; Unity's XR pre-init uses the answer as a `VkPhysicalDevice` and must find it among the devices it enumerated | Unity 2022.3 + Oculus XR titles reject Vulkan before any vendor check and fall back to GLES2 without shaders for it (`shader compiler platform 5 is not available`) | answer no adapter preference (NULL): Unity picks the one GPU by type | overlay step 23 |
| MoltenVK faults replaying a secondary command buffer that begins a render pass | Vulkan titles crash in `MVKRenderSubpass::populateMTLRenderPassDescriptor` | Unity's `boot.config` gains `vulkan-disable-secondary-commandbuffers=1` (both asset doors serve the patched copy) | overlay step 24 |
| The microphone's voice processing (VoiceProcessingIO) ducks and processes the app's other output | music crackles once a title opens the mic, speech stays clean | other-audio ducking set to minimum, advanced ducking off | overlay step 25 |
| DoubleWide eye layers (UE4 GLES): registering the wide texture for the right eye re-bound it to array slice 1 | Unreal titles: left eye empty, washed-out picture, black screenshots | the right eye shares the left eye's storage and slice; per-eye viewports crop each half | overlay step 26 |
| `getSystemService` cached each manager unpinned, so the first JNI frame pop freed it | later calls get a dangling object ("GetObjectClass on an untagged pointer"); memory-advice reads zero memory and judges the device critical | managers pinned; `getMemoryClass`, `getLargeMemoryClass`, `isLowRamDevice`, `Debug.getNativeHeap*` answered from the memory budget | overlay step 27 |
| `/proc/<own pid>/…` missed the synthetic tree; no `oom_score` | memory-advice: "Could not open /proc/N/status" | `/proc/<pid>` resolves to `/proc/self`; `oom_score`/`oom_score_adj` read 0 | overlay step 28 |
| the launcher did not carry **MoltenVK** | every Vulkan title black: `MoltenVK is not vendored` | the launcher build wraps it like ANGLE | `tools/metavision-launcher` |
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

**Many titles in one pass.** The launcher files each run's logs under the
title that wrote them, at the moment the next title is picked. Open each title
in turn (wait ~30 s, close metavision, reopen, pick the next), then:

```bash
sudo tools/metavision-device logs --all    # -> build/logs/<title>/ for every title run
tools/metavision-triage                    # one line each: picture or black, and how it ended
```

**Every title, unattended.** `metavision-device test` opens each title by
itself in each input mode with scripted input, pulls and judges every run, and
`test --failed` re-runs what did not pass — see the unattended test pass in
[SETUP.md](SETUP.md). `uses hand tracking` in the triage notes means the title
read Meta hand state (`[mv-hands]` in its log).

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

- **GPU compute in OpenGL ES titles.** Klepton runs GLES titles on ANGLE's
  Metal backend, which is GLES 3.0: no compute shaders. A GLES-only title that
  uses them — Unity VFX Graph particles, GPU skinning, compute effects — runs
  with those effects missing; its log shows `GLSL compilation failed` and
  `Kernel at index (N) is invalid` (triage lists both). Titles that ship Vulkan
  (their manifest declares `android.hardware.vulkan`) run on MoltenVK, which
  has compute. The fix is GLES 3.1 compute in the GL path.

- **Squashed picture** in at least one title: frames render, the
  view looks compressed. Under test: foveated rendering (`KL_VRR=0`), then a
  unified eye frustum (`KL_OVRP_UNIFY_FRUSTUM=1`).
- **The GLES level Unity is told.** Klepton describes ES 3.2 (ANGLE is 3.0), so
  Unity picks ES 3.1+ shader variants — SSBO instancing (`'std430' : invalid
  layout qualifier`), sampler units equal to explicit locations (units in the
  hundreds: `Invalid texture unit!` even with the cap raised) — and compute.
  `KL_GLES_VERSION=3.0` (overlay step 17) describes 3.0 instead; it is a
  switch until a test pass (`test --env KL_GLES_VERSION=3.0`) shows which
  titles are better for it.
- **`GL_INVALID_FRAMEBUFFER_OPERATION` once a frame** in GLES Unity titles,
  reported by Unity's native-plugin GL check, on the eye-texture framebuffer.
  Next: a run with `KL_GLFB_ERRSCAN=0x506 KL_TRACE_FBO=1` names the call.
- **Video into a texture.** Unity's VideoPlayer renders through a
  `SurfaceTexture`, which Klepton does not have (a flat video app waits
  forever: `AndroidVideoMedia surface creation stalled`), MediaCodec in
  byte-buffer mode (no surface) returns no output, and the AVPro video plugin
  cannot create its player. All are media work in Klepton's `kl_mediandk.c`
  and its Java media classes.
- **Hand tracking in OpenXR titles.** metavision's hands reach titles through
  OVRPlugin; Klepton's OpenXR runtime offers no `XR_EXT_hand_tracking`.
- **Memory growth on the Vulkan path** in at least one title (killed within
  seconds; `test` now keeps the jetsam report and triage names it).
- **Unreal titles** (3 in the archive) are untested past build.
- **Dwell Control inside an immersive title** is untested (see ACCESSIBILITY.md).
- Titles whose code is 32-bit only, Flutter, Quill's own engine or Unreal 5 are
  not generated (8 of 54 in the archive).
