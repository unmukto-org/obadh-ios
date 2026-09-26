# Changelog

This is a plain-language record of work since the last release. Unreleased work
is not a promise that a reported issue is fixed or that a build is on a device.
Current limitations and verification requirements live in [KNOWN-ISSUES.md](KNOWN-ISSUES.md).

## Unreleased — planned v1.0.1

### 2026-09-25

#### Fixes and changes

#### Investigation and testing

- Started a release journal and an evidence-based known-issues register. Reviewed
  the day's branches for sequential integration; the detailed branch and test
  record is in [the integration journal](docs/integration-2026-09-25.md).

## v1.0 — 2026-09-21 baseline

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
- When v1.0.1 ships, move the accumulated Unreleased entries into its dated
  version section, create an annotated tag for the tested release commit, and
  start a fresh Unreleased section. Do not create a release tag for ongoing work.
