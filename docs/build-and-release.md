# Building, installing, releasing

## Setup

```bash
./scripts/bootstrap.sh
open Obadh.xcodeproj
```

If `xcodebuild` still points at Command Line Tools:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

The Xcode project is **generated**: edit `project.yml`, then
`xcodegen generate`. Requirements: Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen),
a Rust toolchain with the iOS targets (bootstrap installs what it can).

## The Rust bridge

```bash
./scripts/build-rust-xcframework.sh   # device + simulator slices
```

Rerun after any change under `rust/`. The engine's C header is vendored into
`rust/ObadhBridge/include/obadh.h` by this script.

**Engine version bumps** follow a fixed recipe: branch → bump the
`obadh_engine` dependency → rebuild the xcframework → **wipe DerivedData**
(stale archives otherwise link silently) → run the integration tests (pinned
fingerprints catch a silent artifact swap) → commit. Adding a new engine call
also means adding its symbol to the shim's `#[used]` table in
`rust/ObadhBridge/src/lib.rs`: the staticlib dead-strips unreferenced
dependency symbols.

## Device install

Signing lives in `Config/Signing.local.xcconfig` (git-ignored). The install
script infers `DEVELOPMENT_TEAM` from your Apple Development certificate,
stamps the build, regenerates the project, builds with automatic
provisioning, and installs:

```bash
./scripts/install-device.sh                 # Release (default)
DEVICE_ID=<udid> ./scripts/install-device.sh
CONFIG=Debug ./scripts/install-device.sh    # only when debug tooling is needed
```

Phones run **Release** by default: it excludes every `#if DEBUG` surface (the
test screen, the probe overlay, the control channel). With a free Personal
Team, provisioning profiles expire after 7 days. "Obadh is not available
anymore" on the device means the profile lapsed, not a code failure.

## Build configurations

| Config | Purpose |
|---|---|
| `Debug` | Development: debug panel, probe overlay, control channel. |
| `Debug-Legacy` | Debug, with the container app opted out of the modern system design (`UIDesignRequiresCompatibility`); reproduces the legacy keyboard presentation for parity work. iOS 26 SDK builds only. |
| `Release` | What users run. No debug surface, no text input in the app. |

## Build stamping

Every build is stamped with the git commit count, short SHA, and a UTC
timestamp (`scripts/stamp-build.sh` → `Config/BuildInfo.xcconfig`, generated
and git-ignored). The version shows in the app and is logged by the extension
on appear: a keyboard extension will otherwise happily keep serving a cached
old binary, so always confirm the stamp when testing on device.

## Release journal

[CHANGELOG.md](../CHANGELOG.md) records completed work under Unreleased until a
release is actually made. Each release section records version, build, release
date, annotated Git tag, full tested source commit, and the comparison range from
the previous tag. Preserve existing published tags.

Before release, review [KNOWN-ISSUES.md](../KNOWN-ISSUES.md) and complete the relevant
device checks. That is the sole open-issue/research register; move resolved items
into the changelog rather than retaining resolved entries or separate reports.
The changelog's maintenance section defines how to record the final source SHA
in a following documentation commit without changing the tested release tag.
