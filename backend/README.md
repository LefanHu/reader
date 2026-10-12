# Reader backend

One container image serves the authenticated mobile API and the Cloud Tasks
worker routes. Deploy it as two Cloud Run services: a public API service
(`SERVICE_ROLE=api`) and a private worker service (`SERVICE_ROLE=worker`,
Cloud Run IAM required, reached only by Cloud Tasks via OIDC). `WORKER_URL`
points at the worker.

Commands (local only; never apply cloud changes):

```sh
npm --prefix backend ci
npm --prefix backend run build
npm --prefix backend test
docker build --platform linux/amd64 -t reader-backend-dev backend
```

## Source map

- `src/index.ts`: composition, public routes, identity, task authorization,
  rollout gates, error translation. `src/http.ts`: bounded validation and
  expected HTTP errors.
- `src/illustration-books.ts` (registration/deletion, pilot credits),
  `illustration-jobs.ts` (`/v1` profile/job routes), `illustration-scenes.ts`
  (scene delivery, regeneration, cleanup), `illustration-worker.ts` (claims,
  planning, settlement, moderation, guarded publication),
  `illustration-credits.ts`, `fences.ts` (deletion-fence lookups).
- `src/image-provider-registry.ts`: exact snapshot dispatch and centralized native
  validation (`image-generation.ts`); `image-provider-http.ts`: operation deadlines,
  bounded streams and DNS-pinned provider assets; `image-providers/`: six direct
  generation transports. `openai.ts` retains narrative analysis and moderation,
  independent of the selected image source.
- `src/narration.ts`, `narration-provider.ts`, `account.ts`: narration lifecycle
  and account routes.
- `src/illustration-worker.test.ts` runs lifecycle regressions over local HTTP
  with isolated storage and deterministic provider barriers.

## Configuration

Required: `OPENAI_API_KEY`, `FINGERPRINT_SECRET`, `GOOGLE_CLOUD_PROJECT`,
`ILLUSTRATION_BUCKET`, `TASK_LOCATION`, `TASK_QUEUE`, `TASK_SERVICE_ACCOUNT`,
`WORKER_URL`, `SERVICE_ROLE`. `ILLUSTRATIONS_ENABLED=true` opens the
illustration flag (default off). Optional: `OPENAI_SCENE_MODEL` (Decisions scene-selection model),
`OPENAI_IMAGE_MODEL`, `OPENAI_IMAGE_ORCHESTRATOR_MODEL`, `PILOT_CREDITS`.
`IMAGE_PROVIDERS` is the comma-separated deployment availability list (OpenAI
remains the initial default). Worker-only optional keys are `BYTEPLUS_API_KEY`,
`QWEN_API_KEY`, `XAI_API_KEY`, and `BFL_API_KEY`; Google uses worker ADC and
Vertex AI access, not a client API key. API availability never reads these keys.
The selected source never falls back to another provider. Operator commercial
accounts, funded billing and applicable terms remain prerequisites; Cloud
hosting is not a claim of unrestricted user eligibility.
The mobile build supplies Firebase/API values with `--dart-define`.

- The OpenAI organization behind the key must have funded API usage; a ChatGPT
  subscription does not. Successful model discovery/moderation does not prove
  generation allowance; `credit_balance_exhausted` / `insufficient_quota` is
  provider billing, not IAM. Fund the organization before replacing a key.
- Firestore: TTL on `illustrationJobInputs.expiresAt`; deny all direct client
  access to Firestore and Storage; grant service accounts least privilege.
- Bucket lifecycle deletes `users/**/scenes/**` after 30 days. Scenes carry
  `assetExpiresAt`; `/unlock` queues an uncharged refresh within 24 hours of
  expiry. Storage stays private: clients get only ten-minute signed URLs.

The immutable `reader-landscape-v1` preset requests one landscape image and at
most two private inline continuity references:

