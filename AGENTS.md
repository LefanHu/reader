# Repository guidance

## Vision

Turn any book you own into an illustrated, narrated edition. Analysis learns the characters and places so art stays consistent across the book; the Decisions API picks the scenes worth illustrating; narration reads it aloud. Generating that enrichment needs the network, but reading never waits on it: books, positions, and art or audio already downloaded stay available offline and without an account. The reader itself must be excellent, because the enrichment is only worth it on top of a reading experience people would choose anyway.

## Purpose and priorities

- Personal development project: no real users, no production data, everything may change.
- Priorities, in order: **robust and reliable**, then **simple and lightweight**, then everything else. Security and privacy are deliberately minimal for now (see below).
- Prefer deleting code to adding it. No speculative abstractions, options, feature flags or defensive layers for problems that do not exist yet. A new abstraction must remove duplication that exists today.
- Change things in place. No versions of anything (schema/format/protocol/API-path fields, versioned identifiers, "v2" copies), no migrations, compatibility readers, legacy fallbacks or transition flags. Old local or dev data that no longer parses is treated as absent. Exception: Terraform `moved` blocks, deleted once dev has applied them.
- Important notes belong in this file. Keep it short; it states rules, not implementation detail the code already shows.

## Robustness

- Expect failure from the network, cloud services, model providers and disk. Auxiliary features (illustrations, analysis, narration, accounts) never interrupt reading or crash the app; they show a retryable error.
- Persist with `AtomicJsonFile` (atomic replace, serialized per file). A malformed record drops only that record, never the whole file.
- Async work that can outlive its owner (book deleted, account changed, newer request) captures a `GenerationFence` ticket and checks it after every await before writing state.
- Background work never prompts sign-in; it uses an existing session or waits.
- Bound everything that can grow: imported file and archive sizes, request bodies, provider output, timeouts, retries, queue depth and caches.
- Book files (EPUB/TXT) are arbitrary input: parse off the UI isolate, enforce size/encoding limits, reject what cannot be rendered, and commit only fully validated imports (staged, SHA-256 deduplicated).
- Backend workers are idempotent. A busy lease answers 409 (never 204, which drops the only retry). `WORKER_LEASE_MS` exceeds the worker request timeout, dispatch deadlines equal it (`backend/src/fences.ts`), and queue retry backoff outlasts the lease.
- Fix root causes, and add a regression test for every bug fixed.

## Security and privacy (relaxed for development)

Keep — cheap, and protects keys and money:
- Secrets are never committed, printed, logged or bundled. OAuth credentials live in the Git-ignored `.credentials/`; the OpenAI key exists only on the worker.
- Firebase Auth on every user-specific route; users only reach their own data.
- Spend limits on paid generation (illustration credits, narration allowance), and `DevApiClient` blocks paid routes in tests.

Not required — do not add, and simplify or remove when touching the code:
- App Check/App Attest gating, per-component symlink hardening beyond simple containment in the app directory, deletion tombstones and privacy outboxes, server-first deletion ordering, consent ceremonies, rollout flags, sanitized-logging rules beyond secrets.

Before any external release, revisit: App Check, deletion/privacy guarantees, consent, and the rollout flags.

## Architecture

