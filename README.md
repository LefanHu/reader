# Reader

An offline-first Flutter text reader for iPhone, iPad, and macOS. EPUB 2/3 and TXT imports are normalized by our Dart parser and displayed by a custom viewport using Flutter's text shaping and layout engine.

- Import several EPUB or TXT files from the native document picker, up to 100 MB each.
- Search by title or author; filter All / Reading / Finished; sort by recent activity or title. The macOS library uses cover tiles with details on hover or keyboard focus; iPhone and iPad use lists with metadata alongside cover thumbnails. Both retain a compact resume card.
- Subtle approximate word counts use the same normalized text as the reader. New imports count immediately; older books backfill in the background without changing reading positions. Unicode letter/number runs and individual Han/kana graphemes form a deterministic estimate; unspaced Thai and similar scripts can undercount.
- Choose Paper, Sepia, or Dark from the library Appearance menu or reading settings. One saved palette applies immediately to the whole app, including menus and dialogs; typography controls affect book text only.
- Open Settings from the library gear or macOS Settings… (Command-comma) to manage account, appearance, reading, global narration preferences, library defaults, usage, storage, privacy, and app information. Preferences stay local and work without an account; payments and cross-device synchronization are not included.
- Switch Page flip / Pages / Scroll, typography, themes, and window sizes while retaining a grapheme-safe text position.
- Preserve EPUB chapter structure, nested tables of contents, headings, paragraphs, and explicit line breaks. Publisher CSS, inline images, interactive links, and rich styling are omitted; local covers remain in the library.
- Read horizontal Unicode text, including RTL and mixed-direction passages, CJK, Indic scripts, Thai, combining marks, and emoji. Font coverage uses platform fallback. Vertical writing is not supported.
- Import strict UTF-8 TXT (with optional BOM) or BOM-marked UTF-16 LE/BE. Form feeds separate sections; large sections and paragraphs split deterministically at paragraph/grapheme boundaries to fit illustration API limits.
- Opt in per book to spoiler-safe AI illustrations, using exactly the text the viewport displays. Illustrations unlock after the leading reading position passes their ending paragraph, and persist in a local gallery.
- Persist source files, normalized sections, and the catalog under Application Support; global reading preferences remain in SharedPreferences.

Scripted, remote-resource, fixed-layout, and encrypted/DRM publications are rejected. Archive traversal, expansion, entry-count, and markup limits apply to every EPUB import. Import parsing and sidecar serialization run outside the UI isolate. The viewport retains at most two measured section layouts. Page flip uses those same layouts for an interactive paper curl, retaining at most two page textures (twice logical resolution, capped at 2048 pixels). Horizontal drags may start anywhere on the page: the fold follows horizontal travel, grab height, and live vertical movement, then settles from the last held shape. Vertical-only gestures do not turn pages. Tap the outer 20% to turn; center taps toggle controls. RTL sections mirror physical navigation. Positions and illustration gates advance only after completed turns; reflow, chapter jumps, suspension, and exit cancel unfinished turns. Reduced-motion settings use immediate page changes without curl textures. Unicode direction ranges are generated from Unicode 17.0.0; regeneration instructions are in `tool/generate_direction.py`.

Catalog version 2 intentionally discards legacy imported books and Readium reading positions on first launch. Global preferences survive. A durable reset marker makes cleanup restartable; known cloud illustration book IDs are queued for deletion before local data is removed. Startup retries use an existing identity session and never prompt for sign-in.

## Development

```sh
flutter pub get
flutter analyze
flutter test
flutter devices
flutter run -d <ios-device-id>
```

Library themes have desktop, hover-overlay, and compact iOS-list visual baselines in `test/goldens/`. After intentional design changes, regenerate them with `flutter test test/library_theme_test.dart --update-goldens` and inspect all nine images before committing.

