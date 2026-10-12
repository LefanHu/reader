# Reader

An offline-first Flutter text reader for iPhone, iPad, and macOS. EPUB 2/3 and TXT imports (up to 100 MB each) are normalized by our Dart parser and displayed by a custom viewport using Flutter's text layout engine.

- Library: search by title/author, filter All / Reading / Finished, sort by recent activity or title. macOS uses cover tiles; iPhone/iPad use lists. Approximate word counts are computed at import from the same normalized text as the reader.
- Reading: Page flip (interactive paper curl) / Pages / Scroll, Paper / Sepia / Dark palettes applied app-wide, typography controls for book text only. Switching modes, themes, or window sizes retains a grapheme-safe text position.
- Text selection works in every mode (long-press and handles on iOS, mouse-drag on macOS). Copy keeps normalized text; Look Up opens the OS dictionary; Read from here starts narration at the start of the selection's first paragraph. Selecting never commits reading progress.
- Edge Back: swiping right from the leftmost 20 logical pixels (at least 64 px) goes Back in Reader and Settings. Reader flushes its full committed position first.
- EPUB structure (chapters, nested TOC, headings, paragraphs, line breaks) is preserved. Publisher CSS, inline images, links, and rich styling are omitted; covers stay in the library. Scripted, remote-resource, fixed-layout, and encrypted/DRM EPUBs are rejected, with archive traversal, expansion, entry-count, and markup limits.
- Text: horizontal Unicode incl. RTL, CJK, Indic, Thai, emoji (platform font fallback); vertical writing is unsupported. TXT must be strict UTF-8 (optional BOM) or BOM-marked UTF-16; form feeds separate sections.
- Optional per-book, spoiler-safe AI illustrations built from exactly the displayed text; they unlock once the leading reading position passes their ending paragraph and persist in a local gallery. Art direction and image source are saved per book: OpenAI (initial default), Google (recommended when configured), ByteDance Seedream, Alibaba Qwen, xAI, and BFL FLUX. Settings affect future submissions and explicit regeneration, not ready artwork or admitted jobs.
- Settings (library gear, or Command-comma on macOS) hold account, appearance, reading, global narration, library defaults, usage, storage, privacy, and app info. Preferences are local and need no account; payments and sync are not included.
- Storage: source files, normalized sections, and the catalog live under Application Support; reading preferences in SharedPreferences.

## Development

```sh
flutter pub get
flutter analyze
flutter test
flutter devices
flutter run -d <ios-device-id>
```

The iOS deployment target is 15.0 and macOS is 12.0. Apple targets use CocoaPods (Firebase, file picker). Install and validate with:

```sh
cd ios && pod install && cd ..
cd macos && pod install && cd ..
flutter build ios --simulator --no-codesign
flutter build macos
flutter test integration_test/reader_test.dart -d macos
flutter test integration_test/reader_test.dart -d <ios-simulator-id>
```

Check dependencies with `flutter pub outdated` and `flutter pub upgrade --dry-run`. Validate EPUB fixtures with the official EPUBCheck: `java -jar /path/to/epubcheck.jar path/to/book.epub`.

### Cloud features

AI illustrations and cloud narration are inert unless the build supplies Firebase/Google OAuth and API values. Provision and deploy the whole Firebase/Google Cloud backend with `tool/deploy_backend dev`; infrastructure is tracked in [`infra/`](infra/README.md) (`tool/plan_infra dev` reviews drift without applying). Deployment generates the ignored `.dart-defines/dev.json`:

```sh
flutter run -d <ios-device-id> --dart-define-from-file=.dart-defines/dev.json
flutter run -d macos --dart-define-from-file=.dart-defines/dev.json
```

