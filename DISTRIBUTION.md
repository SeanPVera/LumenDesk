# Shipping LumenDesk as an installable macOS app

LumenDesk already builds and runs. What it has never had is an artifact you
can hand to someone: a `.app` that opens on a Mac other than the one that
compiled it. This document covers the four ways to get there, what each one
costs, and the specific things about this app that make the choice matter.

Everything here uses tooling that ships with macOS and Xcode. No Homebrew, no
`create-dmg`, no third-party actions, matching the zero-dependency rule the
app itself follows.

## The short version

| Route | Cost | Opens on other Macs | Privacy grants survive updates |
| --- | --- | --- | --- |
| Build in Xcode | Free | No | Yes, with a signing team |
| Ad-hoc DMG | Free | Only after `xattr -dr` | No |
| Self-signed DMG | Free | Only after `xattr -dr` | Yes |
| Developer ID, notarized | $99/yr | Yes, double-click | Yes |
| Mac App Store | $99/yr | Yes, via the store | Yes |

If you are staying free, take the self-signed row over the ad-hoc one. Same
install friction, and it stops macOS from forgetting your Screen Recording
approval every time you ship an update. The last column is explained under
[Why the signature is what macOS remembers](#why-the-signature-is-what-macos-remembers).

## Route 1: build it in Xcode

Open `LumenDesk.xcodeproj`, pick the `LumenDesk` scheme and **My Mac**, press
`⌘R`. To keep the result, choose **Product → Archive**, then **Distribute
App → Copy App**, and drag the output into `/Applications`.

This is the whole story for one machine. The project sets `DEVELOPMENT_TEAM`
to `SW2N54YNK3` with automatic signing, so a member of that team gets an Apple
Development signature that stays the same across rebuilds, and the Screen
Recording and Local Network grants survive. Choose your own team in **Signing
& Capabilities** if you are not on it. When no team resolves, the build falls
back to an ad-hoc signature that is unique to each compile, and macOS treats a
rebuilt copy as a different app.

## Route 2: a free disk image

```sh
./scripts/package_macos.sh
```

With no signing credentials in the environment, the script archives a Release
build, ad-hoc signs it, and writes `dist/LumenDesk-<version>.dmg` plus a
SHA-256 file. Apple Silicon refuses to execute a binary with no signature at
all, which is why the script ad-hoc signs instead of passing
`CODE_SIGNING_ALLOWED=NO`.

It also writes `dist/LumenDesk-<version>.mode`, naming which of the modes
actually produced the image. The release workflow reads that file to decide
what the release notes say about Gatekeeper, because whether a certificate was
available and whether the artifact got notarized are different questions.

### Getting past Gatekeeper

The DMG is not notarized, so a Mac that downloaded it refuses to open the app.
One command clears it on every macOS version:

```sh
xattr -dr com.apple.quarantine /Applications/LumenDesk.app
```

The click-through route depends on the release. On Ventura and Sonoma,
Control-click the app and choose **Open**. Sequoia removed that shortcut, so
there you launch it once, let it get blocked, then go to **System Settings →
Privacy & Security** and click **Open Anyway** next to the warning.

### Use a self-signed certificate

Ad-hoc signatures are regenerated from scratch on every build. macOS therefore
treats each release as a different app and drops its Screen Recording and
Local Network approvals, which means re-granting both after every update.

A self-signed code signing certificate is free, takes about a minute, and
makes the signature stable so the approvals stick. It does nothing for
Gatekeeper, so the quarantine step above still applies.

1. Open **Keychain Access → Certificate Assistant → Create a Certificate**.
2. Name it something like `LumenDesk Self-Signed`.
3. Identity Type: **Self Signed Root**. Certificate Type: **Code Signing**.
4. Leave the rest at their defaults and create it.

Then build with it:

```sh
SIGNING_IDENTITY="LumenDesk Self-Signed" ./scripts/package_macos.sh
```

The script recognises that this is not a Developer ID, so it signs during the
archive, skips `exportArchive` and notarization, and signs the DMG without a
secure timestamp. Keep that certificate in your keychain and back it up. Lose
it and the next release looks like a new app to macOS again.

An **Apple Development** certificate from a free Apple ID works the same way
and the script handles it identically.

## Route 3: Developer ID and notarization

This is the real answer for an app that talks to hardware on your LAN and has
no business being in a store.

### What you need once

1. An Apple Developer Program membership, $99 a year.
2. A **Developer ID Application** certificate. Create it in Xcode under
   **Settings → Accounts → Manage Certificates → + → Developer ID
   Application**, or on the developer portal. It lands in your login keychain.
3. An **App Store Connect API key** for notarization. Go to App Store Connect
   → Users and Access → Integrations → App Store Connect API, create a key
   with the **Developer** role, and download the `.p8`. Apple lets you
   download it exactly once. Note the Key ID and the Issuer ID next to it.

The API key is the better path. The alternative, an Apple ID plus an
app-specific password, works and the script supports it, but it ties your
release pipeline to a human account and to two-factor prompts.

### Build a release locally

```sh
export TEAM_ID=ABCDE12345
export NOTARY_KEY_PATH=~/private_keys/AuthKey_XXXXXXXXXX.p8
export NOTARY_KEY_ID=XXXXXXXXXX
export NOTARY_ISSUER_ID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee

./scripts/package_macos.sh --version 1.0.0
```

The script finds the Developer ID identity in your keychain on its own. It
then archives, exports with manual Developer ID signing and a secure
timestamp, notarizes the app, staples the ticket, builds the DMG, signs the
DMG, notarizes that too, and staples it.

Both submissions are deliberate. Stapling only the DMG leaves an app that
needs an online Gatekeeper check the first time someone copies it out. Two
tickets means the app opens on a Mac with no network at all.

Pass `--skip-notarize` to sign without submitting when you are iterating.

### Build a release in CI

`.github/workflows/release.yml` runs on any `v*` tag. Add these repository
secrets and it signs and notarizes; leave them out and it still produces an
unsigned DMG as a workflow artifact, so the pipeline is useful before you pay
Apple anything.

| Secret | What it is |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Your Developer ID Application cert and private key, exported from Keychain Access as `.p12`, then `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | The password you set on that export |
| `APPLE_TEAM_ID` | Your 10-character team identifier |
| `MACOS_SIGNING_IDENTITY` | Optional. The full identity string. Omit it and the script reads the keychain |
| `NOTARY_KEY_P8` | The App Store Connect `.p8`, base64 encoded the same way |
| `NOTARY_KEY_ID` | Key ID from App Store Connect |
| `NOTARY_ISSUER_ID` | Issuer ID from App Store Connect |

Then cut a release:

```sh
git tag v1.0.0
git push origin v1.0.0
```

The workflow runs the test suite, imports the certificate into a throwaway
keychain, packages, publishes a GitHub Release with the DMG and its checksum
attached, and deletes the keychain whether or not the run succeeded.

## Route 4: the Mac App Store

Technically possible. The app already carries `com.apple.security.app-sandbox`
and a category, which are the two things people usually have to retrofit.

What it would additionally take: an App Store Connect record, screenshots, a
privacy nutrition label, and a switch from Developer ID signing to a **Mac App
Distribution** certificate with a provisioning profile.

Two things I would want to check before committing to this, because I do not
know how review would land:

- **Screen Recording for system audio.** Music Mode uses ScreenCaptureKit to
  capture system audio on macOS. ScreenCaptureKit is allowed in store apps,
  but reviewers do ask why an app needs screen access, and "to read audio"
  is a justification you would have to make in the review notes.
- **Vendor names.** The listing describes control of LIFX and Govee hardware
  over undocumented LAN protocols. That is legal to build and I have no
  reason to think review blocks it, but neither vendor has blessed it, and
  trademark use in store metadata is the kind of thing that draws a rejection
  letter. I am guessing here rather than reporting a rule.

For a local-first LAN utility with no accounts and no in-app purchases, the
store buys you very little and costs the same $99. Notarized direct download
is the better fit.

## Why the signature is what macOS remembers

Two macOS privacy grants are keyed to an app's code signature rather than its
path on disk:

- **Screen Recording**, which Music Mode needs for system-audio capture.
- **Local Network**, which every discovery scan needs on macOS 15 and later.

An ad-hoc signature is regenerated on every build, so macOS sees a new app
each time and drops both grants. That is the behavior already documented in
the README under Music Mode troubleshooting.

Any stable signing identity fixes it, including a free self-signed one. This
is a separate axis from Gatekeeper, which is what notarization buys. Worth
keeping the two apart when deciding what you need:

| | Stable privacy grants | Opens without a Terminal command |
| --- | --- | --- |
| Ad-hoc | No | No |
| Self-signed | Yes | No |
| Developer ID, notarized | Yes | Yes |

## Versioning

`Info.plist` reads `CFBundleShortVersionString` and `CFBundleVersion` from
`$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)`, both declared in
`project.yml`. The packaging script overrides them on the `xcodebuild` command
line, so a release never requires editing a tracked file. Version comes from
the git tag, build number from the commit count.

If you regenerate the project with `xcodegen generate`, those two settings
have to stay in `project.yml` or the plist substitutions resolve to empty
strings and the bundle ships with no version.

## Deliberately not included

- **Sparkle or any in-app updater.** Every option is a third-party package,
  and the project takes no SPM or CocoaPods dependencies. Updates go through
  GitHub Releases.
- **A Homebrew cask.** Worth doing once releases are notarized and stable.
  A cask that points at an unsigned DMG just moves the Gatekeeper problem.
- **A styled DMG window.** Background art and icon placement need Finder
  scripting, which is unreliable on headless CI runners. The image ships with
  the app and an `/Applications` symlink, which is enough to drag into.
