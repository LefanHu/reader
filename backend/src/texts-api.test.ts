import assert from "node:assert/strict";
import test from "node:test";
import express from "express";
import { unflattenRuns } from "./alignment.js";
import { paragraphFingerprint } from "./paragraph-fingerprints.js";
import { MemoryFirestore } from "./test-support/firestore.js";
import { assignUid, startTestServer } from "./test-support/http.js";
import { MemoryStorage } from "./test-support/storage.js";
import { textsApiRouter } from "./texts-api.js";

const prose = (label: string, count = 60) =>
  Array.from({ length: count }, (_, index) => `${label} paragraph number ${index} of the story.`);
const novel = ["Chapter 1", ...prose("Pride")];
const encode = (paragraphs: string[]) => Buffer.concat(paragraphs.map(paragraphFingerprint)).toString("base64");
let copies = 0;
/** A distinct book fingerprint per copy, so each copy is its own user book. */
const nextCopy = () => (copies++).toString(16).padStart(64, "0");

type Identified = { bookId: string; textId: string; score: number; created: boolean };

async function fixture(action: (f: {
  memory: MemoryFirestore; storage: MemoryStorage;
  identify: (paragraphs: string[], uid?: string) => Promise<Identified>;
  request: (json: unknown) => Promise<Response>;
}) => Promise<void>) {
  const memory = new MemoryFirestore(), storage = new MemoryStorage();
  const app = express();
  app.use(express.json({ limit: "5mb" }));
  app.use(assignUid(req => req.header("x-test-owner") ?? "owner"));
  app.use("/api", textsApiRouter({
    db: memory.firestore, storage: storage.storage, bucket: "bucket", requireFeature: (_req, _res, next) => next(),
  }));
  const server = await startTestServer(app);
  const send = (json: unknown, uid = "owner") => fetch(`${server.baseUrl}/api/texts/identify`, {
    method: "POST", headers: { "x-test-owner": uid, "content-type": "application/json" }, body: JSON.stringify(json),
  });
  const identify = async (paragraphs: string[], uid = "owner") => {
    const response = await send({ book: { fingerprint: nextCopy(), title: "Any title", chapterCount: 1 }, fingerprints: encode(paragraphs) }, uid);
    assert.ok(response.status === 200 || response.status === 201, `status ${response.status}`);
    return await response.json() as Identified;
  };
  try { await action({ memory, storage, identify, request: json => send(json) }); } finally { await server.close(); }
}

test("a first copy creates a shared text holding only its fingerprints and sketch", () => fixture(async ({ memory, storage, identify }) => {
  const result = await identify(novel);
  assert.equal(result.created, true);
  assert.equal(result.score, 1);
  const text = memory.values.get(`texts/${result.textId}`)!;
  assert.equal(text.paragraphCount, 61);
  assert.equal((text.sketch as string[]).length, 30);
  assert.deepEqual(storage.objects.get(text.reference as string), Buffer.from(encode(novel), "base64"));
  const book = memory.values.get(`users/owner/books/${result.bookId}`)!.text as { textId: string; runs: number[] };
  assert.equal(book.textId, result.textId);
  assert.deepEqual(unflattenRuns(book.runs), [[0, 0, 61]]);
}));

test("other copies of the same text join it, with their alignment", () => fixture(async ({ memory, identify }) => {
  const { textId } = await identify(novel);
  const same = await identify(novel, "reader");
  assert.deepEqual([same.textId, same.score, same.created], [textId, 1, false]);
  const watermarked = await identify(["Licensed to reader@example.com for personal use only.", ...novel], "reader");
  assert.equal(watermarked.textId, textId);
  assert.ok(watermarked.score >= 0.98 && watermarked.score < 1);
  const runs = (memory.values.get(`users/reader/books/${watermarked.bookId}`)!.text as { runs: number[] }).runs;
  assert.deepEqual(unflattenRuns(runs), [[2, 1, 60]]);
  const abridged = await identify(novel.slice(0, 31), "reader");
  assert.equal(abridged.textId, textId);
  assert.equal([...memory.values.keys()].filter(path => path.startsWith("texts/")).length, 1);
}));

test("a different text becomes its own shared text", () => fixture(async ({ identify }) => {
  const original = await identify(novel);
  const translation = await identify(prose("Translated"));
  assert.notEqual(translation.textId, original.textId);
  assert.equal(translation.created, true);
  assert.equal((await identify(prose("Translated"))).textId, translation.textId);
}));

test("concurrent identical first copies leave one shared text", () => fixture(async ({ memory, storage, identify }) => {
  const results = await Promise.all([identify(novel), identify(novel, "reader")]);
  assert.equal(results[0].textId, results[1].textId);
  const docs = [...memory.values.keys()].filter(path => path.startsWith("texts/"));
  assert.equal(docs.length, 1);
  assert.deepEqual([...storage.objects.keys()], [memory.values.get(docs[0]!)!.reference]);
}));

test("a copy whose sketch matches an unaligned text gets a unique text", () => fixture(async ({ memory, identify }) => {
  const original = await identify(novel);
  const sketch = memory.values.get(`texts/${original.textId}`)!.sketch as string[];
  // The original's sketch paragraphs plus many paragraphs hashing above all of
  // them: same sketch, so the same derived ID, but under 90% aligned.
  const sketched = novel.filter(paragraph => sketch.includes(paragraphFingerprint(paragraph).toString("hex")));
  const larger = prose("Other", 2_000).filter(paragraph => paragraphFingerprint(paragraph).toString("hex") > sketch.at(-1)!);
  const other = await identify([...sketched, ...larger.slice(0, 300)]);
  assert.equal(other.created, true);
  assert.notEqual(other.textId, original.textId);
  assert.equal([...memory.values.keys()].filter(path => path.startsWith("texts/")).length, 2);
}));

test("a copy without identifiable paragraphs still gets its own text", () => fixture(async ({ identify }) => {
  const first = await identify(["Yes.", "No."]);
  const second = await identify(["Yes.", "No."]);
  assert.equal(first.created && second.created, true);
  assert.notEqual(first.textId, second.textId);
}));

test("malformed requests are rejected before anything is stored", () => fixture(async ({ memory, storage, request }) => {
  const book = { fingerprint: nextCopy(), title: "Any title" };
  for (const json of [
    { book: { title: "x" }, fingerprints: encode(novel) },
    { book, fingerprints: Buffer.alloc(7).toString("base64") },
    { book, fingerprints: "" },
    { book },
  ]) {
    assert.equal((await request(json)).status, 400);
  }
  assert.equal(storage.objects.size, 0);
  assert.equal(memory.values.size, 0);
}));
