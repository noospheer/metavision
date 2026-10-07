# MetaVision

Quest → Vision Pro title pipeline.

Pull APKs from a Quest you own, triage them for compatibility, relink ARM64 ELF
to Mach-O, and build a signed visionOS launcher that loads them.

**Read [METAVISION.md](METAVISION.md) before running anything.** The pipeline
only makes sense once you understand the constraint it is built around: on
visionOS, executable code cannot be sideloaded, so titles are compiled into the
app and only their assets are syncable.

## Clone

```bash
git clone --recursive https://github.com/<you>/metavision
```

The runtime lives in a submodule. Cloning without `--recursive` leaves
`vendor/klepton` empty and the build fails late and confusingly:

```bash
git submodule update --init    # if you already cloned
```

## Verify

Everything that does not need a Mac:

```bash
make test
```

vrapi suites, manifest schema, tool syntax. CI runs the same thing on Linux and
will not build an `.ipa` unless it passes.

## Run order

If your access to the Quest is time-limited, archive first — extraction is the
only step that needs the headset, and an incomplete pull found afterwards
cannot be redone:

```bash
tools/metavision-archive --list      # what is installed, and how big
tools/metavision-archive --all       # pull everything, verify while attached
tools/metavision-archive --verify    # re-check later, no device needed
tools/metavision-closure --all       # can these titles run at all?
```

`archive` proves the extraction is *complete*; `closure` proves it is *usable* —
every library a title loads resolves, its engine's bootstrap asset is present,
and no dependency is a Quest driver blob that no amount of extracting can
supply. Neither needs a Vision Pro, so both answers are available while the
Quest is still in reach.

```bash
tools/metavision-pull     com.example.vrtitle
tools/metavision-triage   pull/com.example.vrtitle/base.apk > triage/vrtitle.json
tools/metavision-manifest triage/*.json -o build/assets/manifest.json
# relink                  vendor/klepton/tools/klepton_ld   (METAVISION.md, Stage 4)
# build                   GitHub Actions, or local Xcode    (Stage 6)
tools/metavision-sync     com.example.vrtitle vision.local
```

Before trusting VrApi struct layouts, point the extractor at a real
`libvrapi.so` from an APK you pulled:

```bash
tools/metavision-vrapi-abi --lib pull/<pkg>/lib/arm64-v8a/libvrapi.so --root vrapi
```

Until it runs, the runtime prints `ABI DECLARED, NOT VERIFIED` at startup. That
is accurate, not a warning to dismiss — the ABI is declared from public
documentation because Meta's headers are not redistributable.

## What we build, and what upstream provides

`vendor/klepton` (MIT) is ~94k lines and already covers libc, the NDK, JNI,
OVRPlatform, OpenXR and the graphics path. MetaVision adds the four things it
does not have:

1. **The launcher** — a library tree over the relinked catalogue
2. **The pipeline** — pull, triage, manifest, sync
3. **The code/asset split** and its ingest listener
4. **VrApi** — the Quest 1 catalogue, unimplemented upstream

## Layout

| Path | What |
|---|---|
| `METAVISION.md` | The pipeline. Start here. |
| `app/` | visionOS launcher. XcodeGen spec — no `.xcodeproj` in the repo. |
| `vrapi/` | VrApi shim. Policy and frame logic test without a device. |
| `tools/` | `archive`, `closure`, `pull`, `triage`, `manifest`, `sync`, `vrapi-abi` |
| `triage/` | Per-title records → `manifest.json` |
| `design/` | Launcher mockup — hover behaviour encodes each title's gaze model |
| `vendor/klepton/` | Upstream runtime (submodule, MIT) |
| `pull/`, `build/` | Gitignored. Large, and not ours to redistribute. |

## Requirements

- A Quest in Developer Mode, and `adb`
- A Vision Pro in Developer Mode
- An Apple Developer account — the free tier expires provisioning every 7 days
- **No Meta account on the Vision Pro.** It is needed once, to enable Developer
  Mode on the Quest, and never again — see METAVISION.md, *Accounts*
- A Mac **or** a macOS CI runner for `xcodebuild`; everything else runs on Linux

## Scope

Dev-mode, your own device, your own titles. Not distributable: visionOS has no
sideloading, and App Review rejects apps that execute translated code. The
practical consequence is that users build this themselves rather than
installing it — see METAVISION.md.
