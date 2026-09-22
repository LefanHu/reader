# Reader illustration backend

One container image contains the authenticated mobile API and Cloud Tasks worker
routes. Deploy it as two Cloud Run services: a public API service and a private
worker service. Set `WORKER_URL` to the worker and require Cloud Run IAM
authentication for that service.

Required configuration:

- `OPENAI_API_KEY`, `FINGERPRINT_SECRET`
- `GOOGLE_CLOUD_PROJECT`, `ILLUSTRATION_BUCKET`
- `TASK_LOCATION`, `TASK_QUEUE`, `TASK_SERVICE_ACCOUNT`, `WORKER_URL`
- `ILLUSTRATIONS_ENABLED=true` to open the remote feature flag (it defaults off)
- `SERVICE_ROLE=api` on the public mobile service and `SERVICE_ROLE=worker` on
  the private, Cloud Tasks/IAM-only worker service
- optional `OPENAI_SCENE_MODEL`, `OPENAI_IMAGE_MODEL`,
  `OPENAI_IMAGE_ORCHESTRATOR_MODEL`, `PILOT_CREDITS`, and `WORKER_TOKEN` for
  local worker calls

Create Firestore TTL on `illustrationJobInputs.expiresAt`, deny all direct client
access to Firestore and Storage, and grant the API/worker service accounts only
the collections, bucket prefix, Secret Manager secret, and task permissions they
need. The mobile build supplies Firebase and API values with `--dart-define`.

Configure the bucket lifecycle to delete `users/**/scenes/**` after 30 days.
Scene documents also carry `assetExpiresAt`; `/unlock` queues an uncharged
refresh when an asset is within 24 hours of expiry. Cloud Storage must remain
private—clients receive only ten-minute signed URLs after their local locator
gate opens. Use Firestore CMEK if the deployment requires customer-managed
encryption for temporary chapter jobs; Firestore encryption at rest is always
required.

The API never accepts an EPUB. It accepts one normalized chapter at a time and
analyzes it once into append-only, paragraph-anchored entity revisions plus
scene candidates. The prose is deleted immediately after that analysis. Image
generation receives only the selected scene range and the compact world state
that was established before the scene, never the whole chapter or future
revisions. OpenAI Responses API storage is disabled.

The service runs text moderation before image generation and image moderation
before committing an asset. Credits are transactionally reserved and charged
only after a usable scene record and both private objects commit; retries reuse
the same reservation. `DELETE /v1/account` purges global jobs, temporary prose,
scene metadata, temporal world revisions and references, reservations, user
records, and the user's storage prefix.

Terraform owns the deployed indexes, TTL policy, Security Rules, service
identities, and Cloud Run services. Do not run `firebase deploy`; use the
repository-root deployment entry point so these resources retain one source of
truth:

```sh
tool/deploy_backend dev
```

See [`../infra/README.md`](../infra/README.md) for state bootstrapping,
migration safeguards, secrets, drift review, and new-environment setup.
