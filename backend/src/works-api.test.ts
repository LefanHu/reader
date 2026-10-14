import assert from "node:assert/strict";
import test from "node:test";
import express from "express";
import { unflattenRuns } from "./alignment.js";
import { MemoryFirestore } from "./test-support/firestore.js";
import { assignUid, startTestServer } from "./test-support/http.js";
import { MemoryStorage } from "./test-support/storage.js";
import { paragraphFingerprint, workIdFor } from "./work-text.js";
import { worksApiRouter } from "./works-api.js";

const prose = (label: string) => Array.from({ length: 50 }, (_, index) => `${label} paragraph number ${index} of the story.`);
const austen = ["Chapter 1", ...prose("Pride")];
const copyA = "a".repeat(64), copyB = "b".repeat(64);
const book = (fingerprint = copyA) => ({ fingerprint, title: "Pride and Prejudice", authors: ["Jane Austen"], chapterCount: 1 });
const fingerprints = (paragraphs: string[]) => Buffer.concat(paragraphs.map(paragraphFingerprint)).toString("base64");
const prideId = workIdFor("Pride and Prejudice", "Jane Austen");

type Fetcher = typeof fetch;
const openLibrary = (docs: unknown[]): Fetcher => async () => Response.json({ docs });

async function fixture(action: (f: {
  memory: MemoryFirestore; storage: MemoryStorage; requests: URL[];
  request: (path: string, init?: { method?: string; json?: unknown; uid?: string }) => Promise<Response>;
  linkCopy: (paragraphs?: string[], init?: { uid?: string; fingerprint?: string; title?: string }) => Promise<Response>;
}) => Promise<void>, fetcher: Fetcher = openLibrary([])) {
  const memory = new MemoryFirestore(), storage = new MemoryStorage(), requests: URL[] = [];
  const app = express();
  app.use(express.json({ limit: "5mb" }));
  app.use(assignUid(req => req.header("x-test-owner") ?? "owner"));
  app.use("/api", worksApiRouter({
    db: memory.firestore, storage: storage.storage, bucket: "bucket", requireFeature: (_req, _res, next) => next(),
    fetch: async (url, init) => { requests.push(new URL(url as URL)); return await fetcher(url, init); },
  }));
  const server = await startTestServer(app);
  const request = (path: string, init: { method?: string; json?: unknown; uid?: string } = {}) => fetch(`${server.baseUrl}/api${path}`, {
    method: init.method ?? (init.json ? "POST" : "GET"),
    headers: { "x-test-owner": init.uid ?? "owner", "content-type": "application/json" },
    ...(init.json ? { body: JSON.stringify(init.json) } : {}),
  });
  const linkCopy = (paragraphs = austen, init: { uid?: string; fingerprint?: string; title?: string } = {}) =>
    request("/works/links", { uid: init.uid, json: {
      book: book(init.fingerprint), title: init.title ?? "Pride and Prejudice", author: "Jane Austen",
      firstPublishYear: 1813, fingerprints: fingerprints(paragraphs),
    } });
  try { await action({ memory, storage, requests, request, linkCopy }); } finally { await server.close(); }
}

test("search answers Open Library rows collapsed by work identity and marks linked works", () => fixture(async ({ request, requests, linkCopy }) => {
  assert.equal((await linkCopy()).status, 201);
  const response = await request(`/works?q=${encodeURIComponent("pride austen")}`);
  const body = await response.json() as { works: { id: string; title: string; firstPublishYear: number | null; linked: boolean }[]; degraded: boolean };
  assert.equal(body.degraded, false);
  assert.deepEqual(body.works, [
    { id: prideId, title: "Pride and Prejudice", author: "Jane Austen", firstPublishYear: 1813, linked: true },
    { id: workIdFor("Emma", "Jane Austen"), title: "Emma", author: "Jane Austen", firstPublishYear: null, linked: false },
  ]);
  assert.equal(requests[0]!.searchParams.get("q"), "pride austen");
  assert.equal(requests[0]!.searchParams.get("limit"), "20");
}, openLibrary([
  { title: "Pride and Prejudice", author_name: ["Jane Austen"], first_publish_year: 1813 },
  { title: "The Pride and Prejudice", author_name: ["Jane Austen", "Editor"], first_publish_year: 1900 },
  { title: "Emma", author_name: ["Jane Austen"] },
  { author_name: ["No Title"] },
])));

test("search composes Open Library's decomposed accents", () => fixture(async ({ request }) => {
  const body = await (await request("/works?q=storm")).json() as { works: { id: string; author: string }[] };
  assert.equal(body.works[0]!.author, "Ernst J\u00fcnger");
  assert.equal(body.works[0]!.id, workIdFor("The Storm of Steel", "Ernst J\u00fcnger"));
}, openLibrary([{ title: "Storm of Steel", author_name: ["Ernst Ju\u0308nger"] }])));

