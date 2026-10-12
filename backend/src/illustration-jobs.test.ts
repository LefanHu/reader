import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import express from "express";
import { MemoryFirestore } from "./test-support/firestore.js";
import { HttpError } from "./http.js";
import { illustrationJobRouter } from "./illustration-jobs.js";
import { illustrationBookRegistration } from "./illustration-books.js";
import { illustrationConfiguration, type IllustrationConfiguration } from "./illustration-configuration.js";
async function fixture(action: (memory: MemoryFirestore, request: (path: string, body?: unknown, method?: string) => Promise<Response>, tasks: string[]) => Promise<void>) {
  const previous = { ...process.env };
  process.env.ILLUSTRATIONS_ENABLED = "true";
  process.env.IMAGE_PROVIDERS = "openai,google,seedream,qwen,xai,flux";
  const memory = new MemoryFirestore();
  memory.values.set("users/owner/books/book", { uid: "owner", schemaVersion: 2 });
  const tasks: string[] = [];
  const app = express();
  app.use(express.json());
  app.use((req, _res, next) => { (req as express.Request & { uid: string }).uid = "owner"; next(); });
  app.get("/v1/illustrations/config", illustrationConfiguration);
  app.post("/v1/books", illustrationBookRegistration({ db: memory.firestore, pilotCredits: 100 }));
  app.use("/v1", illustrationJobRouter({ db: memory.firestore, requireFeature: (_req, _res, next) => next(), enqueue: async (_path, _payload, id) => { tasks.push(id); } }));
  app.use((error: unknown, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
    res.status(error instanceof HttpError ? error.status : 500).json({ error: error instanceof Error ? error.message : "Failed" });
  });
  const server = app.listen(0, "127.0.0.1");
  await new Promise<void>(resolve => server.on("listening", resolve));
  const address = server.address();
  assert(address && typeof address === "object");
  try {
    await action(memory, (path, body, method = body === undefined ? "GET" : "POST") => fetch(`http://127.0.0.1:${address.port}/v1${path}`, {
      method, headers: { "content-type": "application/json" }, ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    }), tasks);
  } finally {
    await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    for (const key of Object.keys(process.env)) if (!(key in previous)) delete process.env[key];
    Object.assign(process.env, previous);
  }
}
const settings = { schemaVersion: 2, providerId: "openai", style: "Ink", density: 2, analysisVersion: 2, expectedRevision: 0 };
const chapter = { schemaVersion: 2, profileRevision: 1, analysisVersion: 2, href: "chapter.xhtml", paragraphs: [{ id: "p1", text: "The knight enters the courtyard.", cssSelector: "#p1", ordinal: 0, progression: 1 }] };

test("catalogue remains readable with rollout disabled and exposes all seven nonsecret sources", async () => {
  await fixture(async (_memory, request) => {
    process.env.ILLUSTRATIONS_ENABLED = "false";
    process.env.IMAGE_PROVIDERS = "openai,google";
    const response = await request("/illustrations/config");
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("cache-control"), "no-store");
    const configuration = await response.json() as IllustrationConfiguration;
    assert.equal(configuration.enabled, false);
    assert.equal(configuration.defaultProviderId, "openai");
    assert.equal(configuration.providers.length, 7);
    assert.equal(configuration.providers.find(provider => provider.id === "google")?.recommended, true);
    assert.equal(configuration.providers.find(provider => provider.id === "flux")?.available, false);
    const diagnostic = configuration.providers.find(provider => provider.id === "diagnostic");
    assert.deepEqual([diagnostic?.available, diagnostic?.recommended, diagnostic?.costTier], [false, false, "free"]);
  });
});