Defines can also be passed individually: `FIREBASE_API_KEY`, `FIREBASE_APP_ID`, `FIREBASE_MESSAGING_SENDER_ID`, `FIREBASE_PROJECT_ID`, `FIREBASE_STORAGE_BUCKET`, `FIREBASE_GOOGLE_CLIENT_ID`, `FIREBASE_GOOGLE_SERVER_CLIENT_ID`, `ILLUSTRATION_API_BASE_URL`. macOS has its own Firebase registration and `FIREBASE_GOOGLE_MACOS_CLIENT_ID`; iOS still needs its own `FIREBASE_GOOGLE_CLIENT_ID`. Regenerate the defines for the selected environment before switching builds.

- `--dart-define=FIREBASE_APP_CHECK_DEBUG=true` uses a registered App Check debug token on the iOS simulator or macOS in development. Never set it in release builds.
- Protected generation on macOS requires macOS 14+ and a supported installation producing valid App Check tokens; OS version and signing alone do not establish App Attest support. Local reading works on older systems.
- Illustrations sign in with Google only when the reader taps the illustration control, and need per-book consent before chapter prose is uploaded. Configure the native Google OAuth client, Firebase Authentication, App Check/App Attest, and the services in [`backend/README.md`](backend/README.md) before enabling the server-side rollout flag.
- Illustration source availability is server-owned. Provider keys never enter Flutter or request bodies; the selected generator receives a scene prompt and up to two prior artworks, while OpenAI performs normalized chapter analysis and moderation. No EPUB is uploaded. Every successfully published image costs one illustration credit; failures do not silently switch sources.
- Local macOS builds need development signing and a matching provisioning profile for the Keychain groups used by Google sign-in.

### Headless iPhone builds and private QR installation

A paid Apple Developer Program membership permits Ad Hoc installation on registered iPhones without a live Xcode connection. Tailscale provides private HTTPS downloads only.

Select the full Xcode globally (Dart native build hooks need to find its SDK; per-command `DEVELOPER_DIR` may not suffice):

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
xcrun --sdk iphoneos --show-sdk-path
brew install cocoapods qrencode
```

Create a distribution key and CSR once. Do not overwrite an existing key: Apple's certificate must match the key that made its CSR. Keep all credentials in the ignored `.credentials/` directory with owner-only permissions:

```sh
mkdir -p .credentials
chmod 700 .credentials
openssl req -new -newkey rsa:2048 -nodes \
  -keyout .credentials/ios-distribution.key \
  -out .credentials/ios-distribution.csr -subj "/CN=Reader Build"
chmod 600 .credentials/ios-distribution.*
```

In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources):

1. Create an **Apple Distribution** certificate from the CSR; save it as `.credentials/ios-distribution.cer`.
2. Register App ID `com.leafmealone.reader` with **App Attest** (enable it before generating the profile; a profile downloaded earlier lacks the production entitlement and Xcode rejects it).
3. Register the iPhone's UDID (from Finder or Xcode; not the serial or IMEI).
4. Create an **Ad Hoc** profile for that App ID, certificate, and iPhone; save it as `.credentials/ReaderAdHoc.mobileprovision`.

Import the certificate and key into a dedicated build keychain (one-time, in an interactive **Bash** SSH terminal). Passwords stay in local shell variables, never in files or chat; tracing must be off. The search-list update preserves existing keychains.

```bash
set +x
openssl x509 -inform DER -in .credentials/ios-distribution.cer \
  -out .credentials/ios-distribution.pem
openssl pkcs12 -export -legacy -inkey .credentials/ios-distribution.key \
  -in .credentials/ios-distribution.pem -out .credentials/ios-distribution.p12
chmod 600 .credentials/ios-distribution.*
read -rsp "P12 export password: " P12_PASSWORD; echo
read -rsp "New build keychain password: " KEYCHAIN_PASSWORD; echo
KEYCHAIN="$HOME/Library/Keychains/reader-build.keychain-db"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import .credentials/ios-distribution.p12 -k "$KEYCHAIN" \
  -P "$P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
EXISTING_KEYCHAINS=()
while IFS= read -r entry; do
  entry="${entry#*\"}"; entry="${entry%\"*}"
  EXISTING_KEYCHAINS+=("$entry")
