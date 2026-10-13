import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import express from "express";
import { Timestamp } from "firebase-admin/firestore";
import sharp from "sharp";
import { composeImagePrompt } from "./openai.js";
import { assignUid, startTestServer } from "./test-support/http.js";
import { MemoryStorage } from "./test-support/storage.js";
import { MemoryFirestore } from "./test-support/firestore.js";
import { illustrationWorkerRouter } from "./illustration-worker.js";
import type { IllustrationSceneRange } from "./book-analysis-context.js";
import { illustrationSceneRouter } from "./illustration-scenes.js";
import { illustrationBookDeletion } from "./illustration-books.js";
import { accountDeletionRouter } from "./account.js";
import { NarrationBackend } from "./narration.js";
import type { ChapterInput, ImageGenerationConfig, IllustrationBookProfile, IllustrationContext, SceneGenerationSpec } from "./types.js";
import { snapshotImageGenerationConfig } from "./illustration-configuration.js";
import { validateGeneratedImage, type GeneratedImage, type ReferenceImage } from "./image-generation.js";
import type { SelectedScene } from "./scene-selection.js";
import { renderPromptImage } from "./image-test-provider.js";
import { ASSET_RETENTION_MILLISECONDS } from "./durations.js";

type Data = Record<string, unknown>;
const hash = (value: string) => createHash("sha256").update(value).digest("hex");
const reservationPath = (operation: string) => `creditReservations/${hash(`owner:${operation}`)}`;

const input: ChapterInput = {
  href: "chapter.xhtml", profileRevision: 1, density: 1,
  paragraphs: [{ id: "paragraph", text: "A traveler enters the courtyard.",
    ordinal: 0, progression: 0.5 }],
};
const selection: SelectedScene[] = [{ startParagraphId: "paragraph", endParagraphId: "paragraph" }];
const sceneId = hash("job:paragraph:paragraph").slice(0, 40);
const oldImageObject = "users/owner/books/book/scenes/scene.1.webp";
const oldThumbnailObject = "users/owner/books/book/scenes/scene.1.thumb.webp";
const profile: IllustrationBookProfile = { providerId: "openai",
  style: "Painted", revision: 1, density: 1 };
const imageConfig = snapshotImageGenerationConfig("openai", {});
const generationSpec: SceneGenerationSpec = { imageConfig, style: "Painted", sceneText: "A courtyard" };
let contextStub: ((scene: IllustrationSceneRange) => IllustrationContext) | undefined;
let contextLoads = 0;
type Generation = { config: ImageGenerationConfig; prompt: string; references: readonly ReferenceImage[] };

async function fixture(action: (harness: {
  db: MemoryFirestore; objects: Map<string, Buffer>; image: Buffer; calls: { selection: number; images: number };
  generations: Generation[]; contentTypes: Map<string, string>; moderatedImages: GeneratedImage[];
  request: (path: string, body?: Data, method?: string) => Promise<Response>;
  generate: (implementation: (config: ImageGenerationConfig, prompt: string, references: readonly ReferenceImage[]) => Promise<Buffer | GeneratedImage>) => void;
  credentials: (implementation: (config: ImageGenerationConfig) => void | Promise<void>) => void;
  select: (implementation: () => Promise<SelectedScene[]>) => void;
  save: (implementation: (path: string) => Promise<void>) => void;
  enqueue: (implementation: (path: string, body: Data, id: string) => Promise<void>) => void;
}) => Promise<void>) {
  const db = new MemoryFirestore();
  const calls = { selection: 0, images: 0 };
  const generations: Generation[] = [];
  const moderatedImages: GeneratedImage[] = [];
  const image = await sharp({ create: { width: 150, height: 100, channels: 3, background: "#336699" } }).webp().toBuffer();
  let generate: (config: ImageGenerationConfig, prompt: string, references: readonly ReferenceImage[]) => Promise<Buffer | GeneratedImage> = async () => image;
  let credentials: (config: ImageGenerationConfig) => void | Promise<void> = () => {};
  const priorProviders = process.env.IMAGE_PROVIDERS;
  const priorImageModel = process.env.OPENAI_IMAGE_MODEL;
  const priorOrchestrator = process.env.OPENAI_IMAGE_ORCHESTRATOR_MODEL;
  process.env.IMAGE_PROVIDERS = "openai,google,seedream,qwen,xai,flux,diagnostic";
  let select: () => Promise<SelectedScene[]> = async () => selection;
  let enqueue: (path: string, body: Data, id: string) => Promise<void> = async () => {};
  const memoryStorage = new MemoryStorage(db.events);
  const { objects, contentTypes, storage } = memoryStorage;
  const app = express();
  app.use(express.json());
  app.use("/api", assignUid(() => "owner"));
  app.use("/api", illustrationSceneRouter({
    db: db.firestore, storage, bucket: "private",
    requireFeature: (_req, _res, next) => next(),
    enqueue: (path, body, id) => enqueue(path, body, id),
  }));
  app.delete("/api/books/:bookId", illustrationBookDeletion({ db: db.firestore, storage, bucket: "private" }));
  const narration = new NarrationBackend({ db: db.firestore, storage, bucket: "private",
    enabled: false, enqueue: async () => {}, provider: { generate: async () => { throw new Error("Narration is not exercised"); } } });
  app.use("/api/account", accountDeletionRouter({ db: db.firestore, storage, bucket: "private", narration }));
  app.use("/internal", illustrationWorkerRouter({
    db: db.firestore, storage, bucket: "private",
    assetRetentionMilliseconds: ASSET_RETENTION_MILLISECONDS, composeImagePrompt,
    selectScenes: async () => { calls.selection++; return select(); },
    moderateText: async () => false,
    loadContext: async () => { contextLoads++; return contextStub ?? null; },
    moderateImage: async (bytes, mimeType) => { moderatedImages.push({ bytes, mimeType }); return false; },
    imageGenerationProvider: {
      validateCredentials: config => credentials(config),
      generate: async (config, prompt, references = []) => {
        calls.images++; generations.push({ config, prompt, references });
        const image = await generate(config, prompt, references);
        return Buffer.isBuffer(image) ? validateGeneratedImage(image) : image;
      },
    },
  }));
  const server = await startTestServer(app);
  const url = server.baseUrl;
  try {
    await action({ db, objects, image, calls, generations, contentTypes, moderatedImages,
      request: (path, body = {}, method = "POST") => fetch(`${url}${path.startsWith("/api/") ? path : `/internal${path}`}`, {
        method, headers: { "content-type": "application/json" }, ...(method === "DELETE" ? {} : { body: JSON.stringify(body) }),
      }),
      generate: implementation => { generate = implementation; },
      credentials: implementation => { credentials = implementation; },
      select: implementation => { select = implementation; },
      save: implementation => { memoryStorage.beforeSave = implementation; },
      enqueue: implementation => { enqueue = implementation; },
    });
  } finally {
    if (priorProviders === undefined) delete process.env.IMAGE_PROVIDERS;
    else process.env.IMAGE_PROVIDERS = priorProviders;
    if (priorImageModel === undefined) delete process.env.OPENAI_IMAGE_MODEL;
    else process.env.OPENAI_IMAGE_MODEL = priorImageModel;
    if (priorOrchestrator === undefined) delete process.env.OPENAI_IMAGE_ORCHESTRATOR_MODEL;
    else process.env.OPENAI_IMAGE_ORCHESTRATOR_MODEL = priorOrchestrator;
    await server.close();
  }
}
function seedJob(db: MemoryFirestore) {
  db.values.set("users/owner", { creditsRemaining: 2, creditsReserved: 0 });
  db.values.set("users/owner/books/book", { profile });
  db.values.set("illustrationJobs/job", { uid: "owner", bookId: "book", chapterOrdinal: 0, status: "queued",
    profile, imageConfig });
  db.values.set("illustrationJobInputs/job", { uid: "owner", bookId: "book", chapterOrdinal: 0, input });
}
function seedScene(db: MemoryFirestore) {
  db.values.set("users/owner", { creditsRemaining: 2, creditsReserved: 0 });
  db.values.set("users/owner/books/book", { profile });
  db.values.set("illustrationScenes/scene", { uid: "owner", bookId: "book", status: "regenerating",
    chapterOrdinal: 0, paragraphOrdinal: 0,
    anchor: { href: "chapter.xhtml", spineOrdinal: 0, paragraphId: "paragraph", fallbackProgression: 0.5 },
    altText: "A courtyard", caption: "Courtyard",
    regenerationTarget: 2, regenerationRefresh: false, regenerationTaskId: "regen-scene-2",
    regenerationPreviousStatus: "unlocked", regenerationGenerationSpec: generationSpec,
    generation: 1, imageObject: oldImageObject, thumbnailObject: oldThumbnailObject,
    imageMimeType: "image/webp", thumbnailMimeType: "image/webp", thumbnailUsesOriginal: false,
    generationSpec });
}

