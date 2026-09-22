# Repository guidance

## Code comments and documentation

- Document every new or materially changed non-trivial type, public member, service boundary, and persisted field.
- Comments must explain purpose, invariants, lifecycle behavior, platform constraints, security decisions, or reasons for an implementation choice. Do not narrate syntax that is already clear from the code.
- Keep comments concise and next to the code they qualify. Update or remove them in the same change whenever behavior changes.
- Preserve documentation around EPUB trust boundaries, atomic catalog writes, serial Readium access, complete locator persistence, and platform support. These are product guarantees rather than incidental implementation details.
- Add short comments inside complex private flows where cleanup, ordering, recovery, accessibility, or responsive breakpoints would otherwise be easy to break.
- Test names should state behavior. Add comments inside tests only when the fixture or assertion protects a non-obvious regression.

## Validation

- Run `dart format lib test`, `flutter analyze`, and `flutter test` after Dart changes.
- When platform integration changes, also build or run the affected platform when its toolchain is available.
