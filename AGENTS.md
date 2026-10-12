# Repository guidance

## Comments and documentation

- Document every new or materially changed non-trivial type, public member, service boundary, and persisted field.
- Comments explain purpose, invariants, lifecycle, platform constraints, security decisions, or why; never narrate obvious syntax. Keep them next to the code and update them in the same change.
- Preserve documentation of EPUB trust boundaries, atomic catalog writes, complete text-position persistence, and platform support; these are product guarantees.
- Add short comments in complex private flows where cleanup, ordering, recovery, accessibility, or responsive breakpoints are easy to break.
- Test names state behavior; comment inside tests only to protect a non-obvious regression.
- Important notes belong in this file.

## Dart organization

- Keep every handwritten Dart file under 1,000 lines with headroom. Only `lib/text/direction.dart` (generated Unicode table) is exempt; do not split it or alter its generator.
- One focused declaring file per component. Pair widgets with their private State; owned enums, typedefs, helpers and small single-test fixtures may sit beside their owner. Use direct imports: no barrels, compatibility exports, or `part` splits.
- `ReaderController` is the sole shared notifier and cross-feature transaction owner. Catalog, preferences, and illustration coordinators own authoritative state and live callbacks; they never import the controller, UI, or each other.
- `SectionLayout` owns measured painters; `PageTurn` owns its two-or-zero images. Navigation attaches live callbacks only during viewport lifecycle transitions and detaches only the identical owner. Borrowed targets, lines, slices and painters never dispose these resources.

## Reader and interface invariants

- Rendering and illustration indexing consume the same normalized `TextDocument` text and stable block IDs. Extraction and normalization live in `lib/text/`; no second text pipeline.
- Persist the complete `TextPosition`: document version, section ID, block ID, UTF-16 offset at an extended grapheme boundary. Reflow and mode changes restore the committed logical anchor, not pixels or pages; Scroll restores before its first painted frame.
- Curl previews never advance positions, progress, or persistence. Commit only completed turns; cancel unfinished turns on reflow, chapter navigation, suspension and exit. Keep the two-section-layout and two-texture limits, including disposal and stale-load rejection.
- Inline figure slots are part of section layout identity; a page starting at a figure reports the anchor block's end offset and restores to that block's last text line. Curl textures paint figures as flat placeholders.
- Reserve the toolbar's 60px and bottom navigation's 62px when controls are hidden; visibility changes leave the viewport stationary. Every toolbar button stays visible; the chapter title is centered independently of them.
- Honor reduced motion, paragraph semantics, keyboard navigation, and RTL logical navigation. Hidden controls immediately stop receiving pointer, focus, and accessibility actions.
- Library presentation: macOS cover grids with hover/focus metadata; every iOS width uses list rows. Overlay reveals are stationary, pinned while menus are open, and keep metadata semantics when hidden. The 700px breakpoint controls only the sidebar.
- Word counts come from normalized blocks, never markup or widget builds. `CatalogBook.wordCount` stays nullable for old catalogs; backfill off the UI isolate, merge into current records, never resurrect deleted books or discard reading updates.
- Use `lib/theme.dart` and the active `ColorScheme` everywhere. The saved reading theme is app-wide; font preferences affect book text only. Support large accessibility text.
- Settings are device-local and global. Library filter/sort defaults ignore temporary choices. Settings and listening-sheet voice/speed controls write the same preferences; never restore per-book overrides from narration sidecars.
- A global voice change pauses playback, fences callbacks, and invalidates the old audio offset without advancing text or generating. Speed applies immediately without generating. Sidecar voice is audio/resume identity only; reuse offsets only for the matching global voice.
- Preference reset preserves account, books, illustration consent, narration registrations and caches. Clearing narration audio stops playback, fences pending writes, keeps committed text anchors, and invalidates removed audio offsets. Delete only validated app-owned files.

## Import, persistence, and cloud boundaries

- EPUB and TXT are untrusted. Keep encoding validation, archive/markup limits, traversal protection, and rejection of DRM, scripted, fixed-layout, or remote-resource EPUBs. Parse off the UI isolate; commit only validated imports via private staging and SHA-256 deduplication.
- Keep serialized atomic writes and restartable recovery. Legacy reset durably enqueues known cloud deletions and commits the replacement catalog before deleting book directories; preferences and pending deletions survive it.
- Importing and reading stay offline and account-free. Illustration identity is shared on iOS/macOS; startup deletion retries use an existing session and never prompt sign-in. Keep illustration consent and the remote rollout flag.
- Illustration scenes are chosen by the OpenAI Decisions API over density-sized chapter windows; only the selected paragraphs reach image generation. Art downloads as soon as it is ready and renders inline after its anchor paragraph; confirmed generations show a same-size progress placeholder there; anchors that do not resolve in the normalized index never download or render. Cloud failures never interrupt reading or block local deletion; retain failed deletions for retry and treat already-deleted books as success.
- Every imported and existing book is preprocessed by default (`lib/book_analysis/`, backend `book-analysis-*`): evidence-anchored timeline, entities/mentions, world baselines and textual map. It is background-only, reuses an existing session, never prompts for sign-in, and never starts image generation or spends credits. Image intents wait for a complete generation of the same `documentVersion`; scene context carries only facts applicable at the depicted story time and revealed by the scene end (vetted world facts may be retroactive). Model accuracy is unmeasured without a paid live run.