test("completed jobs end and actively leased jobs retry, leaving input and credits untouched", async () => {
  await fixture(async ({ db, calls, request }) => {
    for (const [state, status] of [[{ status: "complete" }, 204],
      [{ status: "analyzing", leaseUntil: Timestamp.fromMillis(Date.now() + 600000) }, 409]] as const) {
      seedJob(db);
      db.values.set("illustrationJobs/job", { ...db.values.get("illustrationJobs/job"), ...state });
      const before = [...db.values];
      assert.equal((await request("/jobs/job")).status, status);
      assert.deepEqual([...db.values], before);
    }
    assert.deepEqual(calls, { selection: 0, images: 0 });
    assert.equal(db.events.length, 0);
  });
});
test("missing input marks the claimed job failed and clears its lease before returning 404", async () => {
  await fixture(async ({ db, calls, request }) => {
    seedJob(db);
    db.values.delete("illustrationJobInputs/job");
    const response = await request("/jobs/job");
    assert.equal(response.status, 404);
    assert.deepEqual(await response.json(), { error: "Job input not found." });
    const job = db.values.get("illustrationJobs/job")!;
    assert.equal(job.status, "failed");
    assert.equal(job.failureCategory, "missing_input");
    assert(!("leaseUntil" in job));
    assert.deepEqual(calls, { selection: 0, images: 0 });
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 2);
  });
});
test("admitted temporal context is snapshotted into the scene recipe and prompt", async () => {
  await fixture(async ({ db, request, generations }) => {
    seedJob(db);
    contextLoads = 0;
    contextStub = (args) => ({ analysisRevision: "rev", generationId: "gen",
      sceneStart: args.sceneStart, sceneEnd: args.sceneEnd, subjects: [],
      facts: [{ assertionId: "a", subject: "Valley", property: "sky", value: "permanent dark sky", category: "ambient_environment",
        evidence: [], revealAt: args.sceneEnd } as unknown as IllustrationContext["facts"][number]] });
    try {
      assert.equal((await request("/jobs/job")).status, 204);
    } finally { contextStub = undefined; }
    assert.equal(contextLoads, 1);
    assert.match(generations[0]!.prompt, /sky: permanent dark sky/);
    const spec = db.values.get(`illustrationScenes/${sceneId}`)!.generationSpec as SceneGenerationSpec;
    assert.equal(spec.context?.facts[0]?.value, "permanent dark sky");
    assert.deepEqual(spec.sceneEnd, { sectionId: "chapter.xhtml", blockId: "paragraph", offset: input.paragraphs[0]!.text.length });
  });
});
test("scene publication follows reservation and prose deletion, then commits a single credit", async () => {
  await fixture(async ({ db, objects, calls, request, generate }) => {
    seedJob(db);
    generate(async () => {
      assert(!db.values.has("illustrationJobInputs/job"));
      assert.equal(db.values.get(reservationPath(sceneId))!.state, "reserved");
      assert.equal(db.values.get("users/owner")!.creditsReserved, 1);
      return sharp({ create: { width: 150, height: 100, channels: 3, background: "#336699" } }).webp().toBuffer();
    });
    assert.equal((await request("/jobs/job")).status, 204);
    const scene = db.values.get(`illustrationScenes/${sceneId}`)!;
    assert.equal(scene.status, "ready_locked");
    assert.equal(scene.generation, 1);
    assert.match(String(scene.imageObject), new RegExp(`^users/owner/books/book/scenes/${sceneId}\\.claim-[\\w-]+\\.webp$`));
    assert(objects.has(String(scene.imageObject)));
    assert(objects.has(String(scene.thumbnailObject)));
    assert.equal(db.values.get(reservationPath(sceneId))!.state, "committed");
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 1);
    assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
    assert.equal(db.values.get("illustrationJobs/job")!.status, "complete");
    assert(!("leaseUntil" in db.values.get("illustrationJobs/job")!));
    assert(db.events.indexOf(`save:${scene.thumbnailObject}`) < db.events.indexOf(`write:illustrationScenes/${sceneId}:ready_locked`));
    assert(db.events.indexOf(`write:${reservationPath(sceneId)}:committed`) < db.events.indexOf(`write:illustrationScenes/${sceneId}:ready_locked`));
    assert.equal((await request("/jobs/job")).status, 204);
    assert.deepEqual(calls, { selection: 1, images: 1 });
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 1);
  });
});
test("candidate provider failure refunds its reservation, fails the scene record and cleans artifacts", async () => {
  await fixture(async ({ db, objects, request, generate }) => {
    seedJob(db);
    generate(async () => { throw new Error("local provider failure"); });
    assert.equal((await request("/jobs/job")).status, 204);
    assert.equal(db.values.get(reservationPath(sceneId))!.state, "refunded");
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 2);
    assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
    assert.equal(db.values.get("illustrationJobs/job")!.status, "complete");
    const scene = db.values.get(`illustrationScenes/${sceneId}`)!;
    assert.equal(scene.status, "failed");
    assert.equal(scene.failureCategory, "generation_failed");
    assert(!db.values.has("illustrationJobInputs/job"));
    assert.equal(objects.size, 0);
  });
});
test("regeneration lease rejects a second worker and completed target retries never charge twice", async () => {
  await fixture(async ({ db, objects, image, calls, request, generate }) => {
    seedScene(db);
    objects.set(oldImageObject, image);
    objects.set(oldThumbnailObject, image);
    let entered!: () => void;
    const started = new Promise<void>(resolve => { entered = resolve; });
    let release!: () => void;
    const hold = new Promise<void>(resolve => { release = resolve; });
    generate(async () => {
      entered();
      await hold;
      return sharp({ create: { width: 150, height: 100, channels: 3, background: "#336699" } }).webp().toBuffer();
    });
    const first = request("/scenes/scene/regenerate", { targetGeneration: 2, taskId: "regen-scene-2" });
    await started;
    try {
      assert.equal(db.values.get("users/owner")!.creditsReserved, 1);
      const duplicate = await request("/scenes/scene/regenerate", { targetGeneration: 2, taskId: "regen-scene-2" });
      assert.equal(duplicate.status, 409);
      assert.deepEqual(await duplicate.json(), { error: "Regeneration is already running." });
    } finally { release(); }
    assert.equal((await first).status, 204);
    assert.equal(db.values.get("illustrationScenes/scene")!.generation, 2);
    assert.equal(db.values.get(reservationPath("scene:generation:2"))!.state, "committed");
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 1);
    assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
    assert(!objects.has(oldImageObject));
    assert(!objects.has(oldThumbnailObject));
    assert(db.events.indexOf(`write:${reservationPath("scene:generation:2")}:committed`) < db.events.indexOf(`delete-object:${oldImageObject}`));
    assert.equal((await request("/scenes/scene/regenerate", { targetGeneration: 2, taskId: "regen-scene-2" })).status, 204);
    assert.equal(calls.images, 1);
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 1);
  });
});
test("regeneration failure refunds credits, clears the lease and keeps previous assets", async () => {
  await fixture(async ({ db, objects, image, request, generate }) => {
    seedScene(db);
    db.values.get("illustrationScenes/scene")!.regenerationGenerationSpec = {
      ...generationSpec, style: "New ink style", imageConfig: snapshotImageGenerationConfig("qwen", {}),
    };
    objects.set(oldImageObject, image);
    objects.set(oldThumbnailObject, image);
    generate(async () => { throw new Error("local provider failure"); });
    assert.equal((await request("/scenes/scene/regenerate", { targetGeneration: 2, taskId: "regen-scene-2" })).status, 500);
    assert.equal(db.values.get(reservationPath("scene:generation:2"))!.state, "refunded");
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 2);
    assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
    const scene = db.values.get("illustrationScenes/scene")!;
    assert.equal(scene.status, "unlocked");
    assert.equal(scene.failureCategory, "regeneration_failed");
    assert.equal(scene.generation, 1);
    assert.deepEqual(scene.generationSpec, generationSpec);
    assert.equal(scene.imageObject, oldImageObject);
    assert.equal(scene.thumbnailObject, oldThumbnailObject);
    for (const field of ["regenerationGenerationSpec", "regenerationPreviousStatus", "regenerationTarget",
      "regenerationRefresh", "regenerationTaskId", "regenerationToken"]) assert(!(field in scene));
    assert(!("regenerationLeaseUntil" in scene));
    assert.deepEqual([...objects.keys()], [oldImageObject, oldThumbnailObject]);
  });
});