test("search falls back to linked works when Open Library fails", () => fixture(async ({ request, linkCopy }) => {
  await linkCopy();
  const body = await (await request("/works?q=prejudice")).json() as { works: unknown[]; degraded: boolean };
  assert.equal(body.degraded, true);
  assert.deepEqual(body.works, [
    { id: prideId, title: "Pride and Prejudice", author: "Jane Austen", firstPublishYear: 1813, linked: true },
  ]);
  assert.deepEqual(await (await request("/works?q=a")).json(), { works: [], degraded: false });
}, async () => new Response("unavailable", { status: 503 })));

test("the first link makes its fingerprints the work's reference", () => fixture(async ({ memory, storage, linkCopy }) => {
  const response = await linkCopy();
  assert.equal(response.status, 201);
  const { bookId, score, work } = await response.json() as { bookId: string; score: number; work: { id: string; linked: boolean } };
  assert.equal(score, 1);
  assert.deepEqual(work, { id: prideId, title: "Pride and Prejudice", author: "Jane Austen", firstPublishYear: 1813, linked: true });
  const doc = memory.values.get(`works/${prideId}`)!;
  assert.equal(doc.paragraphCount, 51);
  assert.deepEqual(storage.objects.get(doc.reference as string), Buffer.from(fingerprints(austen), "base64"));
  assert.deepEqual(doc.keywords, ["pride", "and", "prejudice", "jane", "austen"]);
  const link = memory.values.get(`users/owner/books/${bookId}`)!.work as { workId: string; runs: number[] };
  assert.equal(link.workId, prideId);
  assert.deepEqual(unflattenRuns(link.runs), [[0, 0, 51]]);
}));

test("a later copy with a different title spelling links with its alignment", () => fixture(async ({ memory, request, linkCopy }) => {
  await linkCopy();
  const watermarked = ["Licensed to reader@example.com for personal use.", ...austen];
  const response = await linkCopy(watermarked, { uid: "reader", fingerprint: copyB, title: "PRIDE AND PREJUDICE" });
  assert.equal(response.status, 200);
  const { bookId, score, work } = await response.json() as { bookId: string; score: number; work: { id: string } };
  assert.ok(score >= 0.98 && score < 1);
  assert.equal(work.id, prideId);
  const link = memory.values.get(`users/reader/books/${bookId}`)!.work as { runs: number[] };
  assert.deepEqual(unflattenRuns(link.runs), [[2, 1, 50]]);
  const current = await request(`/works/links/${copyB}`, { uid: "reader" });
  assert.deepEqual(await current.json(), { bookId, score, work });
  assert.equal((await request(`/works/links/${copyB}`, { uid: "intruder" })).status, 404);
}));

test("a copy that does not align with the reference is refused and stays unlinked", () => fixture(async ({ memory, linkCopy }) => {
  await linkCopy();
  const response = await linkCopy(prose("Translated"), { uid: "reader", fingerprint: copyB });
  assert.equal(response.status, 422);
  const body = await response.json() as { score: number; error: string };
  assert.equal(body.score, 0);
  assert.match(body.error, /0% of paragraphs match/);
  assert.ok(![...memory.values.keys()].some(path => path.startsWith("users/reader/")));
}));

test("concurrent first links leave one reference and align the loser against it", () => fixture(async ({ memory, storage, linkCopy }) => {
  const [first, second] = await Promise.all([linkCopy(), linkCopy(austen, { uid: "reader", fingerprint: copyB })]);
  assert.deepEqual([first.status, second.status].sort(), [200, 201]);
  const references = [...storage.objects.keys()].filter(path => path.startsWith(`works/${prideId}/`));
  assert.deepEqual(references, [memory.values.get(`works/${prideId}`)!.reference]);
}));

test("malformed links are rejected before anything is stored", () => fixture(async ({ memory, storage, request }) => {
  const valid = { book: book(), title: "Pride and Prejudice", author: "Jane Austen", fingerprints: fingerprints(austen) };
  for (const json of [
    { ...valid, book: { title: "x" } },
    { ...valid, title: " " },
    { ...valid, fingerprints: Buffer.alloc(7).toString("base64") },
    { ...valid, fingerprints: "" },
  ]) {
    assert.equal((await request("/works/links", { json })).status, 400);
  }
  assert.equal(storage.objects.size, 0);
  assert.equal(memory.values.size, 0);
}));

test("unlinking removes only the user's link and is idempotent", () => fixture(async ({ memory, request, linkCopy }) => {
  const { bookId } = await (await linkCopy()).json() as { bookId: string };
  assert.equal((await request(`/works/links/${copyA}`, { method: "DELETE" })).status, 204);
  assert.equal(memory.values.get(`users/owner/books/${bookId}`)!.work, undefined);
  assert.ok(memory.values.has(`works/${prideId}`));
  assert.equal((await request(`/works/links/${copyA}`)).status, 404);
  assert.equal((await request(`/works/links/${copyA}`, { method: "DELETE" })).status, 204);
}));
