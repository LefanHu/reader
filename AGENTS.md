# Repository guidance

## Code comments and documentation

- Document every new or materially changed non-trivial type, public member, service boundary, and persisted field.
- Comments must explain purpose, invariants, lifecycle behavior, platform constraints, security decisions, or reasons for an implementation choice. Do not narrate syntax that is already clear from the code.
- Keep comments concise and next to the code they qualify. Update or remove them in the same change whenever behavior changes.
- Preserve documentation around EPUB trust boundaries, atomic catalog writes, complete text-position persistence, and platform support. These are product guarantees rather than incidental implementation details.
- Add short comments inside complex private flows where cleanup, ordering, recovery, accessibility, or responsive breakpoints would otherwise be easy to break.
- Test names should state behavior. Add comments inside tests only when the fixture or assertion protects a non-obvious regression.
- Important notes should go here in AGENTS.md

## Reader and interface invariants

- Rendering and illustration indexing must consume the same normalized `TextDocument` text and stable block identities. Keep extraction and normalization in `lib/text/`; do not introduce a second text pipeline.
- Persist the complete `TextPosition`: document version, section ID, block ID, and UTF-16 offset at an extended grapheme boundary. Reflow and mode changes restore the committed logical anchor rather than pixels or page numbers; entering Scroll must restore before its first painted frame.
- Curl previews must not advance positions, progress, persistence, or illustration gates. Commit only completed turns; cancel unfinished turns on reflow, chapter navigation, suspension, and exit. Preserve the existing two-section-layout and two-texture ownership limits, including disposal and stale-load rejection.
- Keep the toolbar's 60-pixel and bottom navigation's 62-pixel areas reserved when controls are hidden. Visibility changes must leave the reading viewport stationary. Keep every toolbar button visible, and center the chapter title independently of their widths.
- Honor reduced motion, paragraph semantics, keyboard navigation, and RTL logical navigation. Hidden controls must immediately stop receiving pointer, focus, and accessibility actions.
- Library book presentation follows the platform: macOS uses cover grids with hover/focus metadata; every iOS width uses list rows. Keep overlay reveals stationary, pin them while menus are open, and retain metadata semantics when hidden. The 700-pixel breakpoint controls the sidebar, not the book presentation.
- Approximate word counts come from normalized blocks, never source markup or widget builds. Keep `CatalogBook.wordCount` nullable for old catalogs; backfill outside the UI isolate, merge into current records, and never resurrect deleted books or discard reading updates.
- Use `lib/theme.dart` and the active `ColorScheme` for library, reader, menus, and dialogs. The saved reading theme applies app-wide; reading font preferences affect book text only. Preserve the library's 700-pixel sidebar breakpoint and layouts that accommodate large accessibility text.

## Import, persistence, and cloud boundaries

- Treat EPUB and TXT input as untrusted. Preserve encoding validation, archive and markup limits, traversal protection, and rejection of DRM, scripted, fixed-layout, or remote-resource EPUBs. Keep parsing off the UI isolate and commit only validated imports through private staging and SHA-256 deduplication.
- Preserve serialized atomic writes and restartable recovery. Delete only validated app-owned paths; legacy reset must durably enqueue known cloud deletion requests and commit the replacement catalog before deleting book directories. Global preferences and existing pending deletion requests survive reset.
- Importing and reading remain offline and account-free on iOS and macOS. Illustration identity remains iOS-only; startup deletion retries use an existing session without prompting for sign-in. Keep illustration consent and the remote rollout flag intact.
- Unknown or invalid illustration anchors remain locked. Unlock only after the leading committed position passes the complete ending paragraph, including the existing explicit end-of-book completion behavior. Cloud failures must not interrupt reading or prevent local deletion; retain failed deletion requests for retry and treat already-deleted books as success.

## Integration test organization

- Keep `integration_test/reader_test.dart` as the runner that registers feature groups. Put behavior-specific scenarios in `integration_test/scenarios/`.
- Make each scenario independently runnable with a fresh catalog and preferences. Use `integration_test/support/native_test_app.dart` for shared setup, navigation, screenshots, and teardown; do not depend on another scenario's state or execution order.
- Keep behavior-specific assertions in the scenarios. Put reusable document builders in `test/fixtures/`, rather than importing another `*_test.dart` file.
- Register cleanup before initialization, unmount the app before its final serialized persistence flush, and delete only the fixture-owned temporary directory. Release active gestures and captured images even when assertions fail.
- Keep native scenarios focused on complete user flows with real importing, storage, and rendering. Cover parsing and layout edge cases in unit or widget tests, and keep scenario names suitable for focused runs with `--plain-name`.

## Validation

- Run `dart format lib test`, `flutter analyze`, and `flutter test` after Dart changes.
- Format changed integration tests too. Run affected native scenarios on both macOS and an iOS simulator when changing shared reader or library behavior and those toolchains are available.
- After intentional visual changes, regenerate affected goldens and inspect the images; do not accept baseline updates solely because tests pass. Library baselines cover Paper, Sepia, and Dark in iOS lists and desktop grids, including revealed overlays.
- Run `npm run build` and `npm test` in `backend/` when backend behavior changes.
- When platform integration changes, also build or run the affected platform when its toolchain is available.
