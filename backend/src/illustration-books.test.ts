import assert from "node:assert/strict";
import test from "node:test";
import express from "express";
import { MemoryFirestore, type MemoryData } from "./test-support/firestore.js";
import { illustrationBookRegistration, illustrationBookDeletion } from "./illustration-books.js";
import { registerOwnedBook } from "./book-registration.js";
import type { Storage } from "@google-cloud/storage";
import { HttpError } from "./http.js";

/** Serial transactions preserve the same initial-credit decision under concurrent retries. */
async function fixture(action: (values: Map<string, MemoryData>, register: (fingerprint: string) => Promise<Response>) => Promise<void>) {
  const previousEnabled = process.env.ILLUSTRATIONS_ENABLED;
  const previousProviders = process.env.IMAGE_PROVIDERS;
  process.env.ILLUSTRATIONS_ENABLED = "true";
  process.env.IMAGE_PROVIDERS = "openai";
  const memory = new MemoryFirestore();
  const values = memory.values;
  const db = memory.firestore;
  const app = express();
  app.use(express.json());
  app.use((req, _res, next) => { (req as express.Request & { uid: string }).uid = "owner"; next(); });
  app.post("/v1/books", illustrationBookRegistration({ db, pilotCredits: 100 }));
  app.use((error: unknown, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
    res.status(error instanceof HttpError ? error.status : 500).json({ error: error instanceof Error ? error.message : "Failed" });
  });
  const server = app.listen(0, "127.0.0.1");
  await new Promise<void>(resolve => server.on("listening", resolve));
  const address = server.address();
  assert(address && typeof address === "object");
  try {
    await action(values, fingerprint => fetch(`http://127.0.0.1:${address.port}/v1/books`, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ schemaVersion: 2, fingerprint, title: "A courtyard", chapterCount: 1 }),
    }));
  } finally {
    await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    if (previousEnabled === undefined) delete process.env.ILLUSTRATIONS_ENABLED;
    else process.env.ILLUSTRATIONS_ENABLED = previousEnabled;
    if (previousProviders === undefined) delete process.env.IMAGE_PROVIDERS;
    else process.env.IMAGE_PROVIDERS = previousProviders;
  }
}

test("book registration grants pilot credit once and preserves spent and reserved credits on retries and new books", async () => {
  await fixture(async (values, register) => {
    const first = await register("first");
    assert.equal(first.status, 200);
    const original = await first.json() as { id: string; estimatedCredits: number };
    assert.equal(original.estimatedCredits, 3);
    assert.equal(values.get("users/owner")?.creditsRemaining, 100);
    values.set("users/owner", { creditsRemaining: 0, creditsReserved: 1 });
    const responses = await Promise.all([register("first"), register("second"), register("first")]);
    assert(responses.every(response => response.status === 200));
    assert.equal((await responses[0]!.json() as { id: string }).id, original.id);
    assert.deepEqual(values.get("users/owner"), { creditsRemaining: 0, creditsReserved: 1 });
    assert.equal([...values.keys()].filter(path => path.startsWith("users/owner/books/")).length, 2);
  });
});

test("deleted account registration cannot recreate books or pilot credits", async () => {
  await fixture(async (values, register) => {
    values.set("narrationAccountTombstones/owner", { deletedAt: new Date() });
    const response = await register("first");
    assert.equal(response.status, 410);
    assert.deepEqual(await response.json(), { error: "Account was deleted." });
    assert.equal(values.size, 1);
  });
});

test("deleted illustration book registration retains its durable fence without granting credit", async () => {
  await fixture(async (values, register) => {
    const first = await register("first");
    const { id } = await first.json() as { id: string };
    values.set(`users/owner/books/${id}`, { uid: "owner", deleted: true });
    values.set("users/owner", { creditsRemaining: 1, creditsReserved: 0 });
    assert.equal((await register("first")).status, 410);
    assert.deepEqual(values.get(`users/owner/books/${id}`), { uid: "owner", deleted: true });
    assert.deepEqual(values.get("users/owner"), { creditsRemaining: 1, creditsReserved: 0 });
  });
});

