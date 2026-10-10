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
| **Meta hand tracking** (`ovrp_GetHandState`, `GetSkeleton2/3`) — Klepton refuses it | hand-driven titles run but nothing responds to hands | the Vision Pro's hand skeleton mapped onto Meta's 24 bones, in Meta's struct layouts (offsets pinned by static asserts): wrist pose, bone rotations, pinch strengths, pointer ray; the rest skeleton is measured from the user's hand. Off in hands-free mode. `ovrp_GetMesh` answers a hand mesh of our own (a tube along every bone of the measured skeleton, skinned to it) — titles that place particles or effects on the hand mesh need one; titles that show Meta's mesh hand draw tube hands | `shims/mv_hands.c`, `klepton-overlay/MetavisionHands.swift` |
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
| MoltenVK faults replaying a secondary command buffer that begins a render pass | Vulkan titles crash in `MVKRenderSubpass::populateMTLRenderPassDescriptor` | Unity's `boot.config` turns secondary command buffers and graphics jobs off (`gfx-enable-gfx-jobs=0`, `gfx-enable-native-gfx-jobs=0`, replacing the title's own value); both asset doors serve the patched copy; not sufficient on its own, since some titles still record secondaries (step 43) | overlay step 24 |
| The microphone's voice processing (VoiceProcessingIO) ducks and processes the app's other output | music crackles once a title opens the mic, speech stays clean | other-audio ducking set to minimum, advanced ducking off | overlay step 25 |
| DoubleWide eye layers (UE4 GLES): registering the wide texture for the right eye re-bound it to array slice 1 | Unreal titles: left eye empty, washed-out picture, black screenshots | the right eye shares the left eye's storage and slice; per-eye viewports crop each half | overlay step 26 |
| `getSystemService` cached each manager unpinned, so the first JNI frame pop freed it | later calls get a dangling object ("GetObjectClass on an untagged pointer"); memory-advice reads zero memory and judges the device critical | managers pinned; `getMemoryClass`, `getLargeMemoryClass`, `isLowRamDevice`, `Debug.getNativeHeap*` answered from the memory budget | overlay step 27 |
| `/proc/<own pid>/…` missed the synthetic tree; no `oom_score` | memory-advice: "Could not open /proc/N/status" | `/proc/<pid>` resolves to `/proc/self`; `oom_score`/`oom_score_adj` read 0 | overlay step 28 |
| Android 11+ `WindowManager.getMaximumWindowMetrics` unanswered once the platform reads 12L; `MidiManager.getDevices` polled every frame unanswered | Unity reads a null window size; tens of thousands of logged misses a run | window metrics return the display bounds as a `Rect`; MIDI returns an empty device list | overlay step 29 |
| (test passes) a pass filled the wearer's view and ears | the headset could not be used while testing | `MV_HIDDEN=1`: no eye, panels or skybox drawn over passthrough, audio output zeroed; capture and measurement unchanged | overlay step 30 |
| Klepton's environment lookups took Darwin's `getenv` lock, and `sem_post` asked for its trace switch on every call — also from a signal handler (the GC's suspend handler) | a title aborts at random: "Trying to recursively lock an os_unfair_lock" when the GC signal lands on a thread already inside `getenv` | lock-free lookups that walk `environ`; `sem_post`/`pthread_kill` read their trace switch once | overlay step 31 |
| `socketpair` was still forwarded raw: the generated libc table comes first and the lookup is first-match, so step 11's entry was never reached | Rust/tokio titles abort at start: the signal pipe's `socketpair` with `SOCK_NONBLOCK`/`SOCK_CLOEXEC` fails with `EPROTONOSUPPORT`, then a panic that cannot unwind | the flag-translating `socketpair` listed ahead of the generated table | overlay step 32 |
| Android 12's `Build.SOC_MANUFACTURER`/`SOC_MODEL` unanswered once the platform reads 12L; any unset `Build` string read null | Unity's render thread faults in `strlen` at start | the Quest 2's SoC (`QTI`, `SM8250`), also as `ro.soc.*` properties; any other unset `Build` string reads `unknown`, as Android's `Build.UNKNOWN` | overlay step 33 |
| `truncate`, `symlink`, `chmod`, `rmdir`, `readlink`, … : the generated table forwards them with the guest's path unmapped, ahead of step 19's mapped entries | AssetBundle caches under `/sdcard` still fail: `Unable to reserve header in the archive file`, `Failed to decompress data for the AssetBundle` | a path-mapped entry for every path-taking forward, listed ahead of the generated table | overlay step 34 |
| Klepton describes **GLES 3.2** while the ANGLE context is ES 3.0, so Unity runs compute that never compiled | GLES Unity 2021+ titles with GPU skinning draw errors or black: `Internal-Skinning … GLSL compilation failed`, tens of thousands of `Kernel at index (N) is invalid`, `GL_INVALID_FRAMEBUFFER_OPERATION` | Unity 2021+ (year read from the libunity build) is told ES 3.0: CPU skinning, ES 3.0 shader variants — 4 of 4 GPU-skinning titles went from errors or black to pass; older Unity keeps 3.2; `KL_GLES_VERSION` still wins | overlay step 35 (on step 17) |
| (diagnostic) a title freezes when it opens the OpenSL ES recorder: the log stops at `[sl] record state -> STOPPED` | every guest thread goes silent, frames stop | each recorder entry point logged on entry with its thread, so the call that never returns is the last line | overlay step 36 |
| Klepton describes OVRPlugin **1.60.0**, and the C# wrapper refuses newer calls (OpenXR action states are 1.95) without reaching native code | `Error getting action name` every frame; the action-state shims are never called | `KL_OVRP_VERSION=<x.y.z>` describes another version (default unchanged; a switch for A/B: a newer version may reach entry points Klepton stops on by name) | overlay step 37 |
| **Application SpaceWarp** titles: `ovrp_GetLayerTextureSpaceWarp` refused, and the eye-layer desc left the motion-vector size at 0x0 | one XR frame, then none: the main loop runs, the picture stays black | the desc reports a motion-vector size (a quarter of the eye); the entry point takes its real seven arguments and hands out per-stage motion-vector colour and depth images from `kl_vulkan_aux_image` (Vulkan only; GL keeps the refusal). Nothing reads the vectors: visionOS reprojects on its own | overlay step 38 |
| (diagnostic) whether per-frame Vulkan render targets are leaked or only backed | a title killed for memory seconds in, allocating a full-size depth target every frame | every large attachment image tracked create→destroy; `[vk-rt]` logs the live count as it grows and which library made the first large depth targets | overlay step 39 |
| AAudio stream attribute getters (usage, content type, capture policy, privacy, spatialization) missing, and Klepton aborts on an unimplemented AAudio entry point | an Unreal title aborted minutes in, reading `AAudioStream_getUsage` | the getters answer Android's defaults | overlay step 40 |
| a guest viewing a never-created image handle as depth got a colour stand-in, and Metal aborted on the depth view | a SpaceWarp Unity title aborted ~400 frames in (`not compatible with texture view pixelFormat Depth32Float_Stencil8`) | depth/stencil views and barriers on wild handles get a stand-in of their own format; the eye-depth request is logged | overlay step 41 |
| `ActivityThread.currentApplication()` unbound, answering null | an avatar SDK built `std::string(nullptr)` from the missing cache directory and faulted in strlen | answers the same Application singleton as `currentActivityThread().getApplication()` | overlay step 42 |
| secondary command buffers replayed while the primary has no render pass open (MoltenVK dereferences a NULL subpass) | Unity titles faulted on their first frame in `MVKRenderSubpass::populateMTLRenderPassDescriptor` | render-pass state tracked per command buffer; such secondaries are dropped and logged (`KL_VK_SEC_GUARD=0` logs only) | overlay step 43 |
| OpenSL ES record states numbered 0/1/2 (Khronos: 1/2/3), so a guest starting its recorder was read as stopping it | a title waiting on its first recorded buffer froze on that frame | Khronos values | overlay step 44 |
| FMOD's Java census (`isBuiltinInputDeviceAvailable`, `isInputSampleRateAvailable`) hard-wired to false after step 22 made a microphone available | Unity 6 titles saw no microphone and threw every frame on `devices[0]` | both answer what step 22's device list answers | overlay step 45 |
| cached JNI answers (device ids, display modes, OBB dirs, intent query, refresh rates) not pinned, so the first popped local frame retired them | Unity's second `InputDevice.getDeviceIds()` got a dead array: "Null parameter detected", no controllers registered | pinned, with what they hold | overlay step 46 |
| hands-only titles (manifest requires `oculus.software.handtracking`) were shown two Touch controllers | their hand visuals and the effects emitted from the hand mesh stayed hidden | the launcher marks them (`MV_HANDS_ONLY`); tracked hands are reported as hands | overlay step 47 |
| (diagnostic) why a per-frame depth target's memory outlives the image | a title killed for memory although its depth images are destroyed | device memory and image views counted on the census line | overlay step 48 |
| guests told of a newer GLES bind buffer targets ANGLE's ES 3.0 context lacks (shader storage, atomic counter, dispatch indirect) | each call raised GL_INVALID_ENUM, reported by Unity as "OPENGL NATIVE PLUG-IN ERROR" hundreds of times | on an ES 3.0 context only the ES 3.0 targets are forwarded; the runtime's own bookkeeping still sees every call | overlay step 49 |
| ANGLE's lexer flushes float literals below FLT_MIN to 0 on Metal (no preserveDenorms); Unity's translator writes integers kept in floats as such literals | a shader loop whose exit value was one restarted forever: GPU lockup, session ended | in GLSL ES 3.00+ each such literal becomes `intBitsToFloat(<bits>)` | overlay step 50 |
| a title's process footprint ran from 0.6 GB to the 8 GB limit inside one two-second heartbeat | the kill left no line showing what grew (step 51, which destroyed a render target's leftover views, was withdrawn: freed view handles were reused by the guest's next views and then destroyed twice) | a footprint sampler runs from process start and prints each 256 MiB of climb with its time; the Vulkan census line carries the footprint | overlay step 55 |
| (test) scripted input aims at what the screen shows, so menu buttons at the edge of view were pressed only by luck | menus (a language choice, a start button) never left | the managed probe presses the active, interactable Unity UI Buttons, Toggles and Dropdowns directly, least-pressed first, skipping quit/exit/back, data-wiping (clear/erase/remove), external-page, store and debug controls and keyboard keys, matched as whole words ("Back", "BackButton", not "Background") (`MV_AUTOPLAY_UI`) | overlay step 52 |
| `getSystemService("midi")` answered null | a title polling it threw a NullReferenceException every frame | a MidiManager with no devices | overlay step 53 |
| a wake written to the emulated eventfd (a datagram socket) failed with ENOBUFS once its queue filled | a Rust I/O reactor panicked: "failed to wake I/O driver" | an 8-byte write that fails on one of these sockets is taken as written | overlay step 54 |
| a guest's Java classes (its own logger, a plugin's Java half) do not run, so their String arguments vanished | a title's whole log, and the reason it quit, were invisible | in permissive mode an unimplemented call prints its String arguments (600 lines a run) | overlay step 56 |
| `fcntl` file locks refused (struct flock is laid out differently) | SQLite reported a disk I/O error on every open; a title waited forever on its database | F_GETLK/F_SETLK/F_SETLKW (and the OFD forms) translated between the Linux and Darwin layouts and lock types | overlay step 57 |
| the NDK media extractor exposed only a file's video track | a title's videos played without their soundtrack | the first AAC track is a second extractor track (interleaved by timestamp) and `audio/mp4a-latm` decodes through AudioConverter to 16-bit PCM (`MV_VIDEO_AUDIO=0` off) | overlay step 58 |
| hand state carried ARKit joint orientations, and the synthetic hand identity ones; Meta's Interaction SDK rebuilds joints from Meta's own bind skeleton rotated by those bone rotations | no pinch, real or scripted, ever reached a title's gesture gate; hands-only titles never drew | Meta's bind skeleton is the skeleton and mesh from the start; each bone's rotation is solved from measured joint positions (hand frame aligned, scaled, swing per bone, tips placed); `HandScale` carries the measured size (`MV_HAND_SOLVE=0`: bones at rest on the wrist, to tell a solver problem from a title's) | shims/mv_hands.c |
| the real-hand publish ran after autoplay's in the same frame | scripted hands flickered to untracked | the real hands are not published while autoplay drives them | overlay step 59 |
| (diagnostic) why a gesture gate stays shut | — | the input probe reports camera position, named joint positions and distances, and each Interaction SDK Hand's valid/confidence flags (`KL_PROBE_JOINTS`); its joint-name strings are made at each lookup (kept in a static, they were collected and a later `GameObject.Find` read freed memory); the test runner turns the probe on for hands-only titles | overlay step 60, `tools/metavision-device` |
| the input probe read `KL_PROBE_INPUT` and ignored it | every Unity title ran the probe (managed calls, class constructors, scene searches every 120 frames) unasked | it runs only when asked; its axis-name strings are made at the call | overlay step 62 |
| (diagnostic) whether a title sees its GPU work finish | a title that pools render targets made a new one every frame and never destroyed its views | `KL_TRACE_VK_LIFE=1`: once a second, submits, fence waits and status results, timeline-semaphore signals/reads/waits, idle waits, large images and views made/destroyed/live, views whose image was destroyed first (when, and whether, each is destroyed, and by which library), footprint; on in test passes | overlay step 63 |
| a title's `Application.Quit` made `nativeRender` answer false, which Android's UnityPlayer answers with `finish()`; the false was ignored | the title froze on its last frame; one whose watchdog checks that the quit happened crashed itself on purpose seconds later | after 30 false answers in a row the app logs `[guest] the title quit` and exits with status 0 (`KL_EXIT_ON_QUIT=0` off); triage reports **quit** with the scripted input just before it | overlay step 61 |
| (test) autoplay pressed Menu at 12 s | a title answering Menu with a quit ended before the rest of its input was tried | Menu (controller and voice) from about 30 s in | `klepton-overlay/MetavisionAutoplay.swift` |
| GLES compute and storage buffers (ES 3.1) on the ES 3.0 context | compute shaders come back as shader 0 ("no infolog"); std430 blocks do not compile; GPU skinning, compute effects and instanced particles are missing | known limitation: triage notes it and does not count it as an error | — |
| (diagnostic) release builds carry no managed stack traces, so an exception logged every frame named nothing | a title threw a NullReferenceException every frame with no trace | Unity's dlsym of `il2cpp_runtime_invoke` gets a wrapper that logs `[mv-throw] Class.Method threw Type` once per distinct pair (`MV_LOG_THROWS=0` off) | shims/mv_shims.c |
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
  Metal backend, which is GLES 3.0: no compute shaders. Unity 2021+ is now told
  ES 3.0 (overlay step 35) and falls back cleanly (CPU skinning, ES 3.0
  variants); effects that need compute — VFX Graph particles, compute effects —
  are still missing. Unity 2018/2019 keep ES 3.2 (they need 3.x features), so
  their compute still fails (`GLSL compilation failed`, `Kernel at index (N) is
  invalid`; triage lists both). Unity 2022.3 GLES builds get 3.0 by the same
  rule but no test pass has compared them yet. Titles that ship Vulkan run on
  MoltenVK, which has compute. The full fix is GLES 3.1 compute in the GL path.
