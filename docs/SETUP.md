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
gh workflow run titles -f targets="mv_<title> ..."
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
| `stage mv_<title> [--launcher]` | copy a title's APK, assets, OBB and icon into the app — **re-run to resume**: anything already there at full size is skipped |
| `icons` | copy just the icons of titles staged earlier into the launcher |
| `ls [--launcher]` | what is staged, with sizes |
| `logs mv_<title> [--launcher]` | pull the boot log and crash report |
| `logs --all` | every title's last run from the launcher; then `tools/metavision-triage` |
| `env mv_<title> [--launcher] KEY=VALUE …` | runtime switches for the next launch; none clears them |

**The headset sleeps as soon as it is taken off, and a copy in progress stops.**
There is no setting to keep it awake (visionOS 2 removed the old workarounds).
Keep it on, on charge, for long copies — a large OBB takes 15–40 minutes over
Wi-Fi — and re-run `stage` if it drops; it resumes. While worn, a USB-C PD
charger of 30 W or more keeps it running indefinitely.

When a title will not start, see [COMPATIBILITY.md](COMPATIBILITY.md).

### One app for every title: the metavision launcher

```bash
gh workflow run titles -f targets="mv_<title> mv_<title> ..." -f launcher=true
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