For manual UI performance work, follow [Flutter's profiling guidance](https://docs.flutter.dev/perf/ui-performance): run `flutter run --profile -d macos` or `flutter run --profile -d <physical-ios-device-id>`, open the printed DevTools URL, and record the Performance view while opening a book, scrolling, turning pages, and navigating chapters. Diagnose UI and raster times separately against the display's frame budget. Debug builds and iOS simulators are not performance evidence.

Prefer removing redundant work over adding caches or custom infrastructure. Only optimize measured paths causing missed frames or accounting for at least 10% of frame time or allocations. Preserve complete narration/reading anchors, first-frame restoration, paragraph semantics, and explicit end-of-book completion before accepting an optimization.

The reusable native profiler imports a fixed 300-paragraph mixed-script EPUB into a fresh temporary catalog. Each of two repetitions resets to the same complete logical anchor, then measures library → open → twelve 450-pixel scroll gestures → eight page turns → contents navigation. The first and second repetitions remain separate: first-use and warmed costs must not be pooled. Import, mode changes, setup, screenshot readback, and artifact writing are outside the measured phases. Picker input, preferences, and cloud services are fake; parsing, storage, routes, and rendering are real and offline.

The runner uses Flutter's `benchmarkLive` frame policy: app/engine frame requests run normally, while artificial pump frames and extra pointer-fade debugging frames do not contaminate measurement. This also avoids artificial frame waits during timed gestures. Delayed raster timings are joined by engine frame number to frames observed during the action; frames from the two-second buffer flush are excluded from statistics. The policy is recorded in capture metadata; compare only matching policies. Each gesture/turn must advance its logical anchor, so skipped input cannot appear as a performance gain.

```sh
PROFILE_LABEL=baseline flutter drive --profile -d macos --no-dds \
  --target integration_test/performance_test.dart \
  --driver test_driver/performance_test.dart

# Use a new label after a code change, with the same device/window/settings.
PROFILE_LABEL=candidate flutter drive --profile -d macos --no-dds \
  --target integration_test/performance_test.dart \
  --driver test_driver/performance_test.dart
```

Replace `macos` with a physical iOS device ID for device measurements. Keep the macOS app frontmost; if Flutter reports that foregrounding failed, activate its window manually. `--no-dds` permits the in-app VM service connection. The dedicated runner rejects debug/release mode and is deliberately not registered in `reader_test.dart` or the normal unit suite. `vm_service` is an explicit development dependency, already supplied transitively by Flutter's integration-test tooling; it does not change app behavior.

The host driver writes `build/performance/<label>/` (Git-ignored). Omit `PROFILE_LABEL` for a timestamped label; labels cannot contain path separators, and existing captures are never overwritten.

- `raw.json`: versioned workload/device/settings metadata, a completion flag, and each phase's VM timeline, CPU samples, and raw engine frame timings in microseconds. Unreferenced CPU symbols are removed and stack indices remapped; every sample and stack frame is preserved.
- `summary.json`: the same metadata and completion flag, plus per-phase frame count; UI, raster, and total-span median/p95/maximum in milliseconds; and UI/raster/either-thread over-budget counts. p95 uses nearest rank. A frame exceeding both thread budgets counts once in `either_over_budget`; total-span scheduling latency is not treated as thread work.
- `<phase>_<repetition>_timeline.json`: individual raw VM timelines for trace inspection. CPU function/stack tables remain in `raw.json` for attribution; these are VM-service JSON, not DevTools session exports.

The budget uses the recorded display refresh rate, or an explicitly flagged 60 Hz reference if unknown. These are instrumented samples, not proof of physical presentation/dropped frames or release performance. There is no timing pass/fail threshold: correctness assertions and missing measurement data fail the run, while performance values are reported for comparison. Available data from a failed test is saved with `complete: false`; never compare it as a completed capture. A host-side timeout bounds connection, measurement, and export at three minutes (excluding build time); VM disconnections/timeouts fail and may prevent artifact export. Phase progress is printed so a stalled run can be located. CPU samples are time samples, not allocation counts.

Compare matching phase/repetition names only when fixture/source hash, normalization version, device, OS/Flutter version, actual window dimensions, scale, refresh rate, and settings match. Metadata records platform, OS/Dart versions, window/display properties, fixture identity, and settings; save the device model/ID and `flutter --version` alongside it. The fixed archive timestamp keeps fixture hashes stable across launches. On the second repetition, scroll/chapter PNG paths are printed; iOS screenshots reside in the device's app container. Fixture teardown unmounts, flushes serialized persistence, and deletes only its own temporary catalog. Keep captures while investigating; delete only the chosen `build/performance/<label>/` directory when finished.

The earlier experimental lazy list was rolled back because narration-anchor verification failed despite faster scrolling. That optimization is not shipped, and its old `profile_baseline.json`/`profile_lazy.json` captures are not directly comparable with this runner's reset-to-start repetitions.

AI illustrations are available on configured iOS and macOS builds. They remain
inert unless the build supplies platform-specific Firebase/Google OAuth and API
values:

```sh
flutter run -d <ios-device-id> \
  --dart-define=FIREBASE_API_KEY=... \
  --dart-define=FIREBASE_APP_ID=... \
  --dart-define=FIREBASE_MESSAGING_SENDER_ID=... \
  --dart-define=FIREBASE_PROJECT_ID=... \
  --dart-define=FIREBASE_STORAGE_BUCKET=... \
  --dart-define=FIREBASE_GOOGLE_CLIENT_ID=... \
  --dart-define=FIREBASE_GOOGLE_SERVER_CLIENT_ID=... \
  --dart-define=ILLUSTRATION_API_BASE_URL=https://YOUR_API_HOST
```

For a registered Firebase App Check debug token in development on an iOS
simulator or macOS, add `--dart-define=FIREBASE_APP_CHECK_DEBUG=true`. Never set it
in release builds. Production macOS protected generation requires macOS 14+ and
a supported installation producing valid App Check tokens; OS version and
signing alone do not establish App Attest support. Local reading remains
available on older supported systems.

The feature signs in with Google only after the reader taps the illustration
control; per-book consent is required before chapter prose is uploaded.
Importing and reading remain account-free and offline. Configure the selected
platform's native Google OAuth client, Firebase Authentication, App Check/App
Attest, and the services described in [`backend/README.md`](backend/README.md)
before enabling the server-side rollout flag. macOS uses its separate Firebase
registration and `FIREBASE_GOOGLE_MACOS_CLIENT_ID`; iOS still requires its own
`FIREBASE_GOOGLE_CLIENT_ID`.

Provision and deploy the complete Firebase/Google Cloud backend with
`tool/deploy_backend dev`. Infrastructure is tracked in [`infra/`](infra/README.md);
use `tool/plan_infra dev` to review drift without applying it. The deployment
generates the ignored `.dart-defines/dev.json` file used by:

```sh
flutter run -d <ios-device-id> --dart-define-from-file=.dart-defines/dev.json
flutter run -d macos --dart-define-from-file=.dart-defines/dev.json
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

The native integration runner registers independent **Library**, **Reading**,
**Reader controls**, **Page flip**, **Narration**, **Accounts**, and **Settings**
groups from `integration_test/scenarios/`. Each test creates its own temporary
catalog through `integration_test/support/native_test_app.dart`; cleanup runs even
on failure. Import parsing, file storage, rendering, and narration playback are
real; picker input, preferences, and cloud services use fakes. Settings flows cover
global controls, playback reset, cache removal, and complete committed anchors.
EPUB fixtures live in `test/fixtures/` instead of importing another test suite.
Platform screenshots are written to the test app's temporary directory and their
paths are printed. Add `--no-uninstall` on iOS when inspecting those PNGs after
the command exits; the default uninstall removes their app container.

Run one group or scenario without changing the entry point:

```sh
flutter test integration_test/reader_test.dart -d macos --plain-name 'Reader controls'
flutter test integration_test/reader_test.dart -d <ios-simulator-id> --plain-name 'nested EPUB contents'
```

Offline importing and reading work on iOS and macOS. Illustration authentication uses the shared Google/Firebase identity on both platforms, while protected generation still requires valid App Check. The iOS deployment target is 15.0 and macOS target is 12.0. No loopback web server or EPUB-specific App Transport Security exception is required.

Validate every EPUB fixture separately with the official EPUBCheck release:

```sh
java -jar /path/to/epubcheck.jar path/to/book.epub
```

## Organization

- `lib/models.dart` contains catalog records, complete text positions, and reader settings.
- `lib/storage.dart` contains serialized atomic catalog writes, restartable legacy reset, and preferences persistence.
- `lib/book_service.dart` contains selection, isolated parsing, hashing, and atomic import staging.
- `lib/text/` contains normalized documents, EPUB/TXT parsing, Unicode direction detection, lazy section loading, measured scroll/page layout, and logical navigation.
- `lib/controller.dart` is the single shared `ChangeNotifier` and coordinates catalog, identity, and feature lifecycles. `lib/account/usage_coordinator.dart` owns usage snapshots and request fencing across account changes and disposal; `lib/account/api.dart` owns authenticated transport and response validation.
- `lib/illustrations/` contains normalized text indexing, spoiler gating,
  authenticated REST, atomic sidecars, local assets, and deletion retries.
- `lib/theme.dart` defines the shared app-wide palettes; `lib/library.dart` and `lib/reader.dart` contain the adaptive library and reader shell.
- `backend/src/index.ts` composes the API and worker, authentication, rollout gates, and task delivery. `backend/src/illustration-worker.ts` owns illustration execution, world-history loading, credit reservations, moderation, and private asset publication/cleanup. Provider logic remains in `backend/src/openai.ts`; narration and account services remain separate feature boundaries.

Lora and DM Sans are bundled under the SIL Open Font License. Remaining dependency and Unicode data notices are recorded in `THIRD_PARTY_NOTICES.md`.

## Google accounts

Settings → Account signs in with Google independently of cloud generation.
Signing in does not consent to uploading prose. Reading and importing remain
account-free; only opted-in cloud features require authentication and App Check.
Sign out clears both Google and Firebase sessions without changing local books.
Account deletion reauthenticates the same Google user and requires a successful
cloud purge before deleting Firebase identity or clearing local feature consent
and audio. Missing or failed purge endpoints leave those local records intact.
Local books and complete reading positions survive deletion; Settings reflects
the actual identity even if post-purge local cleanup reports an error.

Deploy authentication with `tool/deploy_backend dev --scope core` after configuring
Google OAuth clients. It requires no OpenAI key or feature API deployment. Supply
web OAuth credentials privately through `TF_VAR_google_client_id` and
`TF_VAR_google_client_secret`; never commit them. See [infrastructure setup](infra/README.md).
Build with `--dart-define-from-file=.dart-defines/dev.json` after generating the
matching iOS/macOS callback settings. Regenerate the selected environment before
switching builds. Google sign-in replaces Apple authentication; native Firebase
registrations and App Attest remain in place.

## Settings and usage

Settings stays single-pane on iOS, including tablet widths. macOS uses a sidebar
at widths of at least 700 pixels when text scale is at most 1.5; narrower windows
or larger type use compact navigation. Choices support keyboard activation and
announce selection on the actionable control.

Voice and listening speed are global across books. Settings and the listening
sheet edit the same saved values. Speed changes immediately without regenerating
audio. Changing voice pauses listening at the committed text position and waits
for Play; uncached speech then consumes allowance. Existing per-book consent,
cached audio, and text progress remain intact. Legacy narration sidecar voice
values identify cached/resumable audio and do not override global preferences.

Library filter/sort defaults are saved separately from temporary library choices.
Reset preferences restores the app-wide defaults without deleting books, account,
consent, or caches. Clearing downloaded narration stops playback and invalidates
audio resume offsets while preserving books, consent, and complete text anchors.
The displayed cache size refreshes after clearing finishes.

Usage & allowance displays only server-reported balances, includes outstanding
generation reservations, and shows unavailable/offline states when no snapshot
can be obtained. The read-only `/v1/account/usage` endpoint requires Firebase Auth
and App Check even while generation is disabled; viewing it neither initializes
credits nor grants prose-upload consent. A core-only build can sign in and change
local settings without an API deployment. Payments and subscriptions are deferred.

## Listening to books

The Listen toolbar action opens per-book consent before Google sign-in or prose
upload. Narration supports Marin/Cedar voices, 0.75–2× speed, chapter selection,
play/pause, ±15-second audio seeking, remaining allowance and local cache clearing.
One audio handler continues playback in the library and while the device is
locked; the library includes a mini-player. Opening another book or navigating
manually pauses narration and invalidates the old audio offset.
The native service is initialized once per Flutter engine. Closing a controller
stops its audio and unbinds callbacks without replacing the shared handler; a
speed-only edit immediately updates native media state as well as playback.
The narration sheet's Cloud account menu supports signing out and deleting cloud
data on either platform. Account deletion clears downloaded narration while
preserving local books and reading positions.

Listening uses the same committed logical reading position as visual reading.
Only naturally completed chunks advance prose or unlock illustrations. Downloads,
prefetch and audio seeking never advance progress. After seeking, replay from the
committed passage to grant completion. Pausing restores the committed listening
anchor without continuous scrolling or word highlighting. Interrupted chunks
retain the complete text position, chunk identity and audio offset. Cached replay
works offline and consumes no generation allowance; a 250 MiB LRU cache bounds
local audio. Changing speed reuses audio; changing voice generates new speech.

Narration remains remotely disabled by default. See [backend configuration](backend/README.md#ai-narration-disabled-by-default)
and the guarantees in [AGENTS.md](AGENTS.md#narration-guarantees). Generated Firebase
Dart defines include separate iOS/macOS app identifiers and API keys under one
project. Local macOS builds use development signing and a matching provisioning
profile for the Keychain groups required by Google sign-in. Protected generation additionally
requires a valid App Check token from a supported installation on macOS 14 or
later; the OS version alone does not guarantee App Attest availability. Validate
attestation on the intended distribution before enabling rollout. Existing
offline reading remains available on supported older systems.

The **Narration** native test group uses real imports, local audio files, native
audio decoding, storage and rendering, with fake cloud generation. Run it with
`flutter test integration_test/reader_test.dart -d <device> --plain-name Narration`.
Signed-device background/media actions and representative multilingual narration
still require listening checks before enabling rollout.