- **Squashed picture** in at least one title: frames render, the
  view looks compressed. Under test: foveated rendering (`KL_VRR=0`), then a
  unified eye frustum (`KL_OVRP_UNIFY_FRUSTUM=1`).
- **`GL_INVALID_FRAMEBUFFER_OPERATION` once a frame** in GLES Unity titles,
  reported by Unity's native-plugin GL check, on the eye-texture framebuffer.
  Gone in the Unity 2021+ titles tested with ES 3.0 (step 35); for the rest, a
  run with `KL_GLFB_ERRSCAN=0x506 KL_TRACE_FBO=1` names the call.
- **Passthrough** is refused (`XR_FB_passthrough` absent, OVRPlugin's
  `InitializeInsightPassthrough` unsupported). Mixed-reality titles that expect
  it draw their few objects on black. The fix is a compositor feature: show the
  room behind a transparent passthrough layer.
- **Media.** A VideoPlayer clip with sound plays silent: Klepton's
  `AMediaExtractor` exposes only the video track and `AMediaCodec` has no audio
  decoder. Unity's VideoPlayer renders through a `SurfaceTexture`, which Klepton
  does not have (a flat video app waits forever: `AndroidVideoMedia surface creation
  stalled`), and MediaCodec in byte-buffer mode returns no output. The AVPro
  video plugin's Java player (`com/RenderHeads/AVProVideo`) is unbound, so it
  cannot create its player; it needs a binding over Klepton's video decoder.
  All are media work in Klepton's `kl_mediandk.c` and its Java media classes.
