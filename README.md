# Reader

An offline-first Flutter text reader for iPhone, iPad, and macOS. EPUB 2/3 and TXT imports are normalized by our Dart parser and displayed by a custom viewport using Flutter's text shaping and layout engine.

- Import several EPUB or TXT files from the native document picker, up to 100 MB each.
- Search by title or author; filter All / Reading / Finished; sort by recent activity or title. The adaptive library uses flat cover tiles and a compact resume card.
- Choose Paper, Sepia, or Dark from the library Appearance menu or reading settings. One saved palette applies immediately to the whole app, including menus and dialogs; typography controls affect book text only.
- Switch Page flip / Pages / Scroll, typography, themes, and window sizes while retaining a grapheme-safe text position.
- Preserve EPUB chapter structure, nested tables of contents, headings, paragraphs, and explicit line breaks. Publisher CSS, inline images, interactive links, and rich styling are omitted; local covers remain in the library.
- Read horizontal Unicode text, including RTL and mixed-direction passages, CJK, Indic scripts, Thai, combining marks, and emoji. Font coverage uses platform fallback. Vertical writing is not supported.
- Import strict UTF-8 TXT (with optional BOM) or BOM-marked UTF-16 LE/BE. Form feeds separate sections; large sections and paragraphs split deterministically at paragraph/grapheme boundaries to fit illustration API limits.
- Opt in per book to spoiler-safe AI illustrations, using exactly the text the viewport displays. Illustrations unlock after the leading reading position passes their ending paragraph, and persist in a local gallery.
- Persist source files, normalized sections, and the catalog under Application Support; global reading preferences remain in SharedPreferences.

Scripted, remote-resource, fixed-layout, and encrypted/DRM publications are rejected. Archive traversal, expansion, entry-count, and markup limits apply to every EPUB import. Import parsing and sidecar serialization run outside the UI isolate. The viewport retains at most two measured section layouts. Page flip uses those same layouts for an interactive paper curl, retaining at most two page textures (twice logical resolution, capped at 2048 pixels). Drag or tap the outer 20% to turn; center taps toggle controls. RTL sections mirror physical navigation. Positions and illustration gates advance only after completed turns; reflow, chapter jumps, suspension, and exit cancel unfinished turns. Reduced-motion settings use immediate page changes. Unicode direction ranges are generated from Unicode 17.0.0; regeneration instructions are in `tool/generate_direction.py`.

Catalog version 2 intentionally discards legacy imported books and Readium reading positions on first launch. Global preferences survive. A durable reset marker makes cleanup restartable; known cloud illustration book IDs are queued for deletion before local data is removed. Startup retries use an existing identity session and never prompt for sign-in.

## Development

```sh
flutter pub get
flutter analyze
flutter test
flutter devices
flutter run -d <ios-device-id>
```

Library themes have desktop and compact visual baselines in `test/goldens/`. After intentional design changes, regenerate them with `flutter test test/library_theme_test.dart --update-goldens` and inspect all six images before committing.

AI illustrations are inert unless the build supplies Firebase and API values:

```sh
flutter run -d <ios-device-id> \
  --dart-define=FIREBASE_API_KEY=... \
  --dart-define=FIREBASE_APP_ID=... \
  --dart-define=FIREBASE_MESSAGING_SENDER_ID=... \
  --dart-define=FIREBASE_PROJECT_ID=... \
  --dart-define=FIREBASE_STORAGE_BUCKET=... \
  --dart-define=ILLUSTRATION_API_BASE_URL=https://YOUR_API_HOST
```

For a registered Firebase App Check debug token on an iOS simulator, add
`--dart-define=FIREBASE_APP_CHECK_DEBUG=true`. Never set it in release builds.

The feature signs in with Apple only after the reader taps the illustration
control. Importing and reading remain account-free and offline. Configure the
Apple capability, Firebase Authentication provider, App Check/App Attest, and
the services described in [`backend/README.md`](backend/README.md) before
enabling the server-side rollout flag.

Provision and deploy the complete Firebase/Google Cloud backend with
`tool/deploy_backend dev`. Infrastructure is tracked in [`infra/`](infra/README.md);
use `tool/plan_infra dev` to review drift without applying it. The deployment
generates the ignored `.dart-defines/dev.json` file used by:

```sh
flutter run -d <ios-device-id> --dart-define-from-file=.dart-defines/dev.json
```

Check package updates with:

```sh
flutter pub outdated
flutter pub upgrade --dry-run
```

Apple dependencies use CocoaPods for the remaining Firebase and file-picker integration. Install and validate with:

```sh
cd ios && pod install && cd ..
cd macos && pod install && cd ..
flutter build ios --simulator --no-codesign
flutter build macos
flutter test integration_test/reader_test.dart -d macos
flutter test integration_test/reader_test.dart -d <ios-simulator-id>
```

Offline importing and reading work on iOS and macOS. Illustration authentication remains iOS-only. The iOS deployment target is 15.0 and macOS target is 12.0. No loopback web server or EPUB-specific App Transport Security exception is required.

Validate every EPUB fixture separately with the official EPUBCheck release:

```sh
java -jar /path/to/epubcheck.jar path/to/book.epub
```

## Organization

- `lib/models.dart` contains catalog records, complete text positions, and reader settings.
- `lib/storage.dart` contains serialized atomic catalog writes, restartable legacy reset, and preferences persistence.
- `lib/book_service.dart` contains selection, isolated parsing, hashing, and atomic import staging.
- `lib/text/` contains normalized documents, EPUB/TXT parsing, Unicode direction detection, lazy section loading, measured scroll/page layout, and logical navigation.
- `lib/controller.dart` is the single shared `ChangeNotifier`.
- `lib/illustrations/` contains normalized text indexing, spoiler gating,
  authenticated REST, atomic sidecars, local assets, and deletion retries.
- `lib/theme.dart` defines the shared app-wide palettes; `lib/library.dart` and `lib/reader.dart` contain the adaptive library and reader shell.
- `backend/` contains the Cloud Run API/worker, scene planning, image provider,
  moderation, credit reservations, private delivery, and deletion endpoints.

Lora and DM Sans are bundled under the SIL Open Font License. Remaining dependency and Unicode data notices are recorded in `THIRD_PARTY_NOTICES.md`.
