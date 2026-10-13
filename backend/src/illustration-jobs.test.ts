import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import express from "express";
import { MemoryFirestore } from "./test-support/firestore.js";
import { assignUid, startTestServer } from "./test-support/http.js";
import { illustrationJobRouter } from "./illustration-jobs.js";
import { illustrationBookRegistration } from "./illustration-books.js";
import { illustrationConfiguration, type IllustrationConfiguration } from "./illustration-configuration.js";
async function fixture(action: (memory: MemoryFirestore, request: (path: string, body?: unknown, method?: string) => Promise<Response>, tasks: string[]) => Promise<void>) {
  const previous = { ...process.env };
  process.env.ILLUSTRATIONS_ENABLED = "true";
  process.env.IMAGE_PROVIDERS = "openai,google,seedream,qwen,xai,flux";
  const memory = new MemoryFirestore();
  memory.values.set("users/owner/books/book", { uid: "owner", latestAnalysisGenerationId: "analysis" });
  // Unrelated image behavior runs against a finalized, empty analysis.
  memory.values.set("bookAnalysisRecords/analysis", { uid: "owner", bookId: "book", recordType: "generation", status: "complete" });
  const tasks: string[] = [];
  const app = express();
  app.use(express.json());
  app.use(assignUid(() => "owner"));
  app.get("/api/illustrations/config", illustrationConfiguration);
  app.post("/api/books", illustrationBookRegistration({ db: memory.firestore, pilotCredits: 100 }));
  app.use("/api", illustrationJobRouter({ db: memory.firestore, requireFeature: (_req, _res, next) => next(), enqueue: async (_path, _payload, id) => { tasks.push(id); } }));
  const server = await startTestServer(app);
  try {
    await action(memory, (path, body, method = body === undefined ? "GET" : "POST") => fetch(`${server.baseUrl}/api${path}`, {
      method, headers: { "content-type": "application/json" }, ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    }), tasks);
  } finally {
    await server.close();
    for (const key of Object.keys(process.env)) if (!(key in previous)) delete process.env[key];
    Object.assign(process.env, previous);
  }
}
const settings = { providerId: "openai", style: "Ink", density: 2, expectedRevision: 0 };
const chapter = { profileRevision: 1, href: "chapter.xhtml", paragraphs: [{ id: "p1", text: "The knight enters the courtyard.", ordinal: 0, progression: 1 }] };

test("new image intents wait for finalized matching preprocessing and reserve nothing", async () => {
  await fixture(async (memory, request, tasks) => {
    await request("/books/book/profile", settings, "PUT");
    memory.values.set("bookAnalysisRecords/analysis", { uid: "owner", bookId: "book", recordType: "generation", status: "finalizing" });
    for (const body of [chapter]) {
      const response = await request("/books/book/chapters/0/jobs", body);
      assert.equal(response.status, 409);
      assert.equal((await response.json() as { error: string }).error, "Book preprocessing is not complete.");
    }
    assert.deepEqual(tasks, []);
    assert(![...memory.values.keys()].some(path => path.startsWith("illustrationJobs/") || path.startsWith("illustrationJobInputs/")));
    assert.equal(memory.values.get("users/owner")?.creditsRemaining, undefined);
  });
});

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

test("registration rejects unavailable rollout without credit mutation and salts IDs", async () => {
  await fixture(async (memory, request) => {
    const before = memory.values.size;
    process.env.IMAGE_PROVIDERS = "";
    assert.equal((await request("/books", { fingerprint: "f", title: "Book" })).status, 503);
    process.env.IMAGE_PROVIDERS = "openai";
    process.env.ILLUSTRATIONS_ENABLED = "false";
    assert.equal((await request("/books", { fingerprint: "f", title: "Book" })).status, 503);
    assert.equal(memory.values.size, before);
    process.env.ILLUSTRATIONS_ENABLED = "true";
    const result = await (await request("/books", { fingerprint: "f", title: "Book" })).json() as { id: string; configuration: unknown };
    assert.equal(result.id, createHash("sha256").update("owner:f:illustrations").digest("hex").slice(0, 40));
    assert(result.configuration);
    assert.equal(memory.values.get("users/owner")?.creditsRemaining, 100);
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
    assert.deepEqual(job.profile, { providerId: "openai", style: "Ink", density: 2, revision: 1 });
    assert.deepEqual(job.imageConfig, { providerId: "openai", model: "model-at-admission", orchestratorModel: "orchestrator-at-admission", renderPreset: "reader-landscape" });
    assert(!JSON.stringify(job).includes("courtyard"));
    const input = memory.values.get(`illustrationJobInputs/${id}`)!;
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

test("polling reports committed and pending generations independently", async () => {
  await fixture(async (memory, request) => {
    memory.values.set("illustrationJobs/job", { uid: "owner", status: "ready" });
    memory.values.set("illustrationScenes/scene", { uid: "owner", jobId: "job", status: "regenerating", generation: 1, regenerationTarget: 2, anchor: {} });
    const result = await (await request("/jobs/job")).json() as { scenes: Array<{ generation: number; pendingGeneration: number; regenerating: boolean }> };
    assert.equal(result.scenes[0]?.generation, 1);
    assert.equal(result.scenes[0]?.pendingGeneration, 2);
    assert.equal(result.scenes[0]?.regenerating, true);
  });
});

test("polling reports a generating scene before any image exists", async () => {
  await fixture(async (memory, request) => {
    memory.values.set("illustrationJobs/job", { uid: "owner", status: "analyzing" });
    memory.values.set("illustrationScenes/scene", { uid: "owner", jobId: "job", status: "generating", generation: 0, anchor: {} });
    const result = await (await request("/jobs/job")).json() as { scenes: Array<{ status: string; generation: number; regenerating: boolean }> };
    assert.equal(result.scenes[0]?.status, "generating");
    assert.equal(result.scenes[0]?.generation, 0);
    assert.equal(result.scenes[0]?.regenerating, false);
  });
});

test("registration retries return the authoritative current profile without changing credits", async () => {
  await fixture(async (memory, request) => {
    const registration = { fingerprint: "same-book", title: "Book" };
    const first = await (await request("/books", registration)).json();
    const saved = await (await request(`/books/${first.id}/profile`, { ...settings, providerId: "google" }, "PUT")).json();
    memory.values.set("users/owner", { creditsRemaining: 7, creditsReserved: 1 });
    const retry = await (await request("/books", registration)).json();
    assert.deepEqual(retry.currentProfile, saved);
    assert.deepEqual(memory.values.get("users/owner"), { creditsRemaining: 7, creditsReserved: 1 });
  });
});

test("profile revision is required before any profile or chapter writes", async () => {
  await fixture(async (memory, request, tasks) => {
    const writes = memory.events.length;
    assert.equal((await request("/books/book/profile", { ...settings, expectedRevision: -1 }, "PUT")).status, 400);
    assert.equal((await request("/books/book/chapters/0/jobs", { ...chapter, profileRevision: 0 })).status, 400);
    assert.equal(memory.events.length, writes);
    assert.deepEqual(tasks, []);
  });
});
