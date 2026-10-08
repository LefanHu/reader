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
import type { ChapterInput, NarrativeAnalysis } from "./types.js";

type Data = Record<string, unknown>;
const hash = (value: string) => createHash("sha256").update(value).digest("hex");
const reservationPath = (operation: string) => `creditReservations/${hash(`owner:${operation}`)}`;

/** Operations supported by this worker's transactional/batch fixture boundary. */
interface Writer {
  set(reference: Reference, data: Data, options?: { merge: boolean }): void;
  create(reference: Reference, data: Data): void;
  update(reference: Reference, data: Data): void;
  commit(): Promise<void>;
}
interface Snapshot {
  exists: boolean;
  id: string;
  data(): Data | undefined;
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
      commit: async () => { for (const operation of pending) operation(); },
    };
  }
  batch() { return this.writer(); }
  bulkWriter() {
    const writer = this.writer();
    return { set: writer.set, close: writer.commit };
  }
}
class Reference {
  constructor(readonly db: Database, readonly path: string) {}
  get id() { return this.path.split("/").at(-1)!; }
  collection(path: string) { return this.db.collection(`${this.path}/${path}`); }
  async get() {
    const data = this.db.values.get(this.path);
    return { exists: data !== undefined, id: this.id, data: () => data && { ...data } };
  }
  write(data: Data, merge = false) {
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

async function fixture(action: (harness: {
  db: Database; objects: Map<string, Buffer>; calls: { analysis: number; images: number };
  request: (path: string, body?: Data) => Promise<Response>;
  generate: (implementation: () => Promise<Buffer>) => void;
}) => Promise<void>) {
  const db = new Database();
  const objects = new Map<string, Buffer>();
  const calls = { analysis: 0, images: 0 };
  const image = await sharp({ create: { width: 2, height: 2, channels: 3, background: "#336699" } }).webp().toBuffer();
  let generate: () => Promise<Buffer> = async () => image;
  const storage = { bucket: () => ({ file: (path: string) => ({
    download: async () => { assert(objects.has(path)); return [objects.get(path)!]; },
    save: async (bytes: Buffer) => { objects.set(path, bytes); db.events.push(`save:${path}`); },
    delete: async () => { objects.delete(path); db.events.push(`delete-object:${path}`); },
  }) }) } as unknown as Storage;
  const app = express();
  app.use(express.json());
  app.use("/internal", illustrationWorkerRouter({
    db: db as unknown as Firestore, storage, bucket: "private", pilotCredits: 100,
    assetRetentionMilliseconds: 30 * 86400000, composeImagePrompt,
    analyzeNarrative: async () => { calls.analysis++; return analysis; },
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
      request: (path, body = {}) => fetch(`${url}/internal${path}`, {
        method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body),
      }),
      generate: implementation => { generate = implementation; },
    });
  } finally { await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve())); }
}
function seedJob(db: Database) {
  db.values.set("users/owner", { creditsRemaining: 2, creditsReserved: 0 });
  db.values.set("users/owner/books/book", { profile: { style: "Painted" } });
  db.values.set("illustrationJobs/job", { uid: "owner", bookId: "book", chapterOrdinal: 0, status: "queued" });
  db.values.set("illustrationJobInputs/job", { input });
}
function seedScene(db: Database) {
  db.values.set("users/owner", { creditsRemaining: 2, creditsReserved: 0 });
  db.values.set("illustrationScenes/scene", { uid: "owner", bookId: "book", status: "unlocked",
    generationVersion: 1, imageObject: "old.webp", thumbnailObject: "old.thumb.webp",
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
    assert.equal(scene.imageObject, `users/owner/books/book/scenes/${sceneId}.webp`);
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
    assert(db.events.indexOf(`write:worldReferences/${sceneId}:`) < db.events.indexOf(`write:${reservationPath(sceneId)}:committed`));
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
    assert(db.events.includes(`delete-object:users/owner/books/book/scenes/${sceneId}.webp`));
  });
});
test("regeneration lease rejects a second worker and completed target retries never charge twice", async () => {
  await fixture(async ({ db, objects, calls, request, generate }) => {
    seedScene(db);
    objects.set("old.webp", Buffer.from("old"));
    objects.set("old.thumb.webp", Buffer.from("old thumbnail"));
    db.values.set("worldReferences/scene", { referenceObject: "old.webp" });
    let entered!: () => void;
    const started = new Promise<void>(resolve => { entered = resolve; });
    let release!: () => void;
    const hold = new Promise<void>(resolve => { release = resolve; });
    generate(async () => {
      entered();
      await hold;
      return sharp({ create: { width: 2, height: 2, channels: 3, background: "#336699" } }).webp().toBuffer();
    });
    const first = request("/scenes/scene/regenerate", { targetGeneration: 2 });
    await started;
    try {
      assert.equal(db.values.get("users/owner")!.creditsReserved, 1);
      const duplicate = await request("/scenes/scene/regenerate", { targetGeneration: 2 });
      assert.equal(duplicate.status, 409);
      assert.deepEqual(await duplicate.json(), { error: "Regeneration is already running." });
    } finally { release(); }
    assert.equal((await first).status, 204);
    assert.equal(db.values.get("illustrationScenes/scene")!.generationVersion, 2);
    assert.equal(db.values.get(reservationPath("scene:generation:2"))!.state, "committed");
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 1);
    assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
    assert.equal(db.values.get("worldReferences/scene")!.referenceObject,
      "users/owner/books/book/scenes/scene.v2.webp");
    assert(!objects.has("old.webp"));
    assert(!objects.has("old.thumb.webp"));
    assert(db.events.indexOf(`write:${reservationPath("scene:generation:2")}:committed`) < db.events.indexOf("delete-object:old.webp"));
    assert.equal((await request("/scenes/scene/regenerate", { targetGeneration: 2 })).status, 204);
    assert.equal(calls.images, 1);
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 1);
  });
});
test("regeneration failure refunds credits, clears the lease and keeps previous assets", async () => {
  await fixture(async ({ db, objects, request, generate }) => {
    seedScene(db);
    objects.set("old.webp", Buffer.from("old"));
    objects.set("old.thumb.webp", Buffer.from("old thumbnail"));
    generate(async () => { throw new Error("local provider failure"); });
    assert.equal((await request("/scenes/scene/regenerate", { targetGeneration: 2 })).status, 500);
    assert.equal(db.values.get(reservationPath("scene:generation:2"))!.state, "refunded");
    assert.equal(db.values.get("users/owner")!.creditsRemaining, 2);
    assert.equal(db.values.get("users/owner")!.creditsReserved, 0);
    const scene = db.values.get("illustrationScenes/scene")!;
    assert.equal(scene.status, "unlocked");
    assert.equal(scene.failureCategory, "regeneration_failed");
    assert.equal(scene.generationVersion, 1);
    assert(!("regenerationLeaseUntil" in scene));
    assert.deepEqual([...objects.keys()], ["old.webp", "old.thumb.webp"]);
  });
});