done < <(security list-keychains -d user)
security list-keychains -d user -s "${EXISTING_KEYCHAINS[@]}" "$KEYCHAIN"
unset P12_PASSWORD KEYCHAIN_PASSWORD
security find-identity -v -p codesigning
```

If the keychain has locked, unlock it before later builds (no GUI dialog):

```bash
set +x
read -rsp "Build keychain password: " KEYCHAIN_PASSWORD; echo
security unlock-keychain -p "$KEYCHAIN_PASSWORD" \
  "$HOME/Library/Keychains/reader-build.keychain-db"
unset KEYCHAIN_PASSWORD
```

`security` takes passwords as process arguments: use only on a trusted build Mac and never enable command tracing. No Apple Account GUI sign-in or App Store Connect API key is needed for manual signing.

The tool also supports a preconfigured `~/Library/Keychains/reader-ota-build.keychain-db`; if its password is in `.credentials/ios-build-keychain.password` (current-user-owned, owner-only permissions; never commit, print, or share), builds unlock it automatically. Existing keychains and passwords are not modified.

Build and publish the installer, substituting the Mac's Tailscale DNS name (add `--defines .dart-defines/dev.json` to enable cloud features; local reading does not need it):

```sh
python3 tool/build_ios_ota.py \
  --profile .credentials/ReaderAdHoc.mobileprovision \
  --base-url https://YOUR-MAC.YOUR-TAILNET.ts.net:8443
```

- The tool installs the profile for Xcode, temporarily applies manual signing to Runner only, builds a release IPA, and publishes it under `build/ota/site/`. It rejects expired, development, and App Store profiles and never publishes a stale IPA after a failed export.
- Each build increments the number after `+` in `pubspec.yaml`'s `version:` and passes it as `--build-number`; commit the bumped `pubspec.yaml`. The number is consumed once an IPA is exported, even if publishing fails. `--ipa /path/to/export.ipa` republishes an existing Ad Hoc export without rebuilding or changing the number.
- The installation page, `manifest.plist`, and QR code are always served from `<base-url>/`, so the QR stays valid across builds. Each build adds an immutable `<build-id>/reader.ipa` and atomically repoints the page and manifest; older builds are kept. Responses use `Cache-Control: no-store` (restart `--serve` after updating the tool).
- `.credentials/ios-signing.xcconfig` is removed on exit; if the process is killed, delete it before the next build.

Keep the installer server running (it binds loopback and serves Apple's XML manifest MIME type), then expose only the generated site through private HTTPS from another terminal:

```sh
python3 tool/build_ios_ota.py --serve
/Applications/Tailscale.app/Contents/MacOS/Tailscale serve \
  --bg --https=8443 http://127.0.0.1:8765
```

If Serve is disabled, approve the setup URL Tailscale prints. Do not use Funnel unless you intend public hosting. On a phone in the same tailnet, scan the QR, open the page in Safari, and tap **Install on iPhone**. Keep the Mac awake until installation finishes; `--bg` persists the proxy but not the Python server.

The site contains only installer assets and IPAs, but an IPA includes its signed provisioning profile: restrict access to trusted tailnet members. Adding another phone requires registering its UDID and regenerating the profile. Stop the endpoint without disturbing other Serve endpoints with:

```sh
/Applications/Tailscale.app/Contents/MacOS/Tailscale serve --https=8443 off
```

### Native integration tests

`integration_test/reader_test.dart` registers independent **Library**, **Reading**, **Reader controls**, **Page flip**, **Narration**, **Accounts**, **Settings**, and **Text selection and dictionary lookup** groups from `integration_test/scenarios/`. Each test builds its own temporary catalog via `integration_test/support/native_test_app.dart` and cleans up even on failure. Import, storage, rendering, and audio playback are real; picker, preferences, and cloud services are fakes. EPUB fixtures live in `test/fixtures/`. Screenshots go to the test app's temporary directory and their paths are printed; on iOS add `--no-uninstall` to keep them after the run.

```sh
flutter test integration_test/reader_test.dart -d macos --plain-name 'Reader controls'
flutter test integration_test/reader_test.dart -d <ios-simulator-id> --plain-name 'nested EPUB contents'
```

Without a Mac App Development profile, offline scenarios can be built with command-local signing overrides:

```sh
env FLUTTER_XCODE_CODE_SIGNING_ALLOWED=NO \
  FLUTTER_XCODE_CODE_SIGNING_REQUIRED=NO \
  FLUTTER_XCODE_CODE_SIGN_IDENTITY=- \
  flutter test integration_test/reader_test.dart -d macos