- Dart: keep handwritten files under 1,000 lines with headroom (`lib/text/direction.dart` is generated and exempt). One focused file per component; owned private helpers may sit beside it. Direct imports only: no barrels or `part` files.
- `ReaderController` owns cross-feature transactions. Feature coordinators (catalog, preferences, illustrations, analysis, narration) own their state and never import the controller, the UI or each other. `createProductionController` (`lib/app/production_controller.dart`) is the only composition root.
- One text pipeline: `lib/text/` produces the normalized `TextDocument` with stable block IDs that rendering, narration, illustrations and analysis all consume.
- Reading positions are complete `TextPosition`s (section ID, block ID, UTF-16 offset on a grapheme boundary). Reflow and mode changes restore the logical anchor, never pixels or page numbers.
- Backend (Express on Cloud Run, Firestore, Cloud Tasks): reuse `http.ts` (`HttpError`, `httpErrorHandler`, `require*`), `openai-client.ts`, `signed-urls.ts`, `durations.ts` and `fences.ts` rather than adding parallel helpers.
- Infrastructure: one Terraform owner per resource and API enablement. Stacks are `bootstrap`, `foundation` (core, auth, shared data, monitoring), `illustrations` (feature resources) and `runtime` (API/worker deployments). Use `tool/deploy_backend <env> --scope core|illustrations|all` and `tool/plan_infra`; a scope never destroys an omitted stack.

## Product behavior

- Reading works offline and without an account.
- Page turns: curl previews never change position, progress or persistence; only completed turns commit. Unfinished turns cancel on reflow, navigation, suspension and exit. At most two section layouts and two page textures exist.
- Hidden toolbar (60px) and bottom bar (62px) keep their space, so showing or hiding them never moves the text. Hidden controls take no pointer, focus or accessibility input.
- Honor reduced motion, paragraph semantics, keyboard navigation, RTL logical navigation and large accessibility text. Colors come from `lib/theme.dart` and the active `ColorScheme`.
- Library: macOS uses cover grids, iOS uses list rows at every width; the 700px breakpoint only controls the sidebar.
- Settings are device-global. Settings and the listening sheet edit the same voice/speed preferences.
- Narration: one app-lifetime audio handler. Only natural completion of a chunk commits reading progress; starting, seeking or "Read from here" never does. Segment only the normalized text (`lib/text/narration.dart` for cloud, `lib/text/sentence_narration.dart` for Apple). Cloud narration is the default; on-device Apple narration is behind `--dart-define=ON_DEVICE_NARRATION_ENABLED=true`. Cached replay is free.
- Illustrations: the Decisions API picks scenes per chapter window; only those paragraphs reach image generation. Art renders inline after its anchor paragraph; anchors that do not resolve in the normalized text never render.
- Text identity: every book is identified automatically, in the background while signed in, as a shared text by its paragraph fingerprints alone (no titles, no UI). Lookup is a bottom-30 fingerprint sketch query, then a book joins a candidate only at ≥90% alignment, otherwise it starts a new text. No book text is stored; shared texts are global and not purged on user deletion (revisit before release).
- Book analysis runs in the background for every book, never prompts sign-in and never spends credits; illustration requests wait for a book's analysis to complete.

## Platform notes

- Initialize Firebase and Google sign-in lazily; Google is the only sign-in. Google sign-out clears Firebase even if native logout fails.
- Narration storage checks start at the OS-provided app home; never `lstat` above it (a physical device may deny it and fail startup).
- `NativeNarrationPlayer.create` keeps one engine-lifetime service; never reinitialize `AudioService`.
- The App Attest entitlement is iOS-only; macOS profiles reject it. Keep macOS Keychain/network entitlements and development signing.

## Subagents

- Exploration subagents (searching, reading, mapping code, answering "where/how does X work") run on Sonnet 5.5 (`model: sonnet`, `claude-sonnet-5-5`), not Opus. Use Opus only for subagents that implement changes or need hard reasoning (design, review, debugging).
- Give each subagent a self-contained prompt: goal, files or areas it owns, constraints from this file, the validation it must run, and the report format.
- Parallel subagents own disjoint files. A worktree subagent must branch from the current working branch, not `main`; confirm with `git merge-base` before merging its work.
- Review every subagent diff and rerun the validation yourself before applying it. Subagent reports are claims, not evidence.
- Subagents never deploy, apply cloud changes, push, or commit to the working branch; the main session does that when asked.

## Development cycle