test("registration rejects old schema and unavailable rollout without credit mutation and salts IDs", async () => {
  await fixture(async (memory, request) => {
    const before = memory.values.size;
    assert.equal((await request("/books", { fingerprint: "f", title: "Book" })).status, 400);
    process.env.IMAGE_PROVIDERS = "";
    assert.equal((await request("/books", { schemaVersion: 2, fingerprint: "f", title: "Book" })).status, 503);
    process.env.IMAGE_PROVIDERS = "openai";
    process.env.ILLUSTRATIONS_ENABLED = "false";
    assert.equal((await request("/books", { schemaVersion: 2, fingerprint: "f", title: "Book" })).status, 503);
    assert.equal(memory.values.size, before);
    process.env.ILLUSTRATIONS_ENABLED = "true";
    const result = await (await request("/books", { schemaVersion: 2, fingerprint: "f", title: "Book" })).json() as { id: string; configuration: unknown };
    assert.equal(result.id, createHash("sha256").update("owner:f:illustrations-v2").digest("hex").slice(0, 40));
    assert(result.configuration);
    assert.equal(memory.values.get("users/owner")?.creditsRemaining, 100);
    assert.equal(memory.values.get(`users/owner/books/${result.id}`)?.schemaVersion, 2);
  });
});

test("profile supports six choices, lost-response no-op retries, and revision races", async () => {
  await fixture(async (memory, request) => {
    const save = (body: unknown) => request("/books/book/profile", body, "PUT");
    assert.equal((await save({ ...settings, providerId: "invalid" })).status, 400);
    process.env.IMAGE_PROVIDERS = "openai";
    const before = memory.events.length;
    assert.equal((await save({ ...settings, providerId: "flux" })).status, 503);
    assert.equal(memory.events.length, before);
    process.env.IMAGE_PROVIDERS = "openai,google,seedream,qwen,xai,flux,diagnostic";
    let revision = 0;
    for (const providerId of ["openai", "google", "seedream", "qwen", "xai", "flux", "diagnostic"]) {
      const response = await save({ ...settings, providerId, expectedRevision: revision });
      assert.equal(response.status, 200);
      const profile = await response.json() as { revision: number; providerId: string };
      assert.equal(profile.revision, ++revision);
      assert.equal(profile.providerId, providerId);
      const writes = memory.events.length;
      const retry = await save({ ...settings, providerId, expectedRevision: revision - 1 });
      const retryProfile = await retry.json();
      assert.equal(retryProfile.revision, revision);
      assert.equal(memory.events.length, writes);
    }
    const responses = await Promise.all([save({ ...settings, style: "Watercolour", expectedRevision: revision }), save({ ...settings, style: "Charcoal", expectedRevision: revision })]);
    assert.deepEqual(responses.map(response => response.status).sort(), [200, 409]);
  });
});

test("admitted jobs retain immutable profile/model snapshots across retries and input expiry", async () => {
  await fixture(async (memory, request, tasks) => {
    process.env.OPENAI_IMAGE_MODEL = "model-at-admission";
    process.env.OPENAI_IMAGE_ORCHESTRATOR_MODEL = "orchestrator-at-admission";
    await request("/books/book/profile", settings, "PUT");
    const response = await request("/books/book/chapters/0/jobs", { ...chapter, density: 3, style: "ignored", providerId: "flux" });
    assert.equal(response.status, 202);
    const { id } = await response.json() as { id: string };
    const job = memory.values.get(`illustrationJobs/${id}`)!;
    assert.equal(job.schemaVersion, 2);
    assert.deepEqual(job.profile, { schemaVersion: 2, providerId: "openai", style: "Ink", density: 2, analysisVersion: 2, revision: 1 });
    assert.deepEqual(job.imageConfig, { schemaVersion: 2, providerId: "openai", model: "model-at-admission", orchestratorModel: "orchestrator-at-admission", renderPreset: "reader-landscape-v1" });
    assert(!JSON.stringify(job).includes("courtyard"));
    const input = memory.values.get(`illustrationJobInputs/${id}`)!;
    assert.equal(input.schemaVersion, 2);
    assert(input.input && typeof input.input === "object" && "density" in input.input);
    assert.equal(input.input.density, 2);
    assert(input.expiresAt);
    await request("/books/book/profile", { ...settings, providerId: "google", expectedRevision: 1 }, "PUT");
    process.env.OPENAI_IMAGE_MODEL = "changed";
    process.env.IMAGE_PROVIDERS = "google";
    memory.values.delete(`illustrationJobInputs/${id}`);
    assert.equal((await request("/books/book/chapters/0/jobs", chapter)).status, 202);
    assert.deepEqual(memory.values.get(`illustrationJobs/${id}`), job);
    assert(!memory.values.has(`illustrationJobInputs/${id}`));
    assert.deepEqual(tasks, [`job-${id}`, `job-${id}`]);
    assert.equal((await request("/books/book/chapters/1/jobs", chapter)).status, 409);
    assert.equal((await request("/books/book/chapters/1/jobs", { ...chapter, profileRevision: 2 })).status, 202);
  });
});

