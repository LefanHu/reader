# Repository guidance

## Code comments and documentation

- Document every new or materially changed non-trivial type, public member, service boundary, and persisted field.
- Comments must explain purpose, invariants, lifecycle behavior, platform constraints, security decisions, or reasons for an implementation choice. Do not narrate syntax that is already clear from the code.
- Keep comments concise and next to the code they qualify. Update or remove them in the same change whenever behavior changes.
- Preserve documentation around EPUB trust boundaries, atomic catalog writes, serial Readium access, complete locator persistence, and platform support. These are product guarantees rather than incidental implementation details.
- Add short comments inside complex private flows where cleanup, ordering, recovery, accessibility, or responsive breakpoints would otherwise be easy to break.
- Test names should state behavior. Add comments inside tests only when the fixture or assertion protects a non-obvious regression.

## Integration test organization

- Keep `integration_test/reader_test.dart` as the runner that registers feature groups. Put behavior-specific scenarios in `integration_test/scenarios/`.
- Make each scenario independently runnable with a fresh catalog and preferences. Use `integration_test/support/native_test_app.dart` for shared setup, navigation, screenshots, and teardown; do not depend on another scenario's state or execution order.
- Keep behavior-specific assertions in the scenarios. Put reusable document builders in `test/fixtures/`, rather than importing another `*_test.dart` file.
- Register cleanup before initialization, unmount the app before its final serialized persistence flush, and delete only the fixture-owned temporary directory. Release active gestures and captured images even when assertions fail.
- Keep native scenarios focused on complete user flows with real importing, storage, and rendering. Cover parsing and layout edge cases in unit or widget tests, and keep scenario names suitable for focused runs with `--plain-name`.

## Validation

- Run `dart format lib test`, `flutter analyze`, and `flutter test` after Dart changes.
- When platform integration changes, also build or run the affected platform when its toolchain is available.
