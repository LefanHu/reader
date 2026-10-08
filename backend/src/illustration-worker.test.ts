import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import express from "express";
import { FieldValue, Timestamp, type Firestore } from "firebase-admin/firestore";
import type { Storage } from "@google-cloud/storage";
import sharp from "sharp";
import { composeImagePrompt } from "./openai.js";
import { HttpError } from "./illustration-http.js";
import { illustrationWorkerRouter } from "./illustration-worker.js";
import { illustrationSceneRouter } from "./illustration-scenes.js";
import { illustrationBookDeletion } from "./illustration-books.js";
import { accountDeletionRouter } from "./account.js";
import { NarrationBackend } from "./narration.js";
import type { ChapterInput, NarrativeAnalysis } from "./types.js";

type Data = Record<string, unknown>;
const hash = (value: string) => createHash("sha256").update(value).digest("hex");
const reservationPath = (operation: string) => `creditReservations/${hash(`owner:${operation}`)}`;

/** Match Firestore's default rejection of undefined, including nested scene recipes. */
function assertFirestoreData(value: unknown): void {
  assert.notEqual(value, undefined, "Firestore cannot store undefined fields");
  if (value && typeof value === "object" && !(value instanceof FieldValue) && !(value instanceof Timestamp)) {
    for (const field of Object.values(value)) assertFirestoreData(field);
  }
}
/** Operations supported by this worker's transactional/batch fixture boundary. */
interface Writer {
  set(reference: Reference, data: Data, options?: { merge: boolean }): void;
  create(reference: Reference, data: Data): void;
  update(reference: Reference, data: Data): void;
  delete(reference: Reference): void;
  commit(): Promise<void>;
}
interface Snapshot {
  exists: boolean;
  id: string;
  data(): Data | undefined;
  ref: Reference;
}
interface Transaction extends Writer {
  get(reference: Reference): Promise<Snapshot>;
}

/** Serializes transactions and delays writes until commit; no cloud clients are used. */
class Database {
  values = new Map<string, Data>();
  events: string[] = [];
  private tail = Promise.resolve();
  collection(path: string) { return new Collection(this, path); }
  async runTransaction<T>(action: (transaction: Transaction) => Promise<T>): Promise<T> {
    const result = this.tail.then(async () => {
      const writer = this.writer();
      const value = await action({ ...writer, get: reference => reference.get() });
      await writer.commit();
      return value;
    });
    this.tail = result.then(() => {}, () => {});
    return result;
  }
  writer(): Writer {
    const pending: Array<() => void> = [];
    return {
      set: (reference: Reference, data: Data, options?: { merge: boolean }) => {
        pending.push(() => reference.write(data, options?.merge));
      },
      create: (reference: Reference, data: Data) => {
        pending.push(() => {
          assert(!this.values.has(reference.path));
          reference.write(data);
        });
      },
      update: (reference: Reference, data: Data) => {
        pending.push(() => { assert(this.values.has(reference.path)); reference.write(data, true); });
      },
      delete: (reference: Reference) => { pending.push(() => { this.values.delete(reference.path); this.events.push(`delete:${reference.path}`); }); },
      commit: async () => { for (const operation of pending) operation(); },
    };
  }
  batch() { return this.writer(); }
  bulkWriter() {
    const writer = this.writer();
    return { set: writer.set, delete: writer.delete, close: writer.commit };
  }
  async recursiveDelete(reference: Reference) {
    for (const path of this.values.keys()) if (path === reference.path || path.startsWith(`${reference.path}/`)) this.values.delete(path);
  }
}
class Reference {
  constructor(readonly db: Database, readonly path: string) {}
  get id() { return this.path.split("/").at(-1)!; }
  collection(path: string) { return this.db.collection(`${this.path}/${path}`); }
  async get() {
    const data = this.db.values.get(this.path);
    return { exists: data !== undefined, id: this.id, ref: this, data: () => data && { ...data } };
  }
  write(data: Data, merge = false) {
    assertFirestoreData(data);
    const value: Data = merge ? { ...this.db.values.get(this.path) } : {};
    for (const [key, field] of Object.entries(data)) {
      if (field instanceof FieldValue) {
        if (field.isEqual(FieldValue.delete())) delete value[key];
        else if (field.isEqual(FieldValue.serverTimestamp())) value[key] = Timestamp.now();
        else if (field.isEqual(FieldValue.increment(1))) value[key] = Number(value[key] ?? 0) + 1;
        else if (field.isEqual(FieldValue.increment(-1))) value[key] = Number(value[key] ?? 0) - 1;
        else throw new Error("Unsupported field transform in illustration fixture");
      } else value[key] = field;
    }
    this.db.values.set(this.path, value);
    this.db.events.push(`write:${this.path}:${String(value.state ?? value.status ?? "")}`);
  }
  async set(data: Data, options?: { merge: boolean }) { this.write(data, options?.merge); }
  async update(data: Data) { assert(this.db.values.has(this.path)); this.write(data, true); }
  async delete() { this.db.values.delete(this.path); this.db.events.push(`delete:${this.path}`); }
}
class Collection {
  constructor(readonly db: Database, readonly path: string, readonly filters: Array<[string, unknown]> = []) {}
  doc(id: string) { return new Reference(this.db, `${this.path}/${id}`); }
  where(key: string, operation: string, value: unknown) {
    assert.equal(operation, "==");
    return new Collection(this.db, this.path, [...this.filters, [key, value]]);
  }
  async get() {
    const docs = [];
    for (const [path, data] of this.db.values) {
      if (path.startsWith(`${this.path}/`) && !path.slice(this.path.length + 1).includes("/") &&
        this.filters.every(([key, value]) => data[key] === value)) {
        docs.push(await new Reference(this.db, path).get());
      }
    }
    return { docs };
  }
}