function barrier() {
  let enter!: () => void, release!: () => void;
  const entered = new Promise<void>(resolve => { enter = resolve; });
  const released = new Promise<void>(resolve => { release = resolve; });
  return { entered, release, wait: async () => { enter(); await released; } };
}

for (const deletion of ["book", "account"] as const) {
  test(`chapter selection cannot recreate history or counters after ${deletion} deletion`, async () => {
    await fixture(async ({ db, objects, request, select }) => {
      seedJob(db);
      const gate = barrier();
      select(async () => { await gate.wait(); return selection; });
      const pending = request("/jobs/job");
      await gate.entered;
      try {
        assert.equal((await request(deletion === "book" ? "/api/books/book" : "/api/account", {}, "DELETE")).status, 204);
      } finally { gate.release(); }
      assert.equal((await pending).status, 204);
      assert.equal(objects.size, 0);
      assert(!db.values.has("illustrationJobs/job"));
      assert(!db.values.has("illustrationJobInputs/job"));
      if (deletion === "account") {
        assert.deepEqual([...db.values.keys()], ["narrationAccountTombstones/owner"]);
      } else {
        assert.equal(db.values.get("users/owner/books/book")!.deleted, true);
        assert.equal(db.values.get("users/owner")!.creditsRemaining, 2);
        assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
      }
    });
  });
  test(`late chapter image completion cannot recreate ${deletion}-deleted assets, records or credits`, async () => {
    await fixture(async ({ db, objects, request, generate }) => {
      seedJob(db);
      const gate = barrier();
      generate(async () => {
        await gate.wait();
        return sharp({ create: { width: 150, height: 100, channels: 3, background: "#336699" } }).webp().toBuffer();
      });
      const pending = request("/jobs/job");
      await gate.entered;
      try {
        assert.equal(db.values.get("users/owner")!.creditsReserved, 1);
        assert.equal((await request(deletion === "book" ? "/api/books/book" : "/api/account", {}, "DELETE")).status, 204);
      } finally { gate.release(); }
      assert.equal((await pending).status, 204);
      assert.equal(objects.size, 0);
      assert(!db.values.has(`illustrationScenes/${sceneId}`));
      assert(!db.values.has("illustrationJobs/job"));
      assert(!db.values.has(reservationPath(sceneId)));
      if (deletion === "account") assert.deepEqual([...db.values.keys()], ["narrationAccountTombstones/owner"]);
      else {
        assert.equal(db.values.get("users/owner")!.creditsRemaining, 2);
        assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
      }
    });
  });
}