## Backend infrastructure

- One environment project, Firebase Auth service, and Firestore database. `foundation` owns core/auth/shared data/monitoring; `illustrations` owns feature infrastructure; `runtime` owns API/worker deployments; bootstrap is separate.
- Use `tool/deploy_backend <environment> --scope core|illustrations|all` and matching `tool/plan_infra` scopes (default all). Core works without OpenAI credentials or Node. Scope never destroys an omitted stack and is independent of illustration rollout.
- Each API enablement and resource has one Terraform owner. Migrate existing foundation feature ownership with `tool/migrate_backend_state` before split plans/applies: maintenance window, preserve instance records and generated secrets, commit destination first, never force-push.
- After infra/tooling changes run `python3 -m unittest discover -s tool/tests -v`, Terraform validation/mocked tests, formatting checks, and ShellCheck. Validation never applies cloud changes.

## Integration tests

- `integration_test/reader_test.dart` only registers feature groups; scenarios live in `integration_test/scenarios/`, named for focused `--plain-name` runs.
- Each scenario runs independently with a fresh catalog and preferences, using `integration_test/support/native_test_app.dart` for setup, navigation, screenshots and teardown. Reusable document builders go in `test/fixtures/`; never import another `*_test.dart`.
- Register cleanup before initialization, unmount the app before the final persistence flush, delete only the fixture's temp directory, and release gestures and captured images even on failure.
- Use `NativeTestApp.runWithFrames` for native actions awaiting logical viewport restoration. Keep the macOS test app frontmost; use iOS `--no-uninstall` to keep screenshots.
- Widget fixtures with narration unmount before `disposeControllerWithFrames` (`test/support/controller_lifecycle.dart`); do not keep idle completed fake-zone futures in shared queues.
- Native scenarios cover complete flows with real import, storage and rendering; parsing and layout edge cases belong in unit/widget tests.
- Performance runs are opt-in (`integration_test/performance_test.dart`, `test_driver/performance_test.dart`) via `flutter drive --profile --no-dds` on macOS or physical iOS. Compare matching fixture/device/window/settings metadata and phase names, preserve reset-to-start anchors, exclude setup/artifact I/O, mark failed captures incomplete, and keep every sampled stack's function attribution in CPU compaction.

## Validation

- After Dart changes run `dart format lib test integration_test`, `flutter analyze`, and `flutter test`.
- For shared reader/library changes run affected native scenarios on an iOS simulator when available; for platform integration changes build or run the platform. macOS native scenarios are not required while the build host cannot build the macOS target.
- Behavioral changes (selection, dictionary lookup) are checked by automated native interaction, clipboard, platform-call and committed-position assertions, not screenshots or screen recording.
- After intentional visual changes regenerate and inspect affected goldens (Paper, Sepia, Dark; iOS lists and desktop grids, including revealed overlays); never accept baselines just because tests pass.
- Run `npm run build` and `npm test` in `backend/` when backend behavior changes.
- On feature completion give a copyable `qrencode -t ANSIUTF8 '<OTA installation-page URL>'` command using the latest successfully built and hosted installer; if none is fresh, state that instead of presenting an old build.

## Cloud identity

- Google is the only interactive sign-in. The library account action is independent of illustration consent, narration registration and feature API availability; core-only builds authenticate without an OpenAI key or worker. Firebase users and local books survive provider retirement.
- Initialize Firebase and Google lazily. Sign-in does not need App Check; protected feature requests need a Firebase ID token and App Check token. Google sign-out clears Firebase even if native logout fails.
- Native Google callbacks must match the platform OAuth client and Firebase project. Generated client IDs and callback settings are public config in ignored private files; the OAuth web secret never enters Dart defines, bundles or committed files.
- Keep OAuth credentials in the Git-ignored `.credentials/` directory, owner-only. Pass secrets privately to deployment; never print them or log them.
- Reauthenticate the same Firebase user before server account deletion. Purge remote feature data before deleting the Firebase identity or clearing local consent, registrations and audio. Preserve local books and reading positions.

## Narration

