import assert from "node:assert/strict";
import test from "node:test";
import express from "express";
import { MemoryFirestore, type MemoryData } from "./test-support/firestore.js";
import { illustrationBookRegistration } from "./illustration-books.js";
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