for (const deletion of ["scene", "book", "account"] as const) {
  test(`late regeneration cannot publish after ${deletion} deletion`, async () => {
    await fixture(async ({ db, objects, image, request, generate }) => {
      seedScene(db);
      objects.set(oldImageObject, image);
      objects.set(oldThumbnailObject, image);
      const gate = barrier();
      generate(async () => {
        await gate.wait();
        return sharp({ create: { width: 150, height: 100, channels: 3, background: "#336699" } }).webp().toBuffer();
      });
      const pending = request("/scenes/scene/regenerate", { targetGeneration: 2, taskId: "regen-scene-2" });
      await gate.entered;
      try {
        const path = deletion === "scene" ? "/api/scenes/scene" : deletion === "book" ? "/api/books/book" : "/api/account";
        assert.equal((await request(path, {}, "DELETE")).status, 204);
      } finally { gate.release(); }
      assert.equal((await pending).status, 204);
      assert.equal(objects.size, 0);
      if (deletion === "scene") {
        assert.equal(objects.size, 0);
        assert.equal(db.values.get("illustrationScenes/scene")!.deleted, true);
        assert.equal((await request("/api/scenes/scene/unlock")).status, 404);
        assert.equal(db.values.get("users/owner")!.creditsRemaining, 2);
        assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
      } else {
        assert(!db.values.has("illustrationScenes/scene"));
        assert(!db.values.has(reservationPath("scene:generation:2")));
        if (deletion === "account") assert.deepEqual([...db.values.keys()], ["narrationAccountTombstones/owner"]);
        else assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
      }
    });
  });
}

test("scene deletion during an object save cleans late objects without recreating metadata", async () => {
  await fixture(async ({ db, objects, request, save }) => {
    seedScene(db);
    const gate = barrier();
    save(async path => { if (path.endsWith(".thumb.webp")) await gate.wait(); });
    const pending = request("/scenes/scene/regenerate", { targetGeneration: 2, taskId: "regen-scene-2" });
    await gate.entered;
    try { assert.equal((await request("/api/scenes/scene", {}, "DELETE")).status, 204); }
    finally { gate.release(); }
    assert.equal((await pending).status, 204);
    assert.equal(objects.size, 0);
    assert.equal(db.values.get("illustrationScenes/scene")!.deleted, true);
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 2);
    assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
  });
});

for (const providerId of ["openai", "flux"] as const) for (const failure of [false, true]) {
  test(`${providerId} stale regeneration ${failure ? "failure" : "success"} cannot publish, refund or delete a newer claim's work`, async () => {
    await fixture(async ({ db, objects, calls, request, generate }) => {
      seedScene(db);
      db.values.get("illustrationScenes/scene")!.regenerationGenerationSpec = {
        ...generationSpec, imageConfig: snapshotImageGenerationConfig(providerId, {}),
      };
      const gate = barrier();
      generate(async () => {
        if (calls.images === 1) {
          await gate.wait();
          if (failure) throw new Error("Late first provider failure");
        }
        return sharp({ create: { width: 150, height: 100, channels: 3, background: "#336699" } }).webp().toBuffer();
      });
      const first = request("/scenes/scene/regenerate", { targetGeneration: 2, taskId: "regen-scene-2" });
      await gate.entered;
      try {
        db.values.get("illustrationScenes/scene")!.regenerationLeaseUntil = Timestamp.fromMillis(0);
        assert.equal((await request("/scenes/scene/regenerate", { targetGeneration: 2, taskId: "regen-scene-2" })).status, 204);
        assert.equal(db.values.get("users/owner")!.creditsRemaining, 1);
        assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
      } finally { gate.release(); }
      assert.equal((await first).status, failure ? 500 : 204);
      const scene = db.values.get("illustrationScenes/scene")!;
      assert.equal(scene.generation, 2);
      assert.equal(scene.status, "ready_locked");
      assert(objects.has(String(scene.imageObject)));
      assert(objects.has(String(scene.thumbnailObject)));
      assert.equal(objects.size, providerId === "flux" ? 1 : 2);
      assert.equal(db.values.get(reservationPath("scene:generation:2"))!.state, "committed");
      assert.equal(db.values.get("users/owner")!.creditsRemaining, 1);
      assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
    });
  });
}

test("new chapter lease resumes the prose-free plan and fences a delayed old provider", async () => {
  await fixture(async ({ db, objects, calls, request, generate, generations }) => {
    seedJob(db);
    const gate = barrier();
    generate(async () => {
      if (calls.images === 1) await gate.wait();
      return sharp({ create: { width: 150, height: 100, channels: 3, background: "#336699" } }).webp().toBuffer();
    });
    const first = request("/jobs/job");
    await gate.entered;
    try {
      assert(!db.values.has("illustrationJobInputs/job"));
      db.values.get("users/owner/books/book")!.profile = { ...profile, providerId: "flux", style: "Changed", revision: 2 };
      process.env.OPENAI_IMAGE_MODEL = "new-live-model";
      process.env.OPENAI_IMAGE_ORCHESTRATOR_MODEL = "new-live-orchestrator";
      db.values.get("illustrationJobs/job")!.leaseUntil = Timestamp.fromMillis(0);
      assert.equal((await request("/jobs/job")).status, 204);
    } finally { gate.release(); }
    assert.equal((await first).status, 204);
    assert.equal(calls.selection, 1);
    assert.equal(calls.images, 2);
    assert.deepEqual(generations.map(item => item.config), [imageConfig, imageConfig]);
    assert.equal((db.values.get(`illustrationScenes/${sceneId}`)!.generationSpec as SceneGenerationSpec).style, "Painted");
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 1);
    assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
    assert.equal(db.values.get(reservationPath(sceneId))!.state, "committed");
    assert.equal(db.values.get("illustrationJobs/job")!.status, "complete");
    assert.equal(objects.size, 2);
    assert(objects.has(String(db.values.get(`illustrationScenes/${sceneId}`)!.imageObject)));
  });
});