test("preprocessing registration preserves profiles and balances without initializing image credit", async () => {
  const memory = new MemoryFirestore();
  const metadata = { schemaVersion: 2, fingerprint: "source", title: "Book", chapterCount: 2 };
  const first = await registerOwnedBook({ db: memory.firestore, uid: "owner", metadata });
  assert.equal(memory.values.has("users/owner"), false);
  const path = `users/owner/books/${first.bookId}`;
  memory.values.set(path, { ...memory.values.get(path), profile: { enabled: true }, createdAt: "original" });
  memory.values.set("users/owner", { creditsRemaining: 0, creditsReserved: 2 });
  const second = await registerOwnedBook({ db: memory.firestore, uid: "owner", metadata });
  assert.equal(second.bookId, first.bookId);
  assert.deepEqual(memory.values.get(path)?.profile, { enabled: true });
  assert.equal(memory.values.get(path)?.createdAt, "original");
  assert.deepEqual(memory.values.get("users/owner"), { creditsRemaining: 0, creditsReserved: 2 });
  const other = await registerOwnedBook({ db: memory.firestore, uid: "other", metadata });
  assert.notEqual(other.bookId, first.bookId);
});

test("book deletion purges every analysis generation and staging page while isolating owners and books", async () => {
  const memory = new MemoryFirestore();
  memory.values.set("users/owner/books/book", { uid: "owner" });
  const collections = ["bookAnalysisJobs", "bookAnalysisRecords", "bookAnalysisInputs"];
  for (const collection of collections) {
    for (const generationId of ["old", "new"]) {
      memory.values.set(`${collection}/${generationId}`, { uid: "owner", bookId: "book", generationId });
    }
    memory.values.set(`${collection}/other-owner`, { uid: "other", bookId: "book", generationId: "new" });
    memory.values.set(`${collection}/other-book`, { uid: "owner", bookId: "other", generationId: "new" });
  }
  const app = express();
  app.use((req, _res, next) => { (req as express.Request & { uid: string }).uid = "owner"; next(); });
  app.delete("/books/:bookId", illustrationBookDeletion({
    db: memory.firestore,
    storage: { bucket: () => ({ deleteFiles: async () => {
      assert.equal(memory.values.get("users/owner/books/book")?.deleted, true);
    } }) } as unknown as Storage,
    bucket: "private",
  }));
  const server = app.listen(0, "127.0.0.1");
  await new Promise<void>(resolve => server.on("listening", resolve));
  try {
    const address = server.address();
    assert(address && typeof address === "object");
    const url = `http://127.0.0.1:${address.port}/books/book`;
    assert.equal((await fetch(url, { method: "DELETE" })).status, 204);
    assert.equal((await fetch(url, { method: "DELETE" })).status, 204);
    for (const collection of collections) {
      assert(!memory.values.has(`${collection}/old`));
      assert(!memory.values.has(`${collection}/new`));
      assert(memory.values.has(`${collection}/other-owner`));
      assert(memory.values.has(`${collection}/other-book`));
    }
  } finally {
    await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
  }
});

test("preprocessing-only registration honors book and account tombstones", async () => {
  const memory = new MemoryFirestore();
  const args = { db: memory.firestore, uid: "owner",
    metadata: { schemaVersion: 2, fingerprint: "fenced", title: "Book" } };
  const { bookId } = await registerOwnedBook(args);
  const path = `users/owner/books/${bookId}`;
  memory.values.set(path, { uid: "owner", deleted: true });
  await assert.rejects(registerOwnedBook(args), error => error instanceof HttpError && error.status === 410);
  assert.deepEqual(memory.values.get(path), { uid: "owner", deleted: true });
  memory.values.set("narrationAccountTombstones/owner", { deletedAt: new Date() });
  memory.values.delete(path);
  await assert.rejects(registerOwnedBook(args), error => error instanceof HttpError && error.status === 410);
  assert.equal(memory.values.has(path), false);
  assert.equal(memory.values.has("users/owner"), false);
});