- **The OpenSL ES recorder freeze**: in titles that open the recorder from
  their main thread, every guest thread stops at `[sl] record state ->
  STOPPED`. Under diagnosis with step 36's call log.
- **A GPU hang** in one title: the GPU firmware reports a lockup, Compositor
  Services invalidates the layer renderer and the render loop ends. The hung
  work is most likely ANGLE's Metal work for the title's GL frame. Next: a run
  with Metal shader validation to find the draw.
- **A depth buffer allocated every frame** in one Vulkan Unity title (about 100
  in 1.5 s, where others make 3 to 6): memory climbs by gigabytes in a second
  and the process is killed for memory with no crash report. Why Unity
  reallocates is not established; next, a count of live attachment images and
  the memory each is bound to.
- **Hand tracking in OpenXR titles.** metavision's hands reach titles through
  OVRPlugin; Klepton's OpenXR runtime offers no `XR_EXT_hand_tracking`.
- **An OpenXR title exits on its own about 5 s in**, after its first frames,
  with no crash report. Not memory: the memory answers are right since step 27
  and no jetsam report is written. Under investigation.
- **MoltenVK faults on the first frame** in titles that replay a secondary
  command buffer beginning a render pass. Step 24's first option did not stop
  it; graphics jobs are now forced off as well — awaiting a test pass.
- **Dwell Control inside an immersive title** is untested (see ACCESSIBILITY.md).
- Titles whose code is 32-bit only, Flutter, Quill's own engine or Unreal 5 are
  not generated (8 of 54 in the archive).