1. Implement the change and get it passing validation (see Testing and validation).
2. Simplify: run the `code-simplifier:code-simplifier` agent on the code changed in this cycle (name the files or diff; not the whole repo). It must preserve behavior and follow this file.
3. Review the simplifier's diff like any subagent output, discard edits that change behavior or add abstractions, then rerun the full validation.
4. Commit, deploy or build only when asked.

## Comments

- Document non-trivial types, public members, service boundaries and persisted fields. Comments explain why, invariants, lifecycle and ordering that is easy to break; never narrate syntax. Update them in the same change.
- Test names state behavior.

## Testing and validation

- Dart changes: `dart format lib test integration_test`, `flutter analyze`, `flutter test`.
- `flutter test` includes dev-API tests against the deployed dev backend (needs `.dart-defines/dev.json`, `gcloud auth application-default login`, membership in `api_test_principals`, and Node deps in `backend/`). Deploy backend changes to dev before expecting them to pass; those tests write only test-uid data.
- Prefer the real dev backend over fakes. Fakes are fine for paid generation and for UI states that are impractical to produce against dev (held responses, failures).
- Backend changes: `npm run build` and `npm test` in `backend/`.
- Infra/tooling changes: `python3 -m unittest discover -s tool/tests -v`, `terraform fmt`, `terraform validate` and mocked `terraform test`, and ShellCheck. Validation never applies cloud changes; deploy only when asked.
- Shared reader/library changes: run the affected native scenarios on an iOS simulator (`integration_test/reader_test.dart` registers groups for `--plain-name`; scenarios live in `integration_test/scenarios/` and use `integration_test/support/native_test_app.dart`). Each scenario starts fresh and cleans up after itself even on failure. macOS native runs are not required while the host cannot build macOS.
- Check behavior with automated assertions (positions, clipboard, platform calls), not screenshots. After intentional visual changes, regenerate and inspect the affected goldens (Paper, Sepia, Dark; iOS lists and desktop grids); never accept baselines just because tests pass.
- Performance runs are opt-in: `flutter drive --profile --no-dds` with `integration_test/performance_test.dart`; compare only runs with matching fixture, device and settings.
- On feature completion, give a copyable `qrencode -t ANSIUTF8 '<OTA installation-page URL>'` for the latest successfully built and hosted installer, or say that none is fresh.

## iOS OTA installer builds

"Create a new build" / "http serve build" means an Ad Hoc IPA published to the tailnet installer page:

```sh
python3 tool/build_ios_ota.py \
  --base-url https://lefans-mac-mini.tailf6a70a.ts.net:8443 \
  --profile .credentials/ReaderAdHoc.mobileprovision \
  --defines .dart-defines/dev.json
```

- Takes several minutes; run it in the background and log to the scratchpad. It unlocks the dedicated build keychain itself (`.credentials/ios-build-keychain.password`), builds with the dev cloud defines, bumps the build number in `pubspec.yaml`, and publishes to `build/ota/site`. Commit the `pubspec.yaml` bump with the next commit.
- Serve it (loopback port 8765), detached so it outlives the session; skip if `pgrep -f "build_ios_ota.py --serve"` already finds it:
  `nohup python3 tool/build_ios_ota.py --serve > <scratchpad>/ota-serve.log 2>&1 &`
- Tailscale already proxies `https://lefans-mac-mini.tailf6a70a.ts.net:8443` to it (`Tailscale serve status`); only if missing run `/Applications/Tailscale.app/Contents/MacOS/Tailscale serve --bg --https=8443 http://127.0.0.1:8765`.
- Verify with `curl -s -o /dev/null -w '%{http_code}' https://lefans-mac-mini.tailf6a70a.ts.net:8443/manifest.plist` (expect 200), then give the user `qrencode -t ANSIUTF8 'https://lefans-mac-mini.tailf6a70a.ts.net:8443/'`.
- `--ipa <path>` republishes an existing Ad Hoc export without rebuilding. The installer page URL is stable across builds.
