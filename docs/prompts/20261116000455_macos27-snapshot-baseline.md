# Delegated request

Fix the existing PR112 macOS27.2.1 snapshot-baseline CI failure in a separate disposable worktree at 9c076a1; do not edit the root checkout or push. Re-record existing references for current native OS, review every changed old/actual image for OS-only rendering drift, preserve tests/tolerances, and verify comparisons. Exclude the four model-setup-fritz-{available,populated}-macOS.{light,dark}.png references because the root task replaces that layout and adds downloading/error references. Keep remaining baseline images plus concise OS-baseline documentation/evidence in a focused commit for cherry-pick; no PR, push, or merge. Coordinate shared build locks and do not kill other tests/apps. Log this prompt separately and report checks, OS, and differences beyond native rendering.

# Evidence and scope

CI run 43818614727 passed native compilation after SDK selection repair, then failed all 68 visual comparisons on macOS 27.2.1 (26B131). Unchanged button, chat, and tab controls also drifted. This worktree starts at the unchanged failing application commit, so only reviewed platform-rendering references and baseline documentation will change. Test code and precision remain unchanged.

## Follow-up: deterministic scroll geometry

Root requested investigating and repairing the four scrollbar-gutter mismatches at the existing snapshot fixture owner without global preference changes, tolerances, skips, or production seams.

Public NSScrollView diagnostics showed a 440-point viewport starting with a 423-point document under legacy preferences. Existing AppKit normalization expanded the clip to 440 but left the SwiftUI document proposal at 423. Extra NSView layout invalidation did not repair it. The fixture now uses `scrollIndicators(.never)` before initial SwiftUI layout: Apple's public API explicitly overrides scrollable views that keep indicators visible, while `hidden` is only a preference (https://developer.apple.com/documentation/swiftui/scrollindicatorvisibility/never). Targeted populated-picker light/dark actuals then exactly matched CI. Temporary diagnostics and manual layout experiments were removed; no production source or global preferences changed.

# Review and verification

- Environment: macOS 27.2.1 (26B131), Apple Silicon, Xcode 26.6 (17F113), Swift 6.3.3.
- Before recording, `make check-ui-snapshots` reproduced 68 failures across 20 tests. Recorded unchanged application views in the full root Swift suite through the build-cache wrapper; recording's 68 assertion failures were expected.
- Reviewed every old/current image in 17 paired review sheets. All image dimensions and fixture content remain unchanged. Changes are native control tint, disabled-control appearance, glyph rendering, plus the deliberate removal of the inherited 17-point scrollbar gutter. Re-reviewed the eight images affected by the stronger scroll indicator policy. Four provider-table images have a one-pixel header separator difference. No content, labels, selection, row ordering, or clipping regressions were found.
- With the final fixture policy, 64 of 68 current images pixel-match the failed CI run's actuals, including all four picker images. The remaining four are the reviewed table header separator pixels affected by the policy.
- Final `make check-ui-snapshots`: 20 tests, zero failures. `make test` passed Rust, runtime integrations, 90 root Swift tests (19 normal visual skips), and 32 app Swift tests. `make check` passed formatting and Clippy. No new tests, tolerance changes, global preference mutations, or production code changes.
- Per delegation, restored the four model-setup-fritz available/populated light/dark references before committing. The full 20-test comparison was performed before this exclusion. The root task supplies the compact-sheet replacements and must run the integrated full snapshot comparison; this maintenance commit alone intentionally retains those four prior references.
- Review artifacts and manifests remain under /tmp/fritz-macos27-image-review; comparison/test/check logs are /tmp/fritz-macos27-final-compare.log, /tmp/fritz-macos27-test.log, and /tmp/fritz-macos27-check.log. No push, PR, or merge performed.