const input: ChapterInput = {
  href: "chapter.xhtml", styleVersion: 1, analysisVersion: 1, density: 1,
  paragraphs: [{ id: "paragraph", text: "A traveler enters the courtyard.",
    cssSelector: "#paragraph", ordinal: 0, progression: 0.5 }],
};
const analysis: NarrativeAnalysis = {
  entityDeltas: [{ entityRef: "traveler", kind: "character", anchorParagraphId: "paragraph",
    name: "Traveler", aliases: [], summary: "A traveler", visualDescription: "A blue coat", stateFacts: [] }],
  scenes: [{ startParagraphId: "paragraph", endParagraphId: "paragraph", salience: 1,
    facts: ["A traveler enters a courtyard."], entityRefs: ["traveler"],
    altText: "Traveler in courtyard", caption: "Arrival", contentTags: [] }],
};
const sceneId = hash("job:paragraph:paragraph").slice(0, 40);
const oldImageObject = "users/owner/books/book/scenes/scene.v1.webp";
const oldThumbnailObject = "users/owner/books/book/scenes/scene.v1.thumb.webp";

async function fixture(action: (harness: {
  db: Database; objects: Map<string, Buffer>; calls: { analysis: number; images: number };
  request: (path: string, body?: Data, method?: string) => Promise<Response>;
  generate: (implementation: () => Promise<Buffer>) => void;
  analyze: (implementation: () => Promise<NarrativeAnalysis>) => void;
  save: (implementation: (path: string) => Promise<void>) => void;
  enqueue: (implementation: (path: string, body: Data, id: string) => Promise<void>) => void;
}) => Promise<void>) {
  const db = new Database();
  const objects = new Map<string, Buffer>();
  const calls = { analysis: 0, images: 0 };
  const image = await sharp({ create: { width: 2, height: 2, channels: 3, background: "#336699" } }).webp().toBuffer();
  let generate: () => Promise<Buffer> = async () => image;
  let analyze: () => Promise<NarrativeAnalysis> = async () => analysis;
  let save: (path: string) => Promise<void> = async () => {};
  let enqueue: (path: string, body: Data, id: string) => Promise<void> = async () => {};
  const storage = { bucket: () => ({
    deleteFiles: async ({ prefix }: { prefix: string }) => {
      for (const path of objects.keys()) if (path.startsWith(prefix)) objects.delete(path);
    },
    file: (path: string) => ({
      download: async () => { assert(objects.has(path)); return [objects.get(path)!]; },
      save: async (bytes: Buffer) => { await save(path); objects.set(path, bytes); db.events.push(`save:${path}`); },
      delete: async () => { objects.delete(path); db.events.push(`delete-object:${path}`); },
      getSignedUrl: async () => [`https://private.invalid/${path}`],
    }),
  }) } as unknown as Storage;
  const app = express();
  app.use(express.json());
  app.use("/v1", (req, _res, next) => { (req as express.Request & { uid: string }).uid = "owner"; next(); });
  app.use("/v1", illustrationSceneRouter({
    db: db as unknown as Firestore, storage, bucket: "private",
    requireFeature: (_req, _res, next) => next(),
    enqueue: (path, body, id) => enqueue(path, body, id),
  }));
  app.delete("/v1/books/:bookId", illustrationBookDeletion({ db: db as unknown as Firestore, storage, bucket: "private" }));
  const narration = new NarrationBackend({ db: db as unknown as Firestore, storage, bucket: "private",
    enabled: false, enqueue: async () => {}, provider: { generate: async () => { throw new Error("Narration is not exercised"); } } });
  app.use("/v1/account", accountDeletionRouter({ db: db as unknown as Firestore, storage, bucket: "private", narration }));
  app.use("/internal", illustrationWorkerRouter({
    db: db as unknown as Firestore, storage, bucket: "private",
    assetRetentionMilliseconds: 30 * 86400000, composeImagePrompt,
    analyzeNarrative: async () => { calls.analysis++; return analyze(); },
    moderateText: async () => false, moderateImage: async () => false,
    imageGenerationProvider: { generate: async () => { calls.images++; return generate(); } },
  }));
  app.use((error: unknown, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
    res.status(error instanceof HttpError ? error.status : 500)
      .json({ error: error instanceof HttpError ? error.message : "Illustration service failed." });
  });
  const server = app.listen(0, "127.0.0.1");
  await new Promise<void>(resolve => server.on("listening", resolve));
  const address = server.address();
  assert(address && typeof address === "object");
  const url = `http://127.0.0.1:${address.port}`;
  try {
    await action({ db, objects, calls,
      request: (path, body = {}, method = "POST") => fetch(`${url}${path.startsWith("/v1/") ? path : `/internal${path}`}`, {
        method, headers: { "content-type": "application/json" }, ...(method === "DELETE" ? {} : { body: JSON.stringify(body) }),
      }),
      generate: implementation => { generate = implementation; },
      analyze: implementation => { analyze = implementation; },
      save: implementation => { save = implementation; },
      enqueue: implementation => { enqueue = implementation; },
    });
  } finally { await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve())); }
}
function seedJob(db: Database) {
  db.values.set("users/owner", { creditsRemaining: 2, creditsReserved: 0 });
  db.values.set("users/owner/books/book", { profile: { style: "Painted" } });
  db.values.set("illustrationJobs/job", { uid: "owner", bookId: "book", chapterOrdinal: 0, status: "queued" });
  db.values.set("illustrationJobInputs/job", { uid: "owner", bookId: "book", chapterOrdinal: 0, input });
}
function seedScene(db: Database) {
  db.values.set("users/owner", { creditsRemaining: 2, creditsReserved: 0 });
  db.values.set("users/owner/books/book", { profile: { style: "Painted" } });
  db.values.set("illustrationScenes/scene", { uid: "owner", bookId: "book", status: "regenerating",
    regenerationTarget: 2, regenerationRefresh: false, regenerationTaskId: "regen-scene-2",
    generationVersion: 1, imageObject: oldImageObject, thumbnailObject: oldThumbnailObject,
    generationSpec: { style: "Painted", facts: ["A courtyard"], world: [] } });
}