```

This does **not** validate Google Keychain access, App Check, or a signed distribution. Never export these overrides globally or use them for release/OTA builds. Dictionary scenarios need a visible, active native Flutter window; otherwise the bridge reports `No active Flutter view`.

The **Narration** group exercises the retained on-device (Apple) provider directly, independent of the build switch, plus fake cloud generation for cloud/privacy regressions. Run: `flutter test integration_test/reader_test.dart -d <device> --no-uninstall --plain-name Narration`. Physical-device listening, background/locked continuation, media controls, interruptions, multilingual quality, and latency still need a connected signed device.

### Golden tests

Library, Settings, and narration-control baselines live in `test/goldens/` (from `test/library_theme_test.dart`, `test/settings_test.dart`, `test/narration_reader_test.dart`). After intentional design changes, regenerate with `flutter test <file> --update-goldens`, then inspect every changed image before committing.

Baselines were refreshed with Flutter **3.47.7** (engine `deb287481e3ce9468f3434937ced4240a70539ca`), Dart **3.13.5**, and **macOS 27.0.1 / 26A434 on arm64**. Use that environment and the software Skia renderer (`flutter test --no-enable-impeller`) for exact pixel comparison; widget platform overrides do not replace the host renderer. A new engine or host may change glyph-edge rasterization: review each pair before refreshing, and keep exact comparison rather than adding a tolerance.

### Performance profiling

Debug builds and iOS simulators are not performance evidence. Profile with `flutter run --profile -d macos` (or a physical iOS device) and [DevTools](https://docs.flutter.dev/perf/ui-performance), judging UI and raster times separately against the frame budget. Prefer removing redundant work over adding caches; optimize only paths that miss frames or account for at least 10% of frame time or allocations, and preserve complete narration/reading anchors, first-frame restoration, paragraph semantics, and end-of-book completion. (A lazy-list optimization was rolled back because narration-anchor verification failed.)

The reusable native profiler imports a fixed 300-paragraph mixed-script EPUB into a fresh temporary catalog and, in two repetitions (first-use and warmed costs are never pooled), measures library → open → twelve 450-px scrolls → eight page turns → contents navigation, with fake picker/preferences/cloud and real parsing, storage, routes, and rendering. It uses `benchmarkLive`; each gesture must advance its logical anchor.

```sh
PROFILE_LABEL=baseline flutter drive --profile -d macos --no-dds \
  --target integration_test/performance_test.dart \
  --driver test_driver/performance_test.dart