test("paid regeneration enqueue failure is repaired with the same intent and one credit", async () => {
  await fixture(async ({ db, objects, calls, request, enqueue, generations }) => {
    seedScene(db);
    db.values.get("illustrationScenes/scene")!.status = "unlocked";
    db.values.get("users/owner/books/book")!.profile = { ...profile, providerId: "qwen", style: "Ink", revision: 2 };
    const originalAnchor = db.values.get("illustrationScenes/scene")!.anchor;
    const pendingSpec = { ...generationSpec, style: "Ink", imageConfig: snapshotImageGenerationConfig("qwen", {}) };
    const submitted: Array<{ path: string; body: Data; id: string }> = [];
    enqueue(async (path, body, id) => {
      submitted.push({ path, body, id });
      if (submitted.length === 1) throw new Error("Transient Cloud Tasks failure");
    });
    assert.equal((await request("/api/scenes/scene/regenerate")).status, 500);
    assert.equal(db.values.get("illustrationScenes/scene")!.status, "regenerating");
    assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
    assert.deepEqual(db.values.get("illustrationScenes/scene")!.regenerationGenerationSpec, pendingSpec);
    db.values.get("users/owner/books/book")!.profile = { ...profile, providerId: "flux", style: "Changed again", revision: 3 };
    process.env.OPENAI_IMAGE_MODEL = "changed-after-admission";
    assert.equal((await request("/api/scenes/scene/regenerate")).status, 202);
    assert.deepEqual(submitted[1], submitted[0]);
    assert.deepEqual(db.values.get("illustrationScenes/scene")!.regenerationGenerationSpec, pendingSpec);
    assert.equal((await request("/scenes/scene/regenerate", submitted[1]!.body)).status, 204);
    assert.equal((await request("/scenes/scene/regenerate", submitted[1]!.body)).status, 204);
    assert.equal(calls.images, 1);
    const published = db.values.get("illustrationScenes/scene")!;
    assert.deepEqual(published.generationSpec, pendingSpec);
    assert.deepEqual(published.anchor, originalAnchor);
    assert.deepEqual(generations.map(item => item.config), [pendingSpec.imageConfig]);
    assert(generations[0]!.prompt.includes("Ink"));
    for (const field of ["regenerationGenerationSpec", "regenerationPreviousStatus", "regenerationTarget",
      "regenerationRefresh", "regenerationTaskId", "regenerationToken", "regenerationLeaseUntil"]) assert(!(field in published));
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 1);
    assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
    assert.equal(objects.size, 2);
  });
});

test("unlock repairs failed free-refresh enqueue without changing billing intent", async () => {
  await fixture(async ({ db, request, enqueue, generations }) => {
    seedScene(db);
    db.values.get("illustrationScenes/scene")!.status = "unlocked";
    db.values.get("users/owner/books/book")!.profile = { ...profile, providerId: "flux", style: "Charcoal", revision: 2 };
    process.env.OPENAI_IMAGE_MODEL = "changed-model-before-free-refresh";
    const submitted: Array<{ body: Data; id: string }> = [];
    enqueue(async (_path, body, id) => {
      submitted.push({ body, id });
      if (submitted.length === 1) throw new Error("Transient Cloud Tasks failure");
    });
    assert.equal((await request("/api/scenes/scene/unlock")).status, 500);
    assert.equal((await request("/api/scenes/scene/regenerate")).status, 202);
    assert.deepEqual(submitted[1], submitted[0]);
    assert.equal(submitted[1]!.body.refresh, true);
    assert.deepEqual(db.values.get("illustrationScenes/scene")!.regenerationGenerationSpec, generationSpec);
    assert.equal((await request("/scenes/scene/regenerate", { ...submitted[1]!.body, refresh: false })).status, 204);
    assert.deepEqual(generations.map(item => item.config), [imageConfig]);
    assert.deepEqual(db.values.get("illustrationScenes/scene")!.generationSpec, generationSpec);
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 2);
    assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
    assert(!db.values.has(reservationPath("scene:generation:2")));
    assert.equal((await request("/api/scenes/scene/unlock")).status, 200);
  });
});

test("a failed paid generation can be requested again with a new task identity and one net charge", async () => {
  await fixture(async ({ db, calls, request, enqueue, generate }) => {
    seedScene(db);
    db.values.get("illustrationScenes/scene")!.status = "unlocked";
    const submitted: Array<{ body: Data; id: string }> = [];
    enqueue(async (_path, body, id) => { submitted.push({ body, id }); });
    generate(async () => { throw new Error("First provider failure"); });
    assert.equal((await request("/api/scenes/scene/regenerate")).status, 202);
    assert.equal((await request("/scenes/scene/regenerate", submitted[0]!.body)).status, 500);
    assert.equal((await request("/api/scenes/scene/regenerate")).status, 202);
    assert.notEqual(submitted[1]!.id, submitted[0]!.id);
    assert.equal(submitted[1]!.body.targetGeneration, submitted[0]!.body.targetGeneration);
    assert.equal((await request("/scenes/scene/regenerate", submitted[0]!.body)).status, 204);
    assert.equal(calls.images, 1, "An old task cannot claim the newer regeneration intent");
    generate(async () => sharp({ create: { width: 150, height: 100, channels: 3, background: "#336699" } }).webp().toBuffer());
    assert.equal((await request("/scenes/scene/regenerate", submitted[1]!.body)).status, 204);
    assert.equal(calls.images, 2);
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 1);
    assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
  });
});

for (const kind of ["chapter", "regeneration"] as const) {
  test(`late ${kind} provider failure leaves a replacement claim's reserved credit intact`, async () => {
    await fixture(async ({ db, calls, request, generate }) => {
      if (kind === "chapter") seedJob(db); else seedScene(db);
      const firstGate = barrier(), secondGate = barrier();
      generate(async () => {
        if (calls.images === 1) { await firstGate.wait(); throw new Error("Stale provider failure"); }
        await secondGate.wait();
        return sharp({ create: { width: 150, height: 100, channels: 3, background: "#336699" } }).webp().toBuffer();
      });
      const path = kind === "chapter" ? "/jobs/job" : "/scenes/scene/regenerate";
      const body = kind === "chapter" ? {} : { targetGeneration: 2, taskId: "regen-scene-2" };
      const first = request(path, body);
      await firstGate.entered;
      const record = db.values.get(kind === "chapter" ? "illustrationJobs/job" : "illustrationScenes/scene")!;
      record[kind === "chapter" ? "leaseUntil" : "regenerationLeaseUntil"] = Timestamp.fromMillis(0);
      const second = request(path, body);
      await secondGate.entered;
      try {
        const token = record[kind === "chapter" ? "claimToken" : "regenerationToken"];
        const reservation = reservationPath(kind === "chapter" ? sceneId : "scene:generation:2");
        // Fetch the replacement value rather than the pre-transaction snapshot.
        const currentToken = db.values.get(kind === "chapter" ? "illustrationJobs/job" : "illustrationScenes/scene")![kind === "chapter" ? "claimToken" : "regenerationToken"];
        assert.notEqual(currentToken, token);
        firstGate.release();
        assert.equal((await first).status, kind === "chapter" ? 204 : 500);
        assert.equal(db.values.get(reservation)!.claimToken, currentToken);
        assert.equal(db.values.get(reservation)!.state, "reserved");
        assert.equal(db.values.get("users/owner")!.creditsRemaining, 2);
        assert.equal(db.values.get("users/owner")!.creditsReserved, 1);
        assert.equal(db.values.get(kind === "chapter" ? "illustrationJobs/job" : "illustrationScenes/scene")![kind === "chapter" ? "claimToken" : "regenerationToken"], currentToken);
      } finally { firstGate.release(); secondGate.release(); }
      assert.equal((await second).status, 204);
      assert.equal(db.values.get("users/owner")!.creditsRemaining, 1);
      assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
    });
  });
}