- Provider choice is `selectNarrationProvider` in `lib/narration/narration_provider.dart`. Apple on-device narration is off by default (voices judged too poor); iOS uses cloud like macOS. Re-enable with `--dart-define=ON_DEVICE_NARRATION_ENABLED=true`. Startup rewrites a saved `apple:` voice to the cloud default when cloud is active. Native integration scenarios build the Apple source directly, independent of the switch.
- Cloud narration is gated server-side by `NARRATION_ENABLED` (default false); cloud controls register books when needed and require Google sign-in and valid App Check. Production macOS cloud narration needs macOS 14+ and an installation that produces valid App Check tokens; verify distribution before rollout. Unsupported installs keep local reading and cached audio.
- On-device (when enabled): installed ordinary Apple voices, no authentication, App Check, registration, quota, or cloud fallback; no Personal Voice, recording, or speech-recognition permission. Local iOS listening omits cloud account/allowance controls; Settings keeps privacy actions. Switching to Apple must not erase cloud receipts, deletion outboxes, or server-first deletion.
- Keep the App Attest entitlement in iOS only; macOS profiles reject it. Preserve macOS Keychain/network entitlements and development signing. Protected generation fails closed without valid attestation.
- Segment only the normalized `TextDocument`: cloud protocol-v1 chunks in `lib/text/narration.dart`, Apple sentence units in `lib/text/sentence_narration.dart`. Preserve exact prose, block identities, complete start/end positions and grapheme boundaries. Local clips: 300 UTF-16 soft target, 3,000-unit hard bound; reject an oversized grapheme; never invent silent clips or completion.
- One app-lifetime audio handler. Returning to the library or locking preserves playback; opening another book or manual navigation pauses it. Read from here starts at offset zero of the paragraph containing the first selected character, replaces prior playback, and continues through the book. Selecting or starting playback never commits the catalog anchor; persist a separate complete playback start. Only natural chunk completion commits progress; seeking never grants completion (replay from the committed anchor first). Suppress viewport writes while listening; await silent viewport restoration on pause. Never persist page numbers, pixels or partial anchors.
- `NativeNarrationPlayer.create` keeps one engine-lifetime service; session disposal stops/unbinds it and never reinitializes `AudioService`. Speed-only changes update native playback-state speed immediately.
- Apple synthesis: one engine-owned buffer synthesizer; stream PCM16 WAV at source rate/channels to validated private staging (explicit WAVE for `.wav.tmp`); bound jobs, output, timeout and queue depth; cancel native work outside store serialization and fence late callbacks. Word/sentence timing comes only from verified utterance-relative Apple markers expanded to complete graphemes, else sentence fallback; never estimate word times. The reader owns one cue-boundary timer on the actual player clock and clears presentation on pause, stall, background, library exit or detachment. Cue following never commits or turns pages.
- Narration storage validation starts at the OS-provided app home and checks every app-controlled component below it. Never `lstat` ancestors above the sandbox (a physical device may deny them and fail initialization before the first frame). Keep private-root containment and per-component symlink rejection.
- Versioned additive sidecars keep cloud receipts, engine/synthesis/segmentation and voice identity, legacy speed, committed anchor, playback start, chunk identity and audio offset. Global settings govern playback; restored missing Apple voices stay unavailable without blocking other settings. Identity mismatch invalidates audio offsets, never text anchors. Keep existing cloud cache keys exactly; local keys include clip/sentence/source/voice/OS/synthesis identity, never UID or speed. WAV and timing companions share ownership and the global 250 MiB LRU; pin at most the active plus two buffered clips. Missing timing never invalidates playable audio. Serialize preparation/publication and manifests, not speculative synthesis. Fence writes, callbacks, registration and deletion with session generations; await persistence before removing book directories.
- Cloud narration is `/v1/narration` behind Firebase Auth and App Check, independent of illustration credits, using `gpt-realtime-2.1-mini` via the worker's isolated, tool-free Realtime provider. Bound requests, output and timeouts; publish only bounded, nonempty, aligned 24 kHz mono WAV after successful completion. Ignore transcript metadata. The service does not verify spoken-text fidelity or acoustic quality.
- Allowance defaults: 500,000 UTF-16 units per user per UTC month, 200,000 per environment per UTC day (`NARRATION_MONTHLY_CHARACTERS`, `NARRATION_DAILY_CHARACTERS`). Cached replay is free; every submitted provider attempt consumes allowance, including failures. Release pre-submission failures, fence duplicate worker claims, cap at two attempts per chunk.
- Cloud audio is private, expires after 30 days, and uses ten-minute download URLs. Remove temporary prose on terminal completion; abandoned inputs have a 24-hour TTL. Allowance reads reclaim expired unsubmitted reservations even with rollout disabled. Book deletions stay available with rollout disabled, use existing sessions on startup, and survive legacy resets. Book/account tombstones stop delayed workers from publishing deleted assets.
- Account actions use the shared native identity on both platforms. Delete cloud data before the Firebase user; clear local registrations/audio only after successful server deletion; a missing account endpoint fails closed. Preserve books and positions and reflect actual identity even if local cleanup fails. Purge UID-owned jobs, orphan inputs and monthly usage only after releasing unsubmitted reservations; keep the account tombstone and shared daily charges.
- Account usage reads need existing Firebase Auth and App Check, ignore rollout flags, and never register books, initialize credits, reclaim reservations or submit generation. Include outstanding reservations in remaining allowance. Account changes invalidate pending snapshots; never substitute estimated balances.
- Narration reuses the existing feature stack (API ownership, identities, storage, secrets, runtime deployments) and the `core|illustrations|all` scopes and resource addresses. Never apply cloud changes during validation. Before rollout verify signed-device Auth/App Check, background/media controls, interruptions and headphone removal, and listen to multilingual prose, dialogue, numbers and instruction-like passages.
