# Changelog

This is a plain-language record of work since the last release. Unreleased work
is not a promise that a reported issue is fixed or that a build is on a device.
Current limitations and verification requirements live in [KNOWN-ISSUES.md](KNOWN-ISSUES.md).

## Unreleased — planned v1.0.1

Release date: not set. Release tag and commit: not created.
Baseline: `v1.0` (`94c8132d594a4af5beec7ec12a5ef90b0ec8b169`).

### 2026-09-25

#### Fixes and changes

- Stabilized key-row positions during transient keyboard heights. Cancelled stale suggestions and touches on context changes, cleaned up held-delete timers, restored accessible key activation, and retained caps lock when typing.

- Fixed detached keys using the wrong appearance for their fill and updating only after a touch or refresh. Reset accidental debug sizing overrides that caused an extra 18-point ribbon and isolated deliberate sizing experiments.

- Updated key overlays for Increase Contrast and Reduce Transparency, respected Reduce Motion for press feedback, and used a native glass primary onboarding button on iOS 26+. Investigated host sizing without shipping an unverified height workaround.

- Adjusted modern portrait iPhone letter sizing and baselines against native captures: regular system font, 25 pt lowercase and 21.5 pt uppercase. Verified sampled glyph dimensions and baselines on the iPhone.

#### Investigation and testing

- Started a release journal and a single known-issues and research register.
  Reviewed the day's branches for sequential integration.

## v1.0 — 2026-09-21 baseline

Version: `1.0` (build `105`). Tag: `v1.0` (annotated).
Commit: `94c8132d594a4af5beec7ec12a5ef90b0ec8b169`.
Date: 2026-09-21 (App Review submission/tag date).
Comparison: first release baseline; no earlier release recorded here.

- Prepared Obadh 1.0 (105) for App Review under `org.unmukto.obadh`.
- The existing annotated `v1.0` tag identifies `94c8132`. The pre-patch `main`
  merge commit, `9d9b890`, has exactly the same source tree. The published tag
  is preserved; this date records the submission baseline, not an independently
  verified App Store availability date.

## Maintaining this journal

- Add completed work under Unreleased, dated when it was integrated. Describe
  what changed in plain language; keep plans and unresolved symptoms in the
  issue register. Record investigations as investigations, not fixes.
- Update both files in the same change when an issue's status changes. Link to
  the issue ID and supporting report instead of copying raw logs into this file.
- Correct inaccurate claims explicitly. Keep released entries intact and add
  dated corrections when necessary.
- For each new release, use a `vX.Y.Z — YYYY-MM-DD` section and record the
  marketing version, build number, actual release date, annotated tag, full
  40-character release commit, and a comparison link/range from the previous
  release tag. Preserve the dated work entries below that metadata.
- Build and test the release commit first. Record that exact source SHA here in
  a following documentation commit, and point the annotated release tag at the
  tested source commit. This avoids inventing a self-referential commit hash or
  tagging a different binary source. Record the distinction if documentation
  changed after the build; never silently move an existing published tag.
- When v1.0.1 ships, move the accumulated Unreleased entries into its dated
  version section and start a fresh Unreleased section based on that tag. Do not
  create a release tag or claim a release date for ongoing work.