test("foreign scene regeneration, unlock and deletion never enqueue or mutate owned work", async () => {
  await fixture(async ({ db, request, enqueue }) => {
    seedScene(db);
    db.values.get("illustrationScenes/scene")!.uid = "other";
    enqueue(async () => { assert.fail("An unauthorized scene must not enqueue work"); });
    const before = [...db.values].map(([path, data]) => [path, { ...data }]);
    assert.equal((await request("/api/scenes/scene/regenerate")).status, 404);
    assert.equal((await request("/api/scenes/scene/unlock")).status, 404);
    assert.equal((await request("/api/scenes/scene", {}, "DELETE")).status, 404);
    assert.deepEqual([...db.values], before);
  });
});

for (const kind of ["chapter", "regeneration"] as const) {
  test(`expired ${kind} claim returns retryable failure and the next lease reuses its reservation`, async () => {
    await fixture(async ({ db, objects, calls, request, generate }) => {
      if (kind === "chapter") seedJob(db); else seedScene(db);
      const gate = barrier();
      generate(async () => {
        if (calls.images === 1) await gate.wait();
        return sharp({ create: { width: 150, height: 100, channels: 3, background: "#336699" } }).webp().toBuffer();
      });
      const path = kind === "chapter" ? "/jobs/job" : "/scenes/scene/regenerate";
      const body = kind === "chapter" ? {} : { targetGeneration: 2, taskId: "regen-scene-2" };
      const pending = request(path, body);
      await gate.entered;
      db.values.get(kind === "chapter" ? "illustrationJobs/job" : "illustrationScenes/scene")![kind === "chapter" ? "leaseUntil" : "regenerationLeaseUntil"] = Timestamp.fromMillis(0);
      gate.release();
      assert.equal((await pending).status, 409);
      assert.equal(objects.size, 0);
      assert.equal(db.values.get("users/owner")!.creditsRemaining, 2);
      assert.equal(db.values.get("users/owner")!.creditsReserved, 1);
      assert.equal((await request(path, body)).status, 204);
      assert.equal(db.values.get("users/owner")!.creditsRemaining, 1);
      assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
      assert.equal(objects.size, 2);
      if (kind === "chapter") {
        assert.equal(calls.selection, 1);
      }
    });
  });
}

for (const [providerId, format, mimeType, extension] of [
  ["openai", "webp", "image/webp", "webp"],
  ["google", "png", "image/png", "png"],
  ["seedream", "jpeg", "image/jpeg", "jpg"],
  ["qwen", "png", "image/png", "png"],
  ["xai", "jpeg", "image/jpeg", "jpg"],
  ["flux", "jpeg", "image/jpeg", "jpg"],
] as const) {
  test(`${providerId} publication preserves native ${mimeType} bytes and distinct preview ownership`, async () => {
    await fixture(async ({ db, objects, contentTypes, moderatedImages, request, generate, generations }) => {
      seedJob(db);
      const config = snapshotImageGenerationConfig(providerId, {});
      const job = db.values.get("illustrationJobs/job")!;
      job.profile = { ...profile, providerId };
      job.imageConfig = config;
      const original = await sharp({ create: { width: 1500, height: 1000, channels: 3, background: "#334455" } })
        .withMetadata({ exif: { IFD0: { Copyright: "Provider-original provenance" } } }).toFormat(format).toBuffer();
      generate(async () => original);
      assert.equal((await request("/jobs/job")).status, 204);
      const scene = db.values.get(`illustrationScenes/${sceneId}`)!;
      const imageObject = String(scene.imageObject), thumbnailObject = String(scene.thumbnailObject);
      assert.deepEqual(generations[0]!.config, config);
      assert.equal(scene.imageMimeType, mimeType);
      assert(imageObject.endsWith(`.${extension}`));
      assert.deepEqual(objects.get(imageObject), original);
      assert.equal(contentTypes.get(imageObject), mimeType);
      assert.deepEqual(moderatedImages, [{ bytes: original, mimeType }]);
      assert.equal(scene.thumbnailUsesOriginal, providerId === "flux");
      if (providerId === "flux") {
        assert.equal(imageObject, thumbnailObject);
        assert.equal(scene.thumbnailMimeType, mimeType);
        assert.equal(objects.size, 1);
        assert.equal(db.events.filter(event => event === `save:${imageObject}`).length, 1);
      } else {
        assert.notEqual(imageObject, thumbnailObject);
        assert.equal(scene.thumbnailMimeType, "image/webp");
        assert.equal(contentTypes.get(thumbnailObject), "image/webp");
        const thumbnail = await sharp(objects.get(thumbnailObject)!).metadata();
        assert.equal(thumbnail.format, "webp");
        assert.equal(thumbnail.width, 640);
        assert.equal(objects.size, 2);
      }
      const unlocked = await request(`/api/scenes/${sceneId}/unlock`);
      assert.equal(unlocked.status, 200);
      const body = await unlocked.json() as Data;
      assert.equal(body.imageMimeType, mimeType);
      assert.equal(body.thumbnailMimeType, scene.thumbnailMimeType);
      assert.equal(body.thumbnailUsesOriginal, providerId === "flux");
      assert.equal(body.generation, 1);
      if (providerId === "flux") {
        assert.equal(body.imageUrl, body.thumbnailUrl);
        assert.equal(db.events.filter(event => event === `sign:${imageObject}`).length, 1);
      }
      assert.equal((await request(`/api/scenes/${sceneId}`, {}, "DELETE")).status, 204);
      assert.equal(objects.size, 0);
      assert.equal(db.events.filter(event => event === `delete-object:${imageObject}`).length, 1);
      assert.equal(db.values.get("users/owner")!.creditsRemaining, 1, "Deleting committed art does not refund spending");
    });
  });
}

test("diagnostic source publishes the rendered prompt through the normal pipeline and settles one credit", async () => {
  await fixture(async ({ db, objects, generations, request, generate }) => {
    seedJob(db);
    const job = db.values.get("illustrationJobs/job")!;
    job.profile = { ...profile, providerId: "diagnostic" };
    job.imageConfig = snapshotImageGenerationConfig("diagnostic", {});
    generate(async (_config, sentPrompt, references) => renderPromptImage(sentPrompt, references.length));
    assert.equal((await request("/jobs/job")).status, 204);
    const scene = db.values.get(`illustrationScenes/${sceneId}`)!;
    const published = objects.get(String(scene.imageObject))!;
    assert.deepEqual(published, await renderPromptImage(generations[0]!.prompt, generations[0]!.references.length));
    assert.equal((await sharp(published).metadata()).width, 1536);
    assert.equal(scene.imageMimeType, "image/png");
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 1);
    assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
    const unlocked = await (await request(`/api/scenes/${sceneId}/unlock`)).json() as Data;
    assert.equal(unlocked.imageMimeType, "image/png");
  });
});