| ID | Server-owned model / hosting | Preset |
| --- | --- | --- |
| `openai` | `gpt-image-2.5-flare`, Responses orchestrator `gpt-5.5` (environment overrides snapshotted) | high, 1536×1024, opaque WebP, automatic safety, `store:false` |
| `google` | `gemini-nano-banana-2.1`, Google Cloud Vertex global endpoint / ADC | 2K, 3:2, one candidate, no grounding/tools |
| `seedream` | `seedream-4-0-250828`, direct BytePlus Singapore | 1536×1024, inline base64, no sequential generation |
| `qwen` | `qwen-image-3.0`, direct Model Studio Singapore | 1536×1024, one image, no prompt extension |
| `xai` | `grok-imagine-image-2.0`, direct xAI | 1.5k, 3:2, multi-reference edit when needed |
| `flux` | `flux-3-image`, direct BFL | 1.5k, 3:2, no grounding, safety tolerance 2 |
| `diagnostic` | `text-image-diagnostic-v1`, private Cloud Run service (dev only), no external key | 1536×1024 PNG listing the exact prompt as text; pipeline testing only |

### Pipeline test source

`diagnostic` ("Pipeline test (prompt as text)") proves the whole illustration
pipeline without a paid provider. A separately deployed Cloud Run service
(`node dist/image-test-provider-server.js`, same image; `POST /v1/render`) returns a
white 3:2 PNG showing the exact prompt the worker sent (art direction, world
state, scene facts, source scene), `references: N`, and a truncation notice for
prompts beyond 36 wrapped lines. Terraform creates it only when
`image_test_provider_enabled = true` and only in `dev`; only the worker identity
holds `roles/run.invoker`, and the worker sends a Google ID token for the service
origin (`IMAGE_TEST_PROVIDER_URL`, must be `https://*.run.app`). Select it per
book in Illustration settings and read past a scene. Scene analysis and image
moderation still use OpenAI, and each published image still spends one credit.
Run locally with `npm run image-test-provider`.

All generation operations have a 120-second deadline, including polling and
download. Connection establishment is bounded to ten seconds; synchronous
generation gets the remaining deadline rather than an artificial 30-second
response timeout. JSON is limited to 32 MiB, originals to 16 MiB and 16,777,216
pixels, references to 7 MiB each. Decoder verification requires a single
PNG/JPEG/WebP frame and oriented 3:2 within 2%. Returned asset URLs are restricted
to documented HTTPS provider hosts with public DNS pinned, no redirects or
forwarded provider credentials. A new upstream host fails closed.