test("unavailable chapter admission and stale/deleted fences create no operation or input", async () => {
  await fixture(async (memory, request, tasks) => {
    await request("/books/book/profile", settings, "PUT");
    process.env.IMAGE_PROVIDERS = "google";
    const writes = memory.events.length;
    assert.equal((await request("/books/book/chapters/0/jobs", chapter)).status, 503);
    assert.equal(memory.events.length, writes);
    assert.deepEqual(tasks, []);
    process.env.IMAGE_PROVIDERS = "openai";
    memory.values.set("narrationAccountTombstones/owner", { deletedAt: new Date() });
    assert.equal((await request("/books/book/chapters/0/jobs", chapter)).status, 410);
    assert(![...memory.values.keys()].some(path => path.startsWith("illustrationJobs/") || path.startsWith("illustrationJobInputs/")));
  });
});

test("polling reports committed and pending versions independently", async () => {
  await fixture(async (memory, request) => {
    memory.values.set("illustrationJobs/job", { schemaVersion: 2, uid: "owner", status: "ready" });
    memory.values.set("illustrationScenes/scene", { schemaVersion: 2, uid: "owner", jobId: "job", status: "regenerating", generationVersion: 1, regenerationTarget: 2, anchor: {} });
    const result = await (await request("/jobs/job")).json() as { scenes: Array<{ generationVersion: number; pendingGenerationVersion: number; regenerating: boolean }> };
    assert.equal(result.scenes[0]?.generationVersion, 1);
    assert.equal(result.scenes[0]?.pendingGenerationVersion, 2);
    assert.equal(result.scenes[0]?.regenerating, true);
  });
});

test("polling reports a generating scene before any image exists", async () => {
  await fixture(async (memory, request) => {
    memory.values.set("illustrationJobs/job", { schemaVersion: 2, uid: "owner", status: "analyzing" });
    memory.values.set("illustrationScenes/scene", { schemaVersion: 2, uid: "owner", jobId: "job", status: "generating", generationVersion: 0, anchor: {} });
    const result = await (await request("/jobs/job")).json() as { scenes: Array<{ status: string; generationVersion: number; regenerating: boolean }> };
    assert.equal(result.scenes[0]?.status, "generating");
    assert.equal(result.scenes[0]?.generationVersion, 0);
    assert.equal(result.scenes[0]?.regenerating, false);
  });
});

test("registration retries return the authoritative current profile without changing credits", async () => {
  await fixture(async (memory, request) => {
    const registration = { schemaVersion: 2, fingerprint: "same-book", title: "Book" };
    const first = await (await request("/books", registration)).json();
    const saved = await (await request(`/books/${first.id}/profile`, { ...settings, providerId: "google" }, "PUT")).json();
    memory.values.set("users/owner", { creditsRemaining: 7, creditsReserved: 1 });
    const retry = await (await request("/books", registration)).json();
    assert.deepEqual(retry.currentProfile, saved);
    assert.deepEqual(memory.values.get("users/owner"), { creditsRemaining: 7, creditsReserved: 1 });
  });
});

test("schema and profile revision are required before any profile or chapter writes", async () => {
  await fixture(async (memory, request, tasks) => {
    const writes = memory.events.length;
    assert.equal((await request("/books/book/profile", { ...settings, schemaVersion: 1 }, "PUT")).status, 400);
    assert.equal((await request("/books/book/profile", { ...settings, expectedRevision: -1 }, "PUT")).status, 400);
    assert.equal((await request("/books/book/chapters/0/jobs", { ...chapter, schemaVersion: 1 })).status, 400);
    assert.equal((await request("/books/book/chapters/0/jobs", { ...chapter, profileRevision: 0 })).status, 400);
    assert.equal(memory.events.length, writes);
    assert.deepEqual(tasks, []);
  });
});