for (const kind of ["chapter", "regeneration"] as const) {
  test(`${kind} validates frozen credentials before reserving any credit`, async () => {
    await fixture(async ({ db, request, credentials, calls }) => {
      if (kind === "chapter") seedJob(db); else seedScene(db);
      let credentialChecks = 0;
      credentials(config => {
        credentialChecks++;
        assert.deepEqual(config, imageConfig);
        assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
        assert(![...db.values.keys()].some(path => path.startsWith("creditReservations/")));
        throw new Error("Selected source is not configured");
      });
      const response = await request(kind === "chapter" ? "/jobs/job" : "/scenes/scene/regenerate",
        kind === "chapter" ? {} : { targetGeneration: 2, taskId: "regen-scene-2" });
      assert.equal(response.status, 500);
      assert.equal(credentialChecks, 1);
      assert.equal(calls.images, 0);
      assert.equal(db.values.get("users/owner")!.creditsRemaining, 2);
      assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
      assert(![...db.values.keys()].some(path => path.startsWith("creditReservations/")));
      if (kind === "regeneration") {
        const scene = db.values.get("illustrationScenes/scene")!;
        assert.equal(scene.status, "unlocked");
        assert.deepEqual(scene.generationSpec, generationSpec);
        assert.equal(scene.failureCategory, "regeneration_failed");
        assert(!("regenerationGenerationSpec" in scene));
      }
    });
  });
}

test("unavailable paid source rejects admission without changing recipe, assets, credits or task intent", async () => {
  await fixture(async ({ db, request, enqueue }) => {
    seedScene(db);
    db.values.get("illustrationScenes/scene")!.status = "unlocked";
    db.values.get("users/owner/books/book")!.profile = { ...profile, providerId: "google", style: "Ink", revision: 2 };
    process.env.IMAGE_PROVIDERS = "openai";
    enqueue(async () => { assert.fail("Unavailable sources cannot enqueue"); });
    const before = [...db.values].map(([path, value]) => [path, { ...value }]);
    const response = await request("/api/scenes/scene/regenerate");
    assert.equal(response.status, 503);
    assert.deepEqual(await response.json(), { error: "The selected illustration source is unavailable." });
    assert.deepEqual([...db.values], before);
  });
});

for (const kind of ["chapter", "regeneration"] as const) {
  for (const invalid of ["missing"] as const) {
    test(`${kind} ${invalid} task is acknowledged without claiming, accounting or generation`, async () => {
      await fixture(async ({ db, request, calls, credentials }) => {
        if (kind === "chapter") seedJob(db); else seedScene(db);
        const operationPath = kind === "chapter" ? "illustrationJobs/job" : "illustrationScenes/scene";
        if (invalid === "missing") db.values.delete(operationPath);
        credentials(() => { assert.fail("Missing tasks must not validate credentials"); });
        const before = [...db.values].map(([path, value]) => [path, { ...value }]);
        assert.equal((await request(kind === "chapter" ? "/jobs/job" : "/scenes/scene/regenerate",
          kind === "chapter" ? {} : { targetGeneration: 2, taskId: "regen-scene-2" })).status, 204);
        assert.deepEqual([...db.values], before);
        assert.deepEqual(calls, { selection: 0, images: 0 });
        assert.equal(db.events.length, 0);
      });
    });
  }
}

test("FLUX paid replacement saves one original, settles its recipe, then deletes the previous alias once", async () => {
  await fixture(async ({ db, objects, request, generate, enqueue, generations }) => {
    seedScene(db);
    const originalObject = "users/owner/books/book/scenes/scene.1.jpg";
    const publishedSpec = { ...generationSpec, imageConfig: snapshotImageGenerationConfig("flux", {}) };
    const initial = db.values.get("illustrationScenes/scene")!;
    Object.assign(initial, { status: "unlocked", generationSpec: publishedSpec,
      imageObject: originalObject, thumbnailObject: originalObject, thumbnailUsesOriginal: true,
      imageMimeType: "image/jpeg", thumbnailMimeType: "image/jpeg" });
    db.values.get("users/owner/books/book")!.profile = { ...profile, providerId: "flux", style: "Ink", revision: 2 };
    const oldBytes = await sharp({ create: { width: 150, height: 100, channels: 3, background: "#223344" } }).jpeg().toBuffer();
    objects.set(originalObject, oldBytes);
    let submitted!: Data;
    enqueue(async (_path, body) => { submitted = body; });
    const replacement = await sharp({ create: { width: 150, height: 100, channels: 3, background: "#556677" } })
      .withMetadata({ exif: { IFD0: { Copyright: "Untouched FLUX provenance" } } }).png().toBuffer();
    generate(async () => replacement);
    assert.equal((await request("/api/scenes/scene/regenerate")).status, 202);
    assert.deepEqual(db.values.get("illustrationScenes/scene")!.generationSpec, publishedSpec);
    assert.equal((await request("/scenes/scene/regenerate", submitted)).status, 204);
    const scene = db.values.get("illustrationScenes/scene")!;
    const object = String(scene.imageObject);
    assert.equal(scene.thumbnailObject, object);
    assert.equal(scene.imageMimeType, "image/png");
    assert.equal(scene.thumbnailMimeType, "image/png");
    assert.equal(scene.thumbnailUsesOriginal, true);
    assert.equal(scene.generation, 2);
    assert.deepEqual(scene.generationSpec, { ...publishedSpec, style: "Ink" });
    assert.deepEqual(generations[0]!.config, publishedSpec.imageConfig);
    assert.deepEqual(objects.get(object), replacement);
    assert.equal(objects.size, 1);
    assert.equal(db.events.filter(event => event === `save:${object}`).length, 1);
    assert.equal(db.events.filter(event => event === `delete-object:${originalObject}`).length, 1);
    assert(db.events.indexOf("write:illustrationScenes/scene:ready_locked") < db.events.indexOf(`delete-object:${originalObject}`));
    assert.equal(db.values.get(reservationPath("scene:generation:2"))!.state, "committed");
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 1);
    assert.equal((await request("/scenes/scene/regenerate", submitted)).status, 204);
    assert.equal(db.events.filter(event => event === `save:${object}`).length, 1);
    assert.equal((await request("/api/scenes/scene", {}, "DELETE")).status, 204);
    assert.equal(db.events.filter(event => event === `delete-object:${object}`).length, 1);
    assert.equal(objects.size, 0);
  });
});

