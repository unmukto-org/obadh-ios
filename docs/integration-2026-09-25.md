# v1.0.1 integration journal — 2026-09-25

## Baseline and method

- Starting `main`: `9d9b89073a48b14923b312bd3b24087163ea3917`.
- Published annotated `v1.0`: `94c8132d594a4af5beec7ec12a5ef90b0ec8b169`.
  Both trees are `369cd5c8625956e17c617f257de1922c256fadd9`.
  The existing release tag is preserved locally and on origin.
- Integration branch: `chore/integrate-v1.0.1`. Merge each distinct branch tip
  in dependency order, updating the changelog and issue register with its outcome.
  Branches already contained through ancestry are recorded without empty merges.
- The 14 task branches are cumulative. Their names do not establish that their
  intended fixes succeeded. Research harnesses must remain outside shipping targets.
- Preserve the unfinished spatial branch as a diagnostic engine probe only.
  Its output was changed to an XCTest attachment so it works without a writable
  source checkout or pre-existing pilot output directory. No decoder was added.
- Keep marketing version 1.0 during this integration; v1.0.1 is planned and
  unreleased. No new release tag, phone installation or external publication is
  part of this merge. Historical reports retain their original testing scope.

## Branch integration record

| Branch | Reviewed tip | Integration outcome |
| --- | --- | --- |

## Verification

Final integration verification is pending. Earlier reports describe the evidence
at their original commits; they are not substitutes for the final integration checks.
