# Setup: from nothing to a signed build on your Vision Pro, without a Mac

This is the whole path, in order, including every place it is easy to get
stuck. Budget an afternoon the first time; most of it is waiting on Apple and
on the first ANGLE build.

You need: a Linux machine, a Vision Pro, a GitHub account, and a **paid**
Apple Developer membership (see [Apple](#2-apple-developer-account) for why
the free tier cannot work here).

```bash
pip install pymobiledevice3 pyelftools pyjwt cryptography zeroconf
```

---

## 1. GitHub

### 1.1 The code repository (public)

Fork or push this repository as **public**. Public repositories get GitHub
Actions — including the macOS runners the signed build needs — at no cost.
A private repository bills macOS minutes at 10×, so the free 2,000 minutes
become about 200 macOS minutes a month, and the first ANGLE build alone is
around 60.

Nothing private ever goes into this repository: guest code and built apps
travel only encrypted (§3), and your library inventory, keys and certificates
are all gitignored.

### 1.2 If Actions jobs never start

A job that fails in two or three seconds with zero steps and

> The job was not started because your account is locked due to a billing issue

is an **account** problem, not a workflow problem. What we have seen cause it:

- **A GitHub incident.** Check <https://www.githubstatus.com> first: during an
  Actions outage the same billing message appeared for jobs that were fine.
- **An old failed invoice.** Settings → Billing and plans → *Payment history*.
  Declined charges from a long-cancelled paid plan can lock Actions years later,
  even when the billing page shows $0 owed and offers nothing to pay.
- **No valid payment method / a $0 spending limit.** Counter-intuitively,
  setting an Actions budget of **$0** can itself block jobs.

What unlocked it: remove any expired card, **add a valid card**, and set an
Actions budget of **$1** with "stop usage when the budget is reached" on. Public
repositories still cost $0; the $1 cap means you can never be charged more.
It can take a few minutes to take effect — trigger a *new* run (re-runs of a
blocked run may stay blocked). If it persists, open a ticket at
support.github.com → Billing, quoting the message and a run ID.

### 1.3 The guests repository (private)

The macOS runner needs each title's arm64 libraries. Those are not yours to
publish, so they live encrypted in a **separate private** repository:

```bash
gh repo create <you>/<name>-guests --private
gh api -X PUT repos/<you>/<name>-guests/contents/README.md \
   -f message="Initial commit" -f content="$(echo private | base64)"   # releases need one commit
gh release create guests --repo <you>/<name>-guests --title guests --notes "encrypted bundles"
```

### 1.4 A read-only token for it

Settings → Developer settings → Personal access tokens → **Fine-grained
tokens** → Generate new token.

- Repository access: **Only select repositories** → the guests repository
- Permissions: click **Add permissions**, tick **Contents**, close the menu.
  The access level appears *afterwards*, on the Contents row — make sure it
  reads **Read-only**. (Metadata: Read-only is added automatically.)

This is `MV_GUESTS_TOKEN`. Do not reuse your `gh` login token: it can do
everything your account can.

---

## 2. Apple Developer account

### 2.1 Paid, and why

CI signs through an **App Store Connect API key**, which lets the runner create
each title's App ID and development profile itself. API keys exist only on paid
memberships. The free tier also cannot create certificates or profiles
anywhere but inside Xcode, and its builds expire after 7 days.

Enrollment shows *pending* for a few hours to two days. You are active when the
membership page shows a **Team ID** (10 characters). If it stalls, look for an
email asking for identity verification, and make sure the enrollment name
matches your payment card.

Upgrading later does not extend apps installed under the free tier: their
expiry is in the provisioning profile they were signed with. Rebuild and
reinstall once.

### 2.2 Development certificate (made on Linux)

```bash
tools/metavision-signing csr
```

Upload `build/certs/dev.certSigningRequest` at developer.apple.com/account →
Certificates, IDs & Profiles → Certificates → **+** → **Apple Development**,
download the `.cer`, then:

```bash
tools/metavision-signing p12 ~/Downloads/development.cer
```

The private key never leaves `build/certs/`. The `.p12` is exported with
3DES/SHA1 on purpose: the macOS runner's `security import` rejects OpenSSL 3's
default AES encryption.

### 2.3 App Store Connect API key

appstoreconnect.apple.com → **Users and Access** → **Integrations** tab →
**App Store Connect API**. Click *Request Access* if it is offered (instant for
the account holder). Under **Team Keys**, generate a key with **Admin** access —
creating App IDs and profiles needs it.

**Download the `.p8` immediately; Apple only allows it once.** Note the **Key
ID** (in the key's row) and the **Issuer ID** (above the table). Check it:

```bash
export MV_ASC_KEY_P8=path/to/AuthKey_XXXXXXXXXX.p8 MV_ASC_KEY_ID=XXXXXXXXXX MV_ASC_ISSUER_ID=<uuid>
tools/metavision-signing asc-check
```

Keep the `.p8` and `.cer` outside the repository or in a folder the
`.gitignore` covers (`*.p8`, `*.cer`, `*.p12` are ignored).

---

## 3. Guests and secrets

```bash
tools/metavision-targets stage && tools/metavision-targets emit
tools/metavision-guest-bundle mv_<title> ...            # first run creates build/guest-bundle.key
gh release upload guests build/guest-bundle.tar.gz.enc --repo <you>/<name>-guests --clobber

export MV_TEAM_ID=XXXXXXXXXX MV_GUESTS_REPO=<you>/<name>-guests MV_GUESTS_TOKEN=github_pat_...
tools/metavision-signing secrets --repo <you>/<name>
```

That sets all ten secrets the workflows read (README, *Building without a Mac*).

---

## 4. The Vision Pro

### 4.1 Pair

Put the headset on the **same network** as the Linux machine and open
**Settings → General → Remote Devices**, and keep that screen open.

```bash
tools/metavision-device discover
tools/metavision-device pair          # type the 6-digit code the headset shows
```

Two things stock pymobiledevice3 gets wrong here, both handled by the tool:
it only asks for a PIN on Apple TV (and sends `000000` otherwise, failing with
`KeyError: PROOF`), and the headset is advertised twice (IPv4 and IPv6) under
one identifier. "`RemotePairingCompletedError`" from pymobiledevice3 itself
means pairing *succeeded*.

### 4.2 Read the UDID and register the headset

```bash
sudo tools/metavision-device info     # tunnel needs root, for the TUN interface
tools/metavision-device register --udid 00008XXX-XXXXXXXXXXXXXXXX
```

The App Store Connect API has no visionOS platform value: a Vision Pro registers
as `IOS` and comes back as `APPLE_VISION_PRO`. visionOS 26+ also omits
`peerDeviceInfo` from the pairing handshake, which stock pymobiledevice3 needs;
the tool supplies the identifier from the pairing record.

### 4.3 Developer Mode

It is not in Settings until a developer tool asks for it.

```bash
sudo tools/metavision-device devmode reveal
```

Then **Settings → Privacy & Security → Developer Mode** (at the bottom). If it
still is not there — on recent visionOS the reveal alone may not be enough —
the first install attempt of a development build (§5) makes it appear. Turn it
on, restart, and confirm the prompt after the restart (or
`sudo tools/metavision-device devmode accept`).

Over the tunnel, lockdown services are published with a `.shim.remote`
suffix (AMFI is `com.apple.amfi.lockdown.shim.remote`), so stock
pymobiledevice3's `amfi` commands fail with "No such service"; the tool
retries names with the suffix.

`devmode enable` will answer `Device has a passcode set`: remote enabling is
refused whenever a passcode exists, and a Vision Pro always has one.

---

## 5. Build and install

```bash
gh workflow run titles -f targets="mv_<title> ..." -f launcher=false   # one app per title
```

The first run builds ANGLE from source (about an hour); later runs restore it
from the Actions cache and take minutes. Download the artifact, then:

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass file:build/guest-bundle.key \
    -in mv_<title>.ipa.enc -out mv_<title>.ipa
sudo tools/metavision-device install mv_<title>.ipa
```

### Day-to-day device commands

| Command (`sudo tools/metavision-device …`) | Does |
|---|---|
| `install APP.ipa` | install or update an app (staged data survives) |
| `stage mv_<title>… \| --all [--launcher]` | copy titles' APK, assets, OBB and icon into the app over one connection. A finished title is marked and skipped with one read; part-copied files continue from their last byte; a dropped connection reconnects and carries on (`--retries`, default 20) |
| `icons` | copy just the icons of titles staged earlier into the launcher |
| `ls [--launcher]` | what is staged, with sizes |
| `logs mv_<title> [--launcher]` | pull the boot log and crash report |
| `logs --all` | every title's last run from the launcher; then `tools/metavision-triage` |
| `env mv_<title> [--launcher] KEY=VALUE …` | runtime switches for the next launch; none clears them |

**The headset sleeps as soon as it is taken off, and a copy in progress stops.**
There is no setting to keep it awake (visionOS 2 removed the old workarounds).
Keep it on, on charge, for long copies — a large OBB takes 15–40 minutes over
Wi-Fi. `stage` reconnects by itself when it drops, and re-running it resumes. While worn, a USB-C PD
charger of 30 W or more keeps it running indefinitely.

### Unattended test pass

`test` runs every title in the launcher with **scripted input**
(`MV_AUTOPLAY=1`) in every input mode. By default each title is launched once
and the modes follow one another, 20 s each — hands, hands-free, auto
(`MV_AUTOPLAY_CYCLE`), 95 s a title, about 75 minutes for 45 titles; with
`--modes hands,handsfree,auto` each mode is a launch of its own (75 s). Input
goes in through each mode's own path:

| mode | what the script does |
|---|---|
| `hands` | synthetic Touch controllers *and* synthetic Meta hand skeletons: aims at what looks pressable (or across a grid), clicking/pinching at each; A, B, X, grips, Menu and both sticks on their own periods |
| `handsfree` | no controllers or hands: a gaze ray at each target or grid point plus spoken commands (select, grab, confirm, back, menu, hold/release) fed into the hands-free layer, as Dwell Control and voice would |
| `auto` | the two alternating (every 20 s; 5 s inside a cycle), as a hand entering and leaving view |

Aiming goes for **what looks pressable**: every 1.5 s the eye the title drew
is shrunk to a 128-pixel luminance map (`MetavisionTargets`), regions dense with
edges (text, icons, button outlines) or standing out in brightness are picked
out, and each becomes a world direction through the frustum and head pose that
frame was rendered with. Auto-play rests about 0.35 s on a target before the
click, least-pressed first, and logs the targets as `[mv-target]`. One step in
four, and whenever nothing is found, it sweeps instead: a dense 7.5° scan of
where menus sit, then a wider grid, alternating between aiming from where the
title started (menus placed in the world) and from where the head now faces
(menus that follow it). After the first 30 s the **head moves**
as well (`MV_AUTOPLAY_HEAD=0` holds it still): the pose the title sees looks
around, turns right round once a minute, steps about and crouches.

A pass is **hidden** by default: each title runs, is screenshotted and has its
audio measured as usual, but nothing is drawn over passthrough and nothing is
heard (`MV_HIDDEN=1`, `.mixed` immersion), so the headset can be worn for other
things meanwhile. `--visible` shows and plays each title.

Every run also saves **screenshots** of the eye the title drew, every 15 s
(`MetavisionShots`), pulled beside the logs as `shot_NN.png`; triage reports
**BLACK CONTENT** when every one is dark or a flat colour — frames presented
but nothing in them. In hands-free the commands are **spoken** —
synthesised speech replaces the microphone's input, so the recogniser is
tested too (`MV_AUTOPLAY_SPEECH=0` hands them over directly); triage reports
phrases said against commands recognised. Speech recognition must have been
allowed once (choose Hands-free in the launcher and accept the prompts).
Real eye tracking, Dwell Control and the system pinch cannot be scripted:
visionOS gives apps a gaze ray only with a system select, and that ray is what
the script supplies.

After each run the title's boot log, the runtime's crash log and any system
crash report (`.ips`) are pulled to `build/test/<run>/<title>/<mode>/` and
judged by `tools/metavision-triage`: **pass**, **errors** (exceptions,
shader/compute failures, a library that would not load; the summary names the
error that decided it), **black** (never drew, or every screenshot empty),
**dark** (at most one screenshot with content: a sparse scene, or only the
controllers), **silent** (drew, no serious error, but never made a sound),
**stopped** (an unimplemented entry point), **asleep** (sent to the
background mid-run — the headset taken off; re-run, not counted) or
**crashed** (a fault, a crash report, or an exit on its own). Progress is saved after every run: a
dropped connection reconnects and carries on, running `test` again resumes an
unfinished pass, and `test --failed` re-runs only what did not pass last time.

Runs are **adaptive**: each lasts at most `--seconds` (60), but once past
`--min-seconds` (35) the runner reads the new part of the title's log every
5 s and ends the run as soon as it has drawn (two screenshots with content),
made sound, cycled through the hands and hands-free modes and logged nothing
serious. A healthy title takes about 40 s; a problem title gets the full
minute. `--no-adaptive` always runs the full time. The headset can come off at
any point: the runner sees it asleep, puts the run back, and `test` again
carries on.

Autoplay also **presses Unity UI buttons directly** (`MV_AUTOPLAY_UI`, on with
`MV_AUTOPLAY`): every 4 s from 10 s in, the least-pressed active, interactable
Button, Toggle or Dropdown, skipping labels that read like leaving the title
(quit, exit, back, home, reset). Each press is logged with its label
(`[mv-autoplay-ui] pressed 'English'`).

A **hands-only** title (its manifest requires `oculus.software.handtracking`)
is opened with a **two-hand start gesture**: both hands up in front of the
face, thumb and index tips touching, held still for 22 s. Such titles commonly
wait for both hands near the head, or for fingertips of both hands touching for
seconds, before they start what they draw. The mode cycle starts after it, and
the run gets 25 s more.
The fix loop is: `test` → `metavision-triage` → fix → rebuild and install →
`test --failed`, until nothing is left.

The headset must be **worn** throughout: visionOS stops drawing apps nobody
is looking through, and since visionOS 2 covering its inner sensor only delays
sleep. A hidden pass (the default) shows the wearer nothing but the room, so
the headset can be used for other things; with `--visible`, whoever wears it
should not watch: the scripted head motion swings the picture against their
real head. When two titles in a row come back without a picture after one that
drew, the pass takes the headset to be asleep: it puts those runs back in the
queue, pauses, and re-launches the last title that drew every 30 s until it
draws again — put the headset on (or wake it) and the pass carries on. Each
pause is recorded under `sleeps` in the run's `state.json`.

It needs Apple's developer services, which need the **developer disk image**
mounted, and visionOS's comes only from Xcode. Run the `ddi` workflow once
(Actions → ddi → Run workflow), then:

```bash
gh run download <run id> --repo <you>/<name> --dir build/ddi-dl
mkdir -p build/ddi && openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -pass file:build/guest-bundle.key -in build/ddi-dl/*/visionos-ddi.tar.gz.enc | tar xz -C build/ddi
sudo tools/metavision-device tunnel          # in its own terminal; leave it running
tools/metavision-device test                 # mounts the image when needed, then the pass
tools/metavision-triage                      # the latest pass, one line per title and mode
tools/metavision-device test --failed        # after a fix: only what did not pass
```

`tunnel` keeps one tunnel to the headset open and re-opens it when it drops;
while it runs, every other `metavision-device` command works **without sudo**
(they find it through `build/tunnel.json`). Without it, each command opens its
own tunnel and needs sudo. Narrow a pass with titles (`test mv_<title> ...`)
or `--modes hands`.

When a title will not start, see [COMPATIBILITY.md](COMPATIBILITY.md).

### Test pass in the simulator (no headset)

The same pass runs unattended in the visionOS Simulator on a GitHub macOS
runner — no headset to wear, nothing to fall asleep. Pack the titles' data
into an encrypted set in the private guests release, then run the `sim`
workflow on it:

```bash
tools/metavision-sim-data <set> mv_<title> ... --upload --repo <you>/<private-repo>
gh workflow run sim -f set=<set>          # -f seconds=95 per title
tools/metavision-sim-results              # latest run -> build/simtest/<run>/, triaged
```

The run's inputs name only the set, and its logs mask every title name; the
results (logs, screenshots, verdicts) come back encrypted with the guest key.
`--no-obb` keeps a set small by leaving expansion files out. The simulator
cannot show memory limits, GPU speed or the real eye, hand and microphone
hardware — the headset pass stays the last word on those.

**Its GPU is not the headset's, and rendering diverges.** Measured on the
`macos-26` runner (visionOS 26.5 simulator):

- Vulkan titles (MoltenVK): the simulator's Metal refuses draws with a non-zero
  base vertex and layered (both-eye) attachments, so every draw fails and the
  eye stays black. Argument buffers abort outright, so `metavision-sim` runs
  MoltenVK without them (`MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0`).
- GLES titles (ANGLE): compressed texture uploads take a simulator-only path
  that has crashed reading past its source.

So the simulator pass answers *does it boot, load, link and reach its render
loop* — JNI, loader, files, audio, input, crashes before the first frame — and
the headset answers *does it look right*.

### One app for every title: the metavision launcher

```bash
gh workflow run titles -f targets="mv_<title> mv_<title> ..."   # launcher is the default
sudo tools/metavision-device install metavision.ipa
sudo tools/metavision-device stage mv_<title> --launcher     # once per title
```

The launcher opens on a library of the titles it carries; choosing one boots
it. A process boots one title, so close the app to choose another. Each title
keeps its data under `Documents/<title>/` in the launcher's container.

Runtime switches for any app opened from the Home View go in
`Documents/klepton.env`: `sudo tools/metavision-device env mv_<title> KEY=VALUE ...`
(add `--launcher` for the launcher), and `logs` pulls the boot log back.

### Hands-free: eyes and voice

Every build can be played without hands — head-aimed pointer, gaze-snapped
selects, voice for the buttons. Setup, the full command list and what does
not work yet: [ACCESSIBILITY.md](ACCESSIBILITY.md).

### CI details worth knowing

- Klepton's Makefile finds `angle-patches/` through `$(PWD)`; run its make from
  inside `vendor/klepton`, never with `make -C` from elsewhere.
- Klepton syncs ANGLE with `DEPOT_TOOLS_UPDATE=0`, which also skips
  depot_tools' one-time bootstrap. A fresh runner fails in `gn` with
  `python3_bin_reldir.txt not found` unless `ensure_bootstrap` runs first.
- ANGLE is cached with explicit restore/save steps, saved as soon as it is
  built: the combined `actions/cache` only saves when the whole job succeeds,
  so one later failure would throw the hour away.
- Fetch MoltenVK (`make mvk`) before `make xros`, even for GLES-only titles:
  the runtime's no-Vulkan stub lacks `kl_vulkan_display_luid` and
  `kl_vulkan_capture_layers`, so the link fails without it.
- The memory entitlements (`increased-memory-limit`,
  `extended-virtual-addressing`) need an **explicit** App ID per title, so a
  wildcard profile cannot sign these builds; automatic signing with the API key
  creates them.
- The unverified `low-latency-streaming` entitlement is dropped
  (`KLEPTON_LOW_LATENCY=0`) so it cannot fail signing for the others.