test("completed and actively leased jobs leave input and credits untouched", async () => {
  await fixture(async ({ db, calls, request }) => {
    for (const state of [{ status: "complete" },
      { status: "analyzing", leaseUntil: Timestamp.fromMillis(Date.now() + 600000) }]) {
      seedJob(db);
      db.values.set("illustrationJobs/job", { ...db.values.get("illustrationJobs/job"), ...state });
      const before = [...db.values];
      assert.equal((await request("/jobs/job")).status, 204);
      assert.deepEqual([...db.values], before);
    }
    assert.deepEqual(calls, { analysis: 0, images: 0 });
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
    assert.deepEqual(calls, { analysis: 0, images: 0 });
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 2);
  });
});
test("scene publication follows reservation and prose deletion, then commits a single credit", async () => {
  await fixture(async ({ db, objects, calls, request, generate }) => {
    seedJob(db);
    generate(async () => {
      assert(!db.values.has("illustrationJobInputs/job"));
      assert.equal(db.values.get(reservationPath(sceneId))!.state, "reserved");
      assert.equal(db.values.get("users/owner")!.creditsReserved, 1);
      return sharp({ create: { width: 2, height: 2, channels: 3, background: "#336699" } }).webp().toBuffer();
    });
    assert.equal((await request("/jobs/job")).status, 204);
    const scene = db.values.get(`illustrationScenes/${sceneId}`)!;
    assert.equal(scene.status, "ready_locked");
    assert.equal(scene.generationVersion, 1);
    assert.match(String(scene.imageObject), new RegExp(`^users/owner/books/book/scenes/${sceneId}\\.claim-[\\w-]+\\.webp$`));
    assert(objects.has(String(scene.imageObject)));
    assert(objects.has(String(scene.thumbnailObject)));
    const entityId = hash("book:job:traveler").slice(0, 40);
    assert(db.values.has(`worldRevisions/${hash(`job:${entityId}:paragraph`)}`));
    assert.deepEqual(db.values.get(`worldReferences/${sceneId}`)!.entityIds, [entityId]);
    assert.equal(db.values.get(`worldReferences/${sceneId}`)!.referenceObject, scene.imageObject);
    assert.equal(db.values.get(reservationPath(sceneId))!.state, "committed");
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 1);
    assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
    assert.equal(db.values.get("illustrationJobs/job")!.status, "complete");
    assert(!("leaseUntil" in db.values.get("illustrationJobs/job")!));
    assert(db.events.indexOf(`save:${scene.thumbnailObject}`) < db.events.indexOf(`write:illustrationScenes/${sceneId}:ready_locked`));
    assert(db.events.indexOf(`write:${reservationPath(sceneId)}:committed`) < db.events.indexOf(`write:illustrationScenes/${sceneId}:ready_locked`));
    assert.equal((await request("/jobs/job")).status, 204);
    assert.deepEqual(calls, { analysis: 1, images: 1 });
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 1);
  });
});
test("candidate provider failure refunds its reservation, cleans artifacts and preserves completed analysis", async () => {
  await fixture(async ({ db, objects, request, generate }) => {
    seedJob(db);
    generate(async () => { throw new Error("local provider failure"); });
    assert.equal((await request("/jobs/job")).status, 204);
    assert.equal(db.values.get(reservationPath(sceneId))!.state, "refunded");
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 2);
    assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
    assert.equal(db.values.get("illustrationJobs/job")!.status, "complete");
    assert(!db.values.has(`illustrationScenes/${sceneId}`));
    assert(!db.values.has("illustrationJobInputs/job"));
    assert.equal(objects.size, 0);
    assert(db.events.some(event => event.startsWith(`delete-object:users/owner/books/book/scenes/${sceneId}.claim-`)));
  });
});
test("regeneration lease rejects a second worker and completed target retries never charge twice", async () => {
  await fixture(async ({ db, objects, calls, request, generate }) => {
    seedScene(db);
    objects.set(oldImageObject, Buffer.from("old"));
    objects.set(oldThumbnailObject, Buffer.from("old thumbnail"));
    db.values.set("worldReferences/scene", { referenceObject: oldImageObject });
    let entered!: () => void;
    const started = new Promise<void>(resolve => { entered = resolve; });
    let release!: () => void;
    const hold = new Promise<void>(resolve => { release = resolve; });
    generate(async () => {
      entered();
      await hold;
      return sharp({ create: { width: 2, height: 2, channels: 3, background: "#336699" } }).webp().toBuffer();
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
    assert.equal(db.values.get("illustrationScenes/scene")!.generationVersion, 2);
    assert.equal(db.values.get(reservationPath("scene:generation:2"))!.state, "committed");
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 1);
    assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
    assert.equal(db.values.get("worldReferences/scene")!.referenceObject, db.values.get("illustrationScenes/scene")!.imageObject);
    assert(!objects.has(oldImageObject));
    assert(!objects.has(oldThumbnailObject));
    assert(db.events.indexOf(`write:${reservationPath("scene:generation:2")}:committed`) < db.events.indexOf(`delete-object:${oldImageObject}`));
    assert.equal((await request("/scenes/scene/regenerate", { targetGeneration: 2, taskId: "regen-scene-2" })).status, 204);
    assert.equal(calls.images, 1);
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 1);
  });
});
test("regeneration failure refunds credits, clears the lease and keeps previous assets", async () => {
  await fixture(async ({ db, objects, request, generate }) => {
    seedScene(db);
    objects.set(oldImageObject, Buffer.from("old"));
    objects.set(oldThumbnailObject, Buffer.from("old thumbnail"));
    generate(async () => { throw new Error("local provider failure"); });
    assert.equal((await request("/scenes/scene/regenerate", { targetGeneration: 2, taskId: "regen-scene-2" })).status, 500);
    assert.equal(db.values.get(reservationPath("scene:generation:2"))!.state, "refunded");
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 2);
    assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
    const scene = db.values.get("illustrationScenes/scene")!;
    assert.equal(scene.status, "unlocked");
    assert.equal(scene.failureCategory, "regeneration_failed");
    assert.equal(scene.generationVersion, 1);
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
  test(`chapter analysis cannot recreate history or counters after ${deletion} deletion`, async () => {
    await fixture(async ({ db, objects, request, analyze }) => {
      seedJob(db);
      const gate = barrier();
      analyze(async () => { await gate.wait(); return analysis; });
      const pending = request("/jobs/job");
      await gate.entered;
      try {
        assert.equal((await request(deletion === "book" ? "/v1/books/book" : "/v1/account", {}, "DELETE")).status, 204);
      } finally { gate.release(); }
      assert.equal((await pending).status, 204);
      assert.equal(objects.size, 0);
      assert(!db.values.has("illustrationJobs/job"));
      assert(!db.values.has("illustrationJobInputs/job"));
      assert(![...db.values.keys()].some(path => path.startsWith("worldRevisions/") || path.startsWith("worldReferences/")));
      if (deletion === "account") {
        assert.deepEqual([...db.values.keys()], ["narrationAccountTombstones/owner"]);
      } else {
        assert.equal(db.values.get("users/owner/books/book")!.deleted, true);
        assert.equal(db.values.get("users/owner")!.creditsRemaining, 2);
        assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
        assert(!("worldVersion" in db.values.get("users/owner/books/book")!));
      }
    });
  });
  test(`late chapter image completion cannot recreate ${deletion}-deleted assets, records or credits`, async () => {
    await fixture(async ({ db, objects, request, generate }) => {
      seedJob(db);
      const gate = barrier();
      generate(async () => {
        await gate.wait();
        return sharp({ create: { width: 2, height: 2, channels: 3, background: "#336699" } }).webp().toBuffer();
      });
      const pending = request("/jobs/job");
      await gate.entered;
      try {
        assert.equal(db.values.get("users/owner")!.creditsReserved, 1);
        assert.equal((await request(deletion === "book" ? "/v1/books/book" : "/v1/account", {}, "DELETE")).status, 204);
      } finally { gate.release(); }
      assert.equal((await pending).status, 204);
      assert.equal(objects.size, 0);
      assert(!db.values.has(`illustrationScenes/${sceneId}`));
      assert(!db.values.has("illustrationJobs/job"));
      assert(!db.values.has(reservationPath(sceneId)));
      assert(![...db.values.keys()].some(path => path.startsWith("worldRevisions/") || path.startsWith("worldReferences/")));
      if (deletion === "account") assert.deepEqual([...db.values.keys()], ["narrationAccountTombstones/owner"]);
      else {
        assert.equal(db.values.get("users/owner")!.creditsRemaining, 2);
        assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
        assert(!("worldVersion" in db.values.get("users/owner/books/book")!));
      }
    });
  });
}

for (const deletion of ["scene", "book", "account"] as const) {
  test(`late regeneration cannot publish after ${deletion} deletion`, async () => {
    await fixture(async ({ db, objects, request, generate }) => {
      seedScene(db);
      objects.set(oldImageObject, Buffer.from("old"));
      objects.set(oldThumbnailObject, Buffer.from("old thumbnail"));
      db.values.set("worldReferences/scene", { uid: "owner", bookId: "book", referenceObject: oldImageObject });
      const gate = barrier();
      generate(async () => {
        await gate.wait();
        return sharp({ create: { width: 2, height: 2, channels: 3, background: "#336699" } }).webp().toBuffer();
      });
      const pending = request("/scenes/scene/regenerate", { targetGeneration: 2, taskId: "regen-scene-2" });
      await gate.entered;
      try {
        const path = deletion === "scene" ? "/v1/scenes/scene" : deletion === "book" ? "/v1/books/book" : "/v1/account";
        assert.equal((await request(path, {}, "DELETE")).status, 204);
      } finally { gate.release(); }
      assert.equal((await pending).status, 204);
      assert.equal(objects.size, 0);
      assert(!db.values.has("worldReferences/scene"));
      if (deletion === "scene") {
        assert.equal(objects.size, 0);
        assert.equal(db.values.get("illustrationScenes/scene")!.deleted, true);
        assert.equal((await request("/v1/scenes/scene/unlock")).status, 404);
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
    try { assert.equal((await request("/v1/scenes/scene", {}, "DELETE")).status, 204); }
    finally { gate.release(); }
    assert.equal((await pending).status, 204);
    assert.equal(objects.size, 0);
    assert.equal(db.values.get("illustrationScenes/scene")!.deleted, true);
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 2);
    assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
  });
});

for (const failure of [false, true]) {
  test(`stale regeneration ${failure ? "failure" : "success"} cannot publish, refund or delete a newer claim's work`, async () => {
    await fixture(async ({ db, objects, calls, request, generate }) => {
      seedScene(db);
      const gate = barrier();
      generate(async () => {
        if (calls.images === 1) {
          await gate.wait();
          if (failure) throw new Error("Late first provider failure");
        }
        return sharp({ create: { width: 2, height: 2, channels: 3, background: "#336699" } }).webp().toBuffer();
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
      assert.equal(scene.generationVersion, 2);
      assert.equal(scene.status, "ready_locked");
      assert(objects.has(String(scene.imageObject)));
      assert(objects.has(String(scene.thumbnailObject)));
      assert.equal(objects.size, 2);
      assert.equal(db.values.get(reservationPath("scene:generation:2"))!.state, "committed");
      assert.equal(db.values.get("users/owner")!.creditsRemaining, 1);
      assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
    });
  });
}

test("new chapter lease resumes the prose-free plan and fences a delayed old provider", async () => {
  await fixture(async ({ db, objects, calls, request, generate }) => {
    seedJob(db);
    const gate = barrier();
    generate(async () => {
      if (calls.images === 1) await gate.wait();
      return sharp({ create: { width: 2, height: 2, channels: 3, background: "#336699" } }).webp().toBuffer();
    });
    const first = request("/jobs/job");
    await gate.entered;
    try {
      assert(!db.values.has("illustrationJobInputs/job"));
      db.values.get("illustrationJobs/job")!.leaseUntil = Timestamp.fromMillis(0);
      assert.equal((await request("/jobs/job")).status, 204);
    } finally { gate.release(); }
    assert.equal((await first).status, 204);
    assert.equal(calls.analysis, 1);
    assert.equal(calls.images, 2);
    assert.equal(db.values.get("users/owner/books/book")!.worldVersion, 1);
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 1);
    assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
    assert.equal(db.values.get(reservationPath(sceneId))!.state, "committed");
    assert.equal(db.values.get("illustrationJobs/job")!.status, "complete");
    assert.equal(objects.size, 2);
    assert(objects.has(String(db.values.get(`illustrationScenes/${sceneId}`)!.imageObject)));
  });
});

test("paid regeneration enqueue failure is repaired with the same intent and one credit", async () => {
  await fixture(async ({ db, objects, calls, request, enqueue }) => {
    seedScene(db);
    db.values.get("illustrationScenes/scene")!.status = "unlocked";
    const submitted: Array<{ path: string; body: Data; id: string }> = [];
    enqueue(async (path, body, id) => {
      submitted.push({ path, body, id });
      if (submitted.length === 1) throw new Error("Transient Cloud Tasks failure");
    });
    assert.equal((await request("/v1/scenes/scene/regenerate")).status, 500);
    assert.equal(db.values.get("illustrationScenes/scene")!.status, "regenerating");
    assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
    assert.equal((await request("/v1/scenes/scene/regenerate")).status, 202);
    assert.deepEqual(submitted[1], submitted[0]);
    assert.equal((await request("/scenes/scene/regenerate", submitted[1]!.body)).status, 204);
    assert.equal((await request("/scenes/scene/regenerate", submitted[1]!.body)).status, 204);
    assert.equal(calls.images, 1);
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 1);
    assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
    assert.equal(objects.size, 2);
  });
});

test("unlock repairs failed free-refresh enqueue without changing billing intent", async () => {
  await fixture(async ({ db, request, enqueue }) => {
    seedScene(db);
    db.values.get("illustrationScenes/scene")!.status = "unlocked";
    const submitted: Array<{ body: Data; id: string }> = [];
    enqueue(async (_path, body, id) => {
      submitted.push({ body, id });
      if (submitted.length === 1) throw new Error("Transient Cloud Tasks failure");
    });
    assert.equal((await request("/v1/scenes/scene/unlock")).status, 500);
    assert.equal((await request("/v1/scenes/scene/regenerate")).status, 202);
    assert.deepEqual(submitted[1], submitted[0]);
    assert.equal(submitted[1]!.body.refresh, true);
    assert.equal((await request("/scenes/scene/regenerate", { ...submitted[1]!.body, refresh: false })).status, 204);
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 2);
    assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
    assert(!db.values.has(reservationPath("scene:generation:2")));
    assert.equal((await request("/v1/scenes/scene/unlock")).status, 200);
  });
});

test("a failed paid generation can be requested again with a new task identity and one net charge", async () => {
  await fixture(async ({ db, calls, request, enqueue, generate }) => {
    seedScene(db);
    db.values.get("illustrationScenes/scene")!.status = "unlocked";
    const submitted: Array<{ body: Data; id: string }> = [];
    enqueue(async (_path, body, id) => { submitted.push({ body, id }); });
    generate(async () => { throw new Error("First provider failure"); });
    assert.equal((await request("/v1/scenes/scene/regenerate")).status, 202);
    assert.equal((await request("/scenes/scene/regenerate", submitted[0]!.body)).status, 500);
    assert.equal((await request("/v1/scenes/scene/regenerate")).status, 202);
    assert.notEqual(submitted[1]!.id, submitted[0]!.id);
    assert.equal(submitted[1]!.body.targetGeneration, submitted[0]!.body.targetGeneration);
    assert.equal((await request("/scenes/scene/regenerate", submitted[0]!.body)).status, 204);
    assert.equal(calls.images, 1, "An old task cannot claim the newer regeneration intent");
    generate(async () => sharp({ create: { width: 2, height: 2, channels: 3, background: "#336699" } }).webp().toBuffer());
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
        return sharp({ create: { width: 2, height: 2, channels: 3, background: "#336699" } }).webp().toBuffer();
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
    assert.equal((await request("/v1/scenes/scene/regenerate")).status, 404);
    assert.equal((await request("/v1/scenes/scene/unlock")).status, 404);
    assert.equal((await request("/v1/scenes/scene", {}, "DELETE")).status, 404);
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
        return sharp({ create: { width: 2, height: 2, channels: 3, background: "#336699" } }).webp().toBuffer();
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
        assert.equal(calls.analysis, 1);
        assert.equal(db.values.get("users/owner/books/book")!.worldVersion, 1);
      }
    });
  });
}