Provider contracts: [Google Cloud](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/capabilities/image-generation),
[BytePlus](https://docs.byteplus.com/en/docs/modelark/image-generation-api),
[Qwen](https://www.alibabacloud.com/help/en/model-studio/qwen-image-generation-and-editing-api-reference),
[xAI](https://docs.x.ai/developers/rest-api-reference/inference/images),
[BFL](https://docs.bfl.ml/api-reference/utility/generate-an-image-with-flux-3.md).
[BFL terms §6(i)](https://bfl.ai/legal/developer-terms-of-service) require preserving
Content Credentials. No quality ranking is inferred from model documentation.

## Deployment

Terraform owns indexes, TTL, Security Rules, service identities and Cloud Run
services. Do not run `firebase deploy`; use the root entry point:

```sh
tool/deploy_backend dev
```

`--scope core` deploys accounts/shared infrastructure; `--scope illustrations`
requires core to exist already; omitting scope runs both. Existing foundation
state must migrate before either path is applied. See
[`../infra/README.md`](../infra/README.md) for state bootstrap, migration
safeguards, secrets and drift review.

### Schema-2 cutover reset

`npm run reset:illustrations -- --project P --bucket B` reports obsolete
illustration records (dry run). `--apply --maintenance` deletes them while keeping
users, tombstones, `narrationBooks`, `narrationAccountTombstones` and
`users/{uid}/narration/`. See [`../infra/README.md`](../infra/README.md).

## Illustration privacy and lifecycle guarantees

- The API never accepts an EPUB, only one normalized chapter at a time. It is
  analyzed once into append-only, paragraph-anchored entity revisions and scene
  candidates, then the prose is deleted. Image generation sees only the selected
  scene range and the world state established before it. OpenAI Responses
  storage is disabled.
- Optional absent fields (`title`, `language`, `WorldSnapshot.referenceObject`)
  are omitted, never written as `undefined`, to keep Firestore strict field
  validation on.
- Text moderation runs before image generation; image moderation before asset
  commit. Credits are reserved transactionally and charged in the transaction
  that publishes a usable scene and its world reference.
- Lease fencing: a unique claim token is checked against the current job/scene,
  book tombstone and `narrationAccountTombstones` before any history, status,
  accounting or publication write. Stale claims cannot refund newer
  reservations or touch newer objects; each attempt writes immutable
  `.claim-<token>` objects and removes its own on cancellation. An expired,
  still-owned lease returns 409 for task retry; the next claim transfers the
  reservation exactly once.
- Job documents temporarily hold a `plan` (bounded anchors, paraphrased facts,
  specs/world snapshots). Raw chapter text lives only in the 24-hour-TTL input
  until the guarded analysis commit deletes it. Terminal states remove the plan.
- Regeneration persists `regenerationTarget`, `regenerationRefresh`,
  `regenerationTaskId` and `regenerationGenerationSpec` before enqueue; retries
  (including `/unlock`) resubmit the
  same identity, cannot change paid/free intent or double-charge, and stale task
  identities cannot claim newer requests.
- Deletion: scene delete fences, refunds, removes assets, leaves a `deleted`
  tombstone (delivery 404). Book delete writes a durable tombstone first, then
  purges everything owned (profile/jobs/registration then return 410).
  `DELETE /v1/account` purges prose, jobs, scenes, history, reservations, user
  records, storage prefix and narration data, leaving only the account tombstone
  that fences delayed workers; shared daily usage keeps submitted charges.
  Firebase identity deletion is the native client's job after HTTP success.
  Deletion works with rollout off.
- The first illustration registration initializes pilot credits; later
  registrations keep balances. Deleted account/book fences reject registration
  with 410.
- Schema 2 registers salted book/job identities and rejects legacy mutation
  payloads before writes. `GET /v1/illustrations/config` requires Auth/App Check,
  stays readable with rollout off, returns all six sources and `no-store`.
- The saved book profile has a server-owned revision. No-op saves retain it;
  stale differing updates return 409. Chapter admission snapshots style,
  density, provider, exact model and immutable `reader-landscape-v1` preset.
  Queued work never rereads live preferences or model environment overrides.
- Settings apply to unscheduled chapters and paid explicit regeneration.
  Free expiry refresh retains the published recipe. Pending replacements keep
  prior assets and spoiler/reveal state until new downloads and manifest commit.
  Local `generationVersion` and paths remain committed artwork;
  `regenerating` is independent progress and `pendingGenerationVersion` denotes
  a newer ready replacement. Server `unlocked` does not bypass the device's
  ending-paragraph gate. Terminal failure clears pending progress, not artwork;
  replacing a hidden/dismissed scene never repeats automatic reveal.
- Original PNG/JPEG/WebP bytes are published unchanged with verified MIME.
  FLUX uses its original as the preview to avoid altering Content Credentials;
  other sources have a derived WebP preview, with no provenance-survival claim
  for transformed previews. Each distinct private object has one owner.

## AI narration (disabled by default)

Reuses the API/worker deployments, Firebase Auth, App Check, Firestore, Secret
Manager key and private bucket; it does not touch illustration credits.
Registration needs no consent and accepts only the account-scoped fingerprint;
auth and App Check stay mandatory. Both iOS and macOS use this cloud path by
default (Apple on-device narration is off unless the client is built with
`--dart-define=ON_DEVICE_NARRATION_ENABLED=true`), so generation is refused
until `NARRATION_ENABLED=true` here.

Terraform variables `narration_enabled`, `narration_monthly_characters`,
`narration_daily_characters` inject `NARRATION_ENABLED` (default false),
`NARRATION_MONTHLY_CHARACTERS` (500000), `NARRATION_DAILY_CHARACTERS` (200000)
and `NARRATION_TASK_QUEUE` (`reader-narration`). Foundation owns the Apple
Firebase registrations; the feature stack owns the queue, input TTL and indexes.

Authenticated routes:

- `GET /v1/narration/config`: rollout, model/voices, remaining UTC-month allowance.
- `POST /v1/narration/books`: fingerprint only; no prose.
- `POST /v1/narration/books/:bookId/jobs`: exact prose, SHA-256 digest, chunk ID,
  document/chunk versions, `marin`/`cedar` voice. Idempotent.
- `GET /v1/narration/jobs/:jobId`: status plus a ten-minute download URL for live,
  unexpired audio owned by the caller.
- `DELETE /v1/narration/books/:bookId`: tombstone and purge; works with rollout off.
- `DELETE /v1/account`: purges narration before the client deletes identity.

Worker `/internal/narration/:jobId` claims a job with a four-minute lease and
claim token, then calls OpenAI Realtime (`gpt-realtime-2.1-mini`, fixed
instructions, no tools, isolated input, 24 kHz mono PCM, three-minute timeout).
Refusal, incomplete, empty, misaligned or oversized PCM publishes nothing.
Transcript events are ignored; the service does not verify spoken-text fidelity.

Quota: UTF-16 input characters are reserved against the user's UTC month and the
environment's UTC day. Submission is recorded durably before the provider
request; pre-submission failures release the reservation, submitted failures stay
charged. A user retry gets a new reservation/task identity, with at most two
provider attempts. Stale claims, deleted books and deleted accounts cannot
publish. Cached local replay is free. Audio expires after 30 days (bucket
lifecycle plus checked delivery expiration). Raw prose is removed at terminal
completion; abandoned inputs hit a 24-hour Firestore TTL (asynchronous).
Allowance reads reclaim expired unsubmitted reservations in batches of 100.

Do not enable rollout until signed iOS and macOS auth/App Check, background
playback, media controls and listening quality are verified. Automated tests make
no live provider calls.

## Account usage

`GET /v1/account/usage` needs the verified Firebase ID token and App Check token,
stays readable with both rollout flags off, derives ownership from the token
only, and returns `Cache-Control: no-store` with:

- `asOf`; `narrationEnabled`, `illustrationsEnabled`.
- `narrationMonthlyLimit`, `narrationRemaining` (outstanding reservations
  count as used), `narrationResetAt` (next UTC month start).
- `illustrationCreditsRemaining`, `illustrationCreditsReserved` (null when
  credits are not activated).

Read-only: it never initializes credits, registers books, changes consent,
enqueues work or reclaims reservations, so it may conservatively include expired
reservations until cleanup runs. Missing monthly usage means the full allowance.

## Approved dev live smoke

Use only a disposable, authenticated dev account, after deployment/provider-spend
approval. Never run account deletion against a real user's identity. Every `/v1`
request needs `Authorization: Bearer <Firebase ID token>` and
`X-Firebase-AppCheck: <App Check token>`; never log those, provider keys, passage
bodies or signed URLs; never fabricate App Check tokens. No public test bypass
exists. Both rollout flags must be on for the full recipe.

| Request | Body / assertion |
| --- | --- |
| `GET /health` | 200 `{"ok":true}`, no auth (Cloud Run reserves some `z`-suffixed paths). |
| `GET /v1/account/usage` | 200, `no-store`; flags true, nonnegative narration allowance; fresh illustration credits null. Keep as baseline. |
| `GET /v1/fingerprint-key` | 200, base64 `key`; derive the account-scoped HMAC-SHA256 fingerprint of a disposable book identifier. |
| `GET /v1/illustrations/config` | 200, `schemaVersion:2`, all six sources, availability, OpenAI default, `no-store`; readable with rollout off. |
| `POST /v1/books` | `{"schemaVersion":2,"fingerprint":"<64-hex>","title":"The Lantern Courtyard","authors":["Dev smoke"],"language":"en","chapterCount":1}` → 200, salted 40-hex `id`, configuration/current profile, suggested style, two alternatives, `estimatedCredits:3`. |
| `PUT /v1/books/:bookId/profile` | `{"schemaVersion":2,"providerId":"openai","style":"<suggestedStyle>","density":1,"expectedRevision":0,"analysisVersion":2}` → 200, saved profile with `revision:1`. |
| `POST /v1/books/:bookId/chapters/0/jobs` | Chapter body below → 202, 40-hex job `id`; exact repeat returns same ID, no second charge. |
| `GET /v1/jobs/:jobId` | Poll `queued`/`analyzing` → `complete` with at least one `ready_locked` scene (scene-less `complete` is not success). Anchor `href`, paragraph ID, selector, progression match the submission. |
| `POST /v1/scenes/:sceneId/unlock` | 200, signed URLs, verified image/thumbnail MIME, alias flag, alt text, caption, `generationVersion:1`. Decode the landscape original and preview using returned MIME; aliased FLUX preview is byte-identical to its original. Bare object URLs are inaccessible. |
| `POST /v1/scenes/:sceneId/regenerate` | 202; poll to ready; unlock → 200, `generationVersion:2`, decodable new native-format image. |
| `GET /v1/account/usage` | Initial + paid regeneration spend exactly two credits; reserved returns to 0. Re-registering the book or registering another fingerprint grants/resets nothing. |
| `GET /v1/narration/config` | 200, `enabled:true`, model `gpt-realtime-2.1-mini`, voices `marin`/`cedar`, limits, allowance. |
| `POST /v1/narration/books` | `{"fingerprint":"<64-hex>"}` → 200, 64-hex `id`, matching `account`; illustration balances unchanged. |
| `POST /v1/narration/books/:bookId/jobs` | Narration body below → 200, 64-hex `id`; exact repeat: same ID, no second reservation. |
| `GET /v1/narration/jobs/:jobId` | Poll to `ready` with ten-minute `url`; fetch RIFF/WAVE 24 kHz mono 16-bit PCM; listen for the exact passage, no introduction. Repeat with `voice:"cedar"` and a new chunk ID. |
| `GET /v1/account/usage` | Two voice jobs reduce narration remaining by twice the passage UTF-16 length; credits unchanged; agrees with config. |
| `DELETE /v1/scenes/:sceneId` | 204; unlock → 404; reference/objects removed. |
| `DELETE /v1/books/:bookId` | 204; profile/job/same-fingerprint registration → 410; only the tombstone remains. Delete the second registration too. |
| `DELETE /v1/narration/books/:bookId` | 204; old job delivery and new submission → 410; audio removed, submitted allowance stays charged. |
| `DELETE /v1/account` | 204; privately verify full purge except account tombstone and shared daily usage. Delete Firebase identity only afterward. Old job delivery → 404; new registrations with the old token → 410. |

Chapter body (omits optional metadata to exercise strict Firestore serialization):

```json
{
  "href": "smoke.xhtml",
  "schemaVersion": 2,
  "profileRevision": 1,
  "analysisVersion": 2,
  "paragraphs": [
    {
      "id": "p0",
      "text": "Mira, wearing a blue coat, stepped into a quiet stone courtyard at dusk. A brass lantern glowed beside the arched gate.",
      "cssSelector": "#p0",
      "ordinal": 0,
      "progression": 0
    },
    {
      "id": "p1",
      "text": "She set the lantern on a wooden table beneath the flowering tree. Golden light fell across the stone walls and the silver leaves.",
      "cssSelector": "#p1",
      "ordinal": 1,
      "progression": 1
    }
  ]
}
```

Narration body (`digest` = lowercase SHA-256 of exact UTF-8 `text`; `chunkId` =
lowercase SHA-256 of a stable disposable anchor; length counts UTF-16 units):

```json
{
  "text": "The lantern glowed beside the quiet courtyard gate.",
  "digest": "<64-hex SHA-256>",
  "chunkId": "<64-hex SHA-256>",
  "voice": "marin",
  "documentVersion": 1,
  "chunkVersion": 1
}
```

Additional checks:

- Missing either auth header → 401; a second dev account cannot read another's
  jobs/scenes (404). Invalid narration digest/version → 400 with no usage change.
- API-service `/internal/*` → 404; anonymous worker invocation rejected by Cloud
  Run IAM; task delivery uses the configured OIDC identity.
- Narration `failed` is a failed smoke. An explicit retry may make a second
  provider attempt/reservation; after two attempts, retry → 409. Submitted
  failures stay charged.
- Uncharged illustration refresh: on a separate disposable scene, use a
  parent-approved dev-only fixture setting `assetExpiresAt` within 24 hours.
  Unlock → 409 while queued; after ready, unlock → newer generation, no credit loss.
- Rollout-off check (needs approval to change shared settings): usage, narration
  config and privacy deletion still work; generation endpoints → 503.
- Terminal jobs have no raw prose; account deletion must not refund shared daily
  charges.

For each newly configured generator, opt-in billed smoke must generate one
scene and one continuation with two story-safe references, plus an OpenAI
regression. Inspect composition, exact scene fidelity and character continuity;
record actual model, dimensions, native MIME, latency and provider charge without
logging prose, reference bytes, keys or signed URLs. Check original/preview
ownership, moderation, one-credit publication and FLUX byte preservation.
Protocol fixtures establish transport/lifecycle behavior, not live model access,
acoustic/image quality, provenance authenticity or provider billing. Do not
declare a source production-ready before its own live smoke succeeds.
