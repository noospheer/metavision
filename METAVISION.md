# MetaVision

Quest → Vision Pro title pipeline. Extract, triage, relink, install.

---

## The one rule that shapes everything

**Executable code must be inside the signed app bundle at build time.**

`dlopen()` on a dylib outside the bundle fails AMFI code-signature validation — even when the dylib is correctly signed with your own identity. This is not App Review policy you can argue with; it's the platform security model. iOS and its child platforms (visionOS included) do not load native code that isn't embedded in the app.

The consequence, and the thing to internalize before designing anything else:

| | Where it lives | How it gets there | Changeable without a rebuild? |
|---|---|---|---|
| **Code** (relinked `.framework`s) | Inside the app bundle | Compiled in, signed | **No** |
| **Assets** (metadata, OBB, audio) | `Documents/` container | Sideloaded any time | **Yes** |

So there is no "Vision drive" you drop titles onto. Adding a title means **rebuilding and reinstalling MetaVision**. What *is* drive-like is the asset container — and that's genuinely useful, because assets are 95% of the bytes.

Everything below follows from that split.

---

## Stage 0 — Prerequisites

- **Quest** in Developer Mode (free Meta developer org at developers.meta.com; requires phone or card verification)
- **A Mac with Xcode 15+, or a macOS CI runner.** Only `xcodebuild` needs it;
  extraction, triage, verification and relinking all run on Linux