test("failed FLUX alias save refunds only its owned reservation and retains the prior committed art and recipe", async () => {
  await fixture(async ({ db, objects, image, request, save }) => {
    seedScene(db);
    const scene = db.values.get("illustrationScenes/scene")!;
    scene.thumbnailObject = oldImageObject;
    scene.regenerationPreviousStatus = "ready_locked";
    scene.regenerationGenerationSpec = { ...generationSpec, style: "Changed", imageConfig: snapshotImageGenerationConfig("flux", {}) };
    const oldBytes = image;
    objects.set(oldImageObject, oldBytes);
    let attemptedObject = "";
    save(async path => {
      attemptedObject = path;
      objects.set(path, Buffer.from("Late partial upload"));
      throw new Error("Storage save failed");
    });
    assert.equal((await request("/scenes/scene/regenerate", { targetGeneration: 2, taskId: "regen-scene-2" })).status, 500);
    const retained = db.values.get("illustrationScenes/scene")!;
    assert.equal(retained.status, "ready_locked");
    assert.equal(retained.generation, 1);
    assert.equal(retained.failureCategory, "regeneration_failed");
    assert.deepEqual(retained.generationSpec, generationSpec);
    assert.deepEqual(objects.get(oldImageObject), oldBytes);
    assert.deepEqual([...objects.keys()], [oldImageObject]);
    assert.equal(db.events.filter(event => event === `delete-object:${attemptedObject}`).length, 1);
    assert(!db.events.includes(`delete-object:${oldImageObject}`));
    assert.equal(db.values.get(reservationPath("scene:generation:2"))!.state, "refunded");
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 2);
    assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
    assert(!("regenerationGenerationSpec" in retained));
  });
});

for (const deletion of ["scene", "book", "account"] as const) {
  test(`FLUX aliased save cannot publish after ${deletion} deletion`, async () => {
    await fixture(async ({ db, objects, request, save }) => {
      seedScene(db);
      db.values.get("illustrationScenes/scene")!.regenerationGenerationSpec = {
        ...generationSpec, imageConfig: snapshotImageGenerationConfig("flux", {}),
      };
      const gate = barrier();
      save(async () => { await gate.wait(); });
      const pending = request("/scenes/scene/regenerate", { targetGeneration: 2, taskId: "regen-scene-2" });
      await gate.entered;
      try {
        const path = deletion === "scene" ? "/api/scenes/scene" : deletion === "book" ? "/api/books/book" : "/api/account";
        assert.equal((await request(path, {}, "DELETE")).status, 204);
      } finally { gate.release(); }
      assert.equal((await pending).status, 204);
      assert.equal(objects.size, 0);
      const newDeletes = db.events.filter(event => event.startsWith("delete-object:") && event.includes(".2.claim-"));
      assert.equal(newDeletes.length, 1);
      if (deletion === "account") assert(!db.values.has("users/owner"));
      else {
        assert.equal(db.values.get("users/owner")!.creditsRemaining, 2);
        assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
      }
    });
  });
}

test("an empty selection completes the job without images or credits", async () => {
  await fixture(async ({ db, calls, request, select }) => {
    seedJob(db);
    select(async () => []);
    assert.equal((await request("/jobs/job")).status, 204);
    assert.equal(db.values.get("illustrationJobs/job")!.status, "complete");
    assert.equal(calls.images, 0);
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 2);
    assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
    assert(![...db.values.keys()].some(path => path.startsWith("illustrationScenes/")));
  });
});

test("a confirmed scene is visible as generating until its image publishes", async () => {
  await fixture(async ({ db, request, generate }) => {
    seedJob(db);
    const gate = barrier();
    generate(async () => {
      await gate.wait();
      return sharp({ create: { width: 150, height: 100, channels: 3, background: "#336699" } }).webp().toBuffer();
    });
    const pending = request("/jobs/job");
    await gate.entered;
    try {
      const scene = db.values.get(`illustrationScenes/${sceneId}`)!;
      assert.equal(scene.status, "generating");
      assert.equal(scene.generation, 0);
      assert.equal(scene.altText, "Illustration of the passage beginning “A traveler enters the courtyard.”");
      assert.equal(scene.caption, "");
      assert.equal(db.values.get(reservationPath(sceneId))!.state, "reserved");
    } finally { gate.release(); }
    assert.equal((await pending).status, 204);
    const scene = db.values.get(`illustrationScenes/${sceneId}`)!;
    assert.equal(scene.status, "ready_locked");
    assert.equal(scene.generation, 1);
    assert.equal((scene.generationSpec as SceneGenerationSpec).sceneText, "A traveler enters the courtyard.");
    assert.equal(db.values.get(reservationPath(sceneId))!.state, "committed");
  });
});

test("generation errors fail the scene record and refund its reservation", async () => {
  await fixture(async ({ db, request, generate }) => {
    seedJob(db);
    generate(async () => { throw new Error("local provider failure"); });
    assert.equal((await request("/jobs/job")).status, 204);
    const scene = db.values.get(`illustrationScenes/${sceneId}`)!;
    assert.equal(scene.status, "failed");
    assert.equal(scene.failureCategory, "generation_failed");
    assert.equal(db.values.get(reservationPath(sceneId))!.state, "refunded");
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 2);
    assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
  });
});

test("a lease takeover resumes an existing generating record and charges one credit", async () => {
  await fixture(async ({ db, calls, request }) => {
    seedJob(db);
    db.values.delete("illustrationJobInputs/job");
    db.values.get("illustrationJobs/job")!.plan = { scenes: [{ id: sceneId, paragraphOrdinal: 0,
      anchor: { href: "chapter.xhtml", spineOrdinal: 0, paragraphId: "paragraph", fallbackProgression: 0.5 },
      altText: "Alt", caption: "", sceneText: "A traveler enters the courtyard." }] };
    db.values.set(`illustrationScenes/${sceneId}`, { uid: "owner", bookId: "book", jobId: "job",
      chapterOrdinal: 0, paragraphOrdinal: 0, status: "generating", generation: 0, altText: "Alt", caption: "" });
    db.values.set(reservationPath(sceneId), { uid: "owner", bookId: "book", operationId: sceneId,
      claimToken: "dead-lease", sceneId, state: "reserved" });
    db.values.get("users/owner")!.creditsReserved = 1;
    assert.equal((await request("/jobs/job")).status, 204);
    assert.equal(calls.images, 1);
    assert.equal(calls.selection, 0);
    assert.equal(db.values.get(`illustrationScenes/${sceneId}`)!.status, "ready_locked");
    assert.equal(db.values.get(reservationPath(sceneId))!.state, "committed");
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 1);
    assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
  });
});