```

Use a new label after each code change with the same device/window/settings; omit `PROFILE_LABEL` for a timestamp. Labels are 1–96 letters, digits, underscores, or hyphens, and existing captures are never overwritten. Replace `macos` with a physical iOS device ID if needed; keep the macOS app frontmost. The runner rejects debug/release mode and is not part of `reader_test.dart` or the normal suite.

Output goes to Git-ignored `build/performance/<label>/`: `raw.json` (workload/device metadata, completion flag, per-phase VM timelines, CPU samples, raw frame timings), `summary.json` (per-phase frame count, UI/raster/total median, p95, max, and over-budget counts), and `<phase>_<repetition>_timeline.json`. The budget uses the display refresh rate (or a flagged 60 Hz reference). There is no pass/fail timing threshold; correctness failures or missing data fail the run, and a failed run's data is saved with `complete: false` and must not be compared. A three-minute host timeout excludes build time. Compare captures only when fixture hash, device, OS/Flutter version, window, scale, refresh rate, and settings match; record the device and `flutter --version` alongside them.

## Organization

- `lib/catalog/`: catalog records, serial imports, recency, complete text-position persistence, serialized atomic catalog writes.
- `lib/preferences/`: device-local reader settings with serialized persistence and native-audio application queue. `lib/importing/`: selection, isolated parsing, hashing, atomic import staging.
- `lib/text/`: shared normalized document pipeline, EPUB/TXT parsing, direction detection, lazy section loading, logical navigation. `lib/text/layout/` owns measured section painters (at most two section layouts retained; curl turns keep at most two page textures).
- `lib/app/reader_controller.dart` is the single shared `ChangeNotifier` coordinating catalog, preferences, illustrations, narration, and account transactions; feature coordinators do not import it or each other. `lib/app/reader_app.dart` owns theme/lifecycle/Settings routing; `lib/main.dart` runs it.
- `lib/identity/`: shared lazy Google/Firebase identity. `lib/account/`: usage coordinator, API interface (`api.dart`), authenticated transport (`http_account_api.dart`).
- `lib/illustrations/`: text indexing, spoiler gating, REST, atomic sidecars, local assets, durable deletion retries.
- `lib/narration/`: registration, speech transport, private audio persistence, app-lifetime player/session, listening controls. `narration_provider.dart` (`selectNarrationProvider`) picks the provider.
- `lib/theme.dart` holds palettes; widgets under `lib/library/`, `lib/reader/`, `lib/settings/` own their screen's state and callbacks.
- Tests: doubles/helpers in `test/support/`, values in `test/fixtures/`; tests never import other test entrypoints. `integration_test/support/frame_summary.dart` is shared by the profile driver and its tests.
- Handwritten Dart files stay under 1,000 lines, one focused component per file; callers import declarations directly (no compatibility exports or `part` splits). The sole exception is `lib/text/direction.dart`, generated by `tool/generate_direction.py` from Unicode 17.0.0.
- `backend/src/index.ts` composes API, worker, auth, rollout gates, and task delivery; `backend/src/illustration-worker.ts` runs illustration jobs (credits, moderation, asset publication/cleanup); `backend/src/openai.ts` holds provider logic; narration and account services are separate.

Lora and DM Sans are bundled under the SIL Open Font License; other notices are in `THIRD_PARTY_NOTICES.md`.

## Google accounts

Settings → Account signs in with Google independently of cloud generation; signing in does not enable illustrations or upload prose. Reading and importing remain account-free; cloud requests require authentication and App Check. Sign out clears Google and Firebase sessions without touching local books. Account deletion reauthenticates the same Google user and needs a successful cloud purge before deleting the Firebase identity or clearing illustration consent, narration registrations, and audio; if the purge endpoint is missing or fails, those local records stay intact. Local books and reading positions survive deletion.

Deploy authentication with `tool/deploy_backend dev --scope core` after configuring Google OAuth clients; it needs no OpenAI key or feature API. Supply the web OAuth credentials privately via `TF_VAR_google_client_id` and `TF_VAR_google_client_secret` and never commit them ([infrastructure setup](infra/README.md)). Build with `--dart-define-from-file=.dart-defines/dev.json` after generating the matching iOS/macOS callback settings. Google sign-in replaces Apple authentication; native Firebase registrations and App Attest remain.

## Settings and usage

Settings is single-pane on iOS (including tablets); macOS uses a sidebar at widths of at least 700 px with text scale at most 1.5, otherwise compact navigation.

Voice and listening speed are global across books; Settings and the listening sheet edit the same values. Speed changes apply immediately without regenerating audio. Changing voice pauses playback, invalidates the old audio offset, and waits for Play. Saved voices unavailable in the active provider stay visibly unavailable until replaced, but other preference edits still work. Sidecar voice values identify cached/resumable audio, not per-book overrides. At startup a saved `apple:` voice is migrated to the cloud default when the active source is cloud (and a saved cloud voice to the Apple default when it is on-device).

Library filter/sort defaults are saved separately from temporary choices. Reset preferences restores app-wide defaults without deleting books, account, illustration consent, registrations, or caches. Clearing narration audio stops playback and invalidates audio resume offsets while preserving books, registrations, and text anchors.

Usage & allowance shows only server-reported balances (including outstanding reservations) and unavailable/offline states otherwise. The read-only `/api/account/usage` endpoint requires Firebase Auth and App Check even while generation is disabled; viewing it neither initializes credits nor registers books. A core-only build can sign in and change local settings without an API deployment.

## Listening to books

The Listen toolbar action opens listening controls. The provider is chosen by `selectNarrationProvider` in `lib/narration/narration_provider.dart`:

- **Cloud (default on iOS and macOS):** opening the controls registers the book when needed; cloud requests need Google sign-in and valid App Check. Narration has no consent dialog (illustration consent is unchanged). Only cloud controls show generation allowance and cloud-account actions. The server stays gated by `NARRATION_ENABLED` (default false), so generation is refused until the backend flag is on; see [backend configuration](backend/README.md#ai-narration-disabled-by-default).
- **Apple on-device (iOS only, disabled by default):** the Apple voices were judged too poor to ship, but the implementation is retained. Re-enable with `--dart-define=ON_DEVICE_NARRATION_ENABLED=true`. It synthesizes locally with installed ordinary Apple voices: no sign-in, App Check, registration, or allowance, and errors never fall back to cloud. Short first sentence clips start playback early; overlong sentences split near 300 UTF-16 units at clause, whitespace, or grapheme boundaries. iOS highlights native word bounds only where marker offsets are verified for the voice, OS, and PCM format (verified on the iOS 27.0 simulator with Samantha, mono Float32/22,050 Hz); otherwise it uses native-tokenized sentence fallback, never estimated word times.

Both providers support 0.75–2× speed, chapter selection, play/pause, ±15-second seeking, and local cache clearing; macOS highlights at paragraph granularity. Guarantees are in [AGENTS.md](AGENTS.md#narration-guarantees); highlights:

- The themed sheet appears before attachment/registration finishes, shows loading inline, and keeps recoverable errors and Retry beside the transport controls.
- Range painting clips to measured glyph boxes (RTL and page fragments included). Silent following keeps the cue visible without committing progress or curling the page. Pausing or buffering removes the highlight. Playing/paused/buffering status stays in reserved bottom chrome, even with controls hidden, and never resizes the viewport.
- One audio handler continues playback in the library and while locked; the library has a mini-player. Opening another book or navigating manually pauses narration and invalidates the old audio offset. The native service initializes once per Flutter engine; closing a controller stops its audio and unbinds callbacks without replacing the shared handler.
- Listening starts at the committed logical position. Read from here instead starts at the selection's paragraph, continues to the end of the book, replaces prior audio, and discards its offset, without changing the catalog anchor merely by starting.
- Only naturally completed chunks advance prose or unlock illustrations. Downloads, prefetch, seeking, following, and highlighting never advance progress; after seeking, replay from the committed passage to grant completion. Pausing restores the committed listening anchor. Interrupted chunks keep the complete committed position separate from playback start, chunk identity, and audio offset.
- Cached replay works offline and uses no cloud allowance; a 250 MiB LRU bounds audio and timing companions, pinning the active clip plus at most two lookahead clips. Speed changes reuse audio; voice changes synthesize new speech. Interrupted audio offsets are invalidated when the engine, sentence policy, OS synthesis identity, or voice changes; complete anchors survive.
- The macOS sheet's Cloud account menu supports signing out and deleting cloud data; Settings keeps shared account/privacy actions on both platforms. Deletion purges server data first, then clears narration audio, preserving local books and reading positions.