- **Apple Developer Program**, $99/yr — strongly recommended. The free tier gives 7-day provisioning expiry and a 3-app limit, which means re-signing and reinstalling your whole library weekly.
- `adb` (`brew install android-platform-tools`, or your distro's `android-tools`)
- Vision Pro paired to Xcode (Settings → General → Remote Devices)

Everything in this repo that does not need a Mac is checked by one command:

```bash
make test
```

Scope note: this is for titles you own, on your own hardware, in developer mode. It is not distributable — see [What you can't do](#what-you-cant-do).

---

## Stage 1 — Extract (Quest → your machine)

Quest store apps are **split APKs plus OBB**. Pulling only `base.apk` gets you a title that won't run.

If your time with the Quest is limited, use the archive tool — it pulls
everything and verifies while the device is still attached:

```bash
tools/metavision-archive --list   # what is installed, and how big
tools/metavision-archive --all    # pull and verify every title
```

**Launch each title once on the Quest first.** Titles that download content on
first run keep it in `/sdcard/Android/data/`, and it will not be there if the
game never started.

The manual equivalent, for one title:

```bash
adb devices
adb shell pm list packages -3 | sed 's/^package://'
```

`/data/app/**/base.apk` is world-readable, so no root is needed. Pull every split:

```bash
PKG=com.example.vrtitle
mkdir -p pull/$PKG

# all APK splits (base + arm64 config + asset packs)
adb shell pm path $PKG | tr -d '\r' | sed 's/^package://' | while read -r p; do
  adb pull "$p" "pull/$PKG/"
done

# OBB — frequently multi-GB
adb pull /sdcard/Android/obb/$PKG  pull/$PKG/obb  2>/dev/null
adb pull /sdcard/Android/data/$PKG pull/$PKG/data 2>/dev/null
```

Budget disk. A mid-size library is 40–150 GB before any processing.

---

## Stage 2 — Verify, before the Quest leaves

Extraction is the only step that needs the headset. Everything after it works
from files, so an incomplete archive found later cannot be redone — and both
questions worth asking are answerable now, with no Vision Pro in hand.

```bash
tools/metavision-archive --verify   # is the extraction complete?
tools/metavision-closure  --all     # can these titles run at all?
```

`archive --verify` re-checks splits, digests and OBB against what the device
reported at pull time. A title whose device-side OBB was 3 GB and which pulled
none is an interrupted transfer; afterwards that is indistinguishable from a
title that never had any.

`closure` asks the harder question. A stripped ELF still declares `DT_NEEDED`,
so every library a title loads either resolves inside the APK, comes from the
runtime, or does not exist off-device. That last group — `libgsl.so`,
`vulkan.adreno.so` and the other Adreno blobs — is terminal: the dependency is
a driver, and no amount of extracting supplies it. It also checks that an
IL2CPP title has `global-metadata.dat`, which is read before any managed code
runs, and that OBB archives decompress rather than merely exist.

Neither proves a title *renders*. Both prove it is not missing anything, which
is the only question that stops being answerable once the Quest is gone.

---

## Stage 3 — Triage

Decide whether a title *can* run before spending relink time on it. This stage emits the manifest the launcher reads, and its output maps 1:1 onto the library badges.

```bash
#!/usr/bin/env bash
# metavision-triage <apk> — emits one manifest record
apk="$1"; L=$(unzip -l "$apk")

has() { grep -q "$1" <<<"$L"; }

# --- gate 1: ABI. armeabi-v7a only is terminal. ---
if ! has 'lib/arm64-v8a/'; then echo "ARCH32 — AArch32 not executable on Apple silicon"; exit 1; fi

# --- gate 2: scripting backend ---
if   has 'libil2cpp.so';        then BACKEND=IL2CPP
elif has 'libmonobdwgc-2.0.so'; then BACKEND=MONO
elif has 'libmain.so';          then BACKEND=NATIVE
else                                 BACKEND=UNKNOWN; fi

# --- gate 3: XR runtime → which shim ---
if   has 'libopenxr_loader.so'; then XR=OPENXR
elif has 'libvrapi.so';         then XR=VRAPI
else                                 XR=NONE; fi

# --- gate 4: graphics path → predicts the gaze model ---
unzip -p "$apk" 'lib/arm64-v8a/*.so' 2>/dev/null \
  | strings | grep -q vkCreateInstance && GFX=VULKAN || GFX=GLES

# --- gate 5: JIT canaries ---
JIT=none
for c in luajit libv8 hermes libmono; do has "$c" && JIT="$c"; done
```

**Reading the output:**

| Signal | Meaning | Badge |
|---|---|---|
| `lib/arm64-v8a/` absent | 32-bit only | `ARCH32` — reject |
| `libmonobdwgc-2.0.so` | Mono JIT backend | needs full-AOT, or reject |
| `libvrapi.so` | Quest 1 era | route to VrApi shim |
| `GFX=VULKAN` | framebuffer submit | gaze `NONE` |
| `GFX=GLES` + scene intercept | entity path viable | gaze `PINCH` |
| JIT canary hit | LuaJIT / V8 / Hermes | reject |

Also check `AndroidManifest.xml` for `NativeActivity` / `GameActivity`. A custom Activity class means real Java logic, which the Java-thin runtime won't carry.

---

## Stage 4 — Relink

Per architecture-passing `.so`:

```bash
vendor/klepton/tools/klepton_ld \
  --in  pull/$PKG/lib/arm64-v8a/libil2cpp.so \
  --out build/frameworks/$PKG/libil2cpp.framework \
  --patch-x18 \
  --gles-backend angle --vulkan-backend moltenvk
```

The relinker and the runtime shims come from `vendor/klepton` (MIT). MetaVision
adds the launcher, this pipeline, the code/asset split, and `vrapi/` — the
Quest 1 era, which upstream does not implement.

ELF → Mach-O, `x18` sites rewritten to per-library TLS slots, symbols bound against the shim libs. Then sign with your team identity — unsigned output will not load.

Typical yield: **30–120 MB of frameworks per title.** That is the only part that goes in the bundle.

---

## Stage 5 — Split code from assets

Non-negotiable, for a practical reason: a 20-title bundle with assets embedded is 60 GB+, and installs at that size time out or fail mid-transfer.

```
MetaVision.app/                      ← signed, rebuilt to add titles
└── Frameworks/
    └── com.example.vrtitle/
        ├── libil2cpp.framework
        ├── libunity.framework
        └── libovrplatformloader.framework

Documents/                           ← sideloadable, swap freely
├── manifest.json
└── titles/com.example.vrtitle/
    ├── global-metadata.dat
    ├── data.unity3d
    ├── *.assets / *.resS
    └── obb/
```

Rule of thumb: if it's mapped executable, it's in the bundle. Everything else is data.

---

## Stage 6 — Install the app

```bash
xcodebuild -scheme MetaVision -destination 'platform=visionOS,name=Vision Pro' \
           -allowProvisioningUpdates install
```

Or Xcode → Run. On the paid tier the profile is good for a year; on the free tier, weekly.

---

## Stage 7 — The drive

Three routes into the asset container, in increasing order of usefulness for bulk.

**A. Files app — the closest thing to a real "Vision drive."**

Add to `Info.plist`:

```xml
<key>UIFileSharingEnabled</key><true/>
<key>LSSupportsOpeningDocumentsInPlace</key><true/>
```

The app's `Documents/` now appears in the visionOS **Files** app under *On My Vision Pro*. Drag assets in from iCloud Drive, an SMB share, or a USB-C drive. Good for a title or two by hand.

**B. `devicectl` — scriptable, with a real gotcha.**

```bash
xcrun devicectl device copy to \
  --device <UDID> \
  --domain-type appDataContainer \
  --domain-identifier com.yourteam.metavision \
  --source  ./assets/global-metadata.dat \
  --destination Documents/titles/com.example.vrtitle/global-metadata.dat \
  --user mobile
```

**Recursive directory copy is broken** — it returns `The specified file could not be transferred`. Single files transfer fine. So either loop file-by-file, or `tar` the title and extract on device.

**C. Local HTTP ingest — what you actually want for multi-GB.**

Have MetaVision run a loopback-scoped HTTP endpoint on Wi-Fi while the library screen is open:

```bash
tools/metavision-sync com.example.vrtitle vision.local
```

One file per `PUT /ingest?pkg=&path=`. No tarball: there is no shell on device
to extract one, and a Swift archive extractor is needless when game assets are
few and large.

This is the only route that moves a full library in reasonable time, and it round-trips without touching Xcode or a Mac.

---

## Stage 8 — Load

The launcher reconciles two independent sources at startup:

1. **Compiled-in frameworks** — enumerate `Bundle.main`, discover which titles have code.
2. **`Documents/manifest.json`** — the triage output, plus asset presence checks.

A title is runnable only if **both** are satisfied. That produces a failure mode the current library tree doesn't yet render:

> **`NOASSET`** — code linked in, assets missing from the container.

Worth adding as a status badge. It's the one failure a user can fix themselves without a rebuild, so it should look actionable rather than blocked.

---

## Accounts, and what runs offline

**No Meta account is involved on the Vision Pro.** OVRPlatform is reimplemented
rather than proxied — there are no outbound endpoints and nothing to sign in
to. `ovr_Entitlement_GetIsViewerEntitled` is answered locally, and
`ovr_User_GetLoggedInUser` returns a stable local identity, which is what the
titles that ask actually need.

| | Meta | Apple |
|---|---|---|
| Enable Quest Developer Mode | once, before extraction | — |
| Extract, triage, verify | — | — |
| Build, sign, install | — | Developer account |
| Run titles | **never** | — |

The Meta account matters exactly once, on the Quest side. After the headset
goes, it is out of the picture permanently and the launcher works with no
network at all.

Note what the entitlement stub is and is not. It is not a store bypass: there
is no store here, and no way to obtain a title you do not already have on disk.
It exists because the APKs came off hardware you own, running titles you bought,
and the check they perform cannot be answered without an account we are
deliberately not asking you to have.

### What will not work

Entitlement is answered locally; Meta's backend is not replaced. Anything that
genuinely needs their servers fails, and cannot be made to work:

- Multiplayer and matchmaking
- Leaderboards and achievements
- Cloud saves
- Meta avatars
- In-app purchases

Single-player content runs. The social layer does not, because there is no
authenticated session behind it.

### The account that will actually cost you

Apple's. Free-tier provisioning expires every **7 days**, after which the app
refuses to launch until you rebuild and reinstall. The `Documents/` container
survives a reinstall, so it is a rebuild rather than a re-sync — but weekly.
The $99/yr tier takes it to a year and is the difference between this being
usable and being a chore.

---

## What you can't do

- **Drop an APK on the headset and run it.** Not now, not with an entitlement. AMFI.
- **Add a title without rebuilding and reinstalling.** Code is compile-time, always.
- **Distribute this.** visionOS has no sideloading, and App Review rejects apps that execute downloaded code. Dev-mode, your own device, your own titles.
- **Update titles over the air.** An update is a new relink and a new build.

---

## Suggested layout

```
metavision/
├── pull/          # raw adb output, gitignored
├── triage/        # manifest.json per title
├── build/
│   ├── frameworks/
│   └── assets/
├── vendor/klepton/# upstream runtime (MIT): libc, ndk, jni, ovrp, openxr, gfx
├── vrapi/         # our addition: the Quest 1 era
├── app/           # Xcode project + library UI
└── tools/
    ├── metavision-pull
    ├── metavision-triage
    └── metavision-sync
```

Run order: `pull` → `triage` → `metavision-manifest` → `klepton_ld` → build → `sync`.

Before trusting VrApi struct layouts, point the extractor at a real
`libvrapi.so` from one of the APKs you pulled:

```bash
tools/metavision-vrapi-abi --lib pull/<pkg>/lib/arm64-v8a/libvrapi.so --root vrapi
```

Until that runs, the runtime banner reads `ABI DECLARED, NOT VERIFIED`.
