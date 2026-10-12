import assert from "node:assert/strict";
import test from "node:test";
import express from "express";
import { Timestamp } from "firebase-admin/firestore";
import { bookAnalysisAccountKey, bookAnalysisApiRouter } from "./book-analysis-api.js";
import { BookAnalysisStore, CancelledAnalysisClaim } from "./book-analysis-store.js";
import { analysisChunkHash, analysisDocumentDigest, analysisOverlapHash, analysisSpanHash } from "./book-analysis-source.js";
import { HttpError } from "./http.js";
import { MemoryFirestore } from "./test-support/firestore.js";
import type { AnalysisChunkInput, AnalysisGenerationAdmission, AnalysisReceipt, AnalysisResultPage, AnalysisSourceSpan } from "./book-analysis-types.js";

function source(texts = ["Mara arrives.", "The valley remains dark."]) {
  const inputs: AnalysisChunkInput[] = texts.map((text, ordinal) => {
    const span: AnalysisSourceSpan = { sectionOrdinal: ordinal, sectionId: `section-${ordinal}`,
      blockOrdinal: 0, blockId: `block-${ordinal}`, startOffset: 0, endOffset: text.length, blockLength: text.length, hash: "", text };
    span.hash = analysisSpanHash(span);
    return { ordinal, hash: analysisChunkHash([span]), primary: [span], overlap: [], overlapHash: analysisOverlapHash([]) };
  });
  const chunks = inputs.map(input => ({ ...input, primary: input.primary.map(({ text: _text, ...span }) => span) }));
  const admission: AnalysisGenerationAdmission = { 
    model: "gpt-6-luna", documentDigest: analysisDocumentDigest(chunks), sectionCount: texts.length,
    blockCount: texts.length, chunkCount: texts.length, pageCount: texts.length,
    sections: texts.map((_text, ordinal) => ({ ordinal, id: `section-${ordinal}`, blockCount: 1 })) };
  return { inputs, chunks, admission };
}
async function fixture(action: (f: {
  memory: MemoryFirestore; store: BookAnalysisStore; tasks: { path: string; taskId: string; payload: Record<string, unknown> }[];
  request: (path: string, method?: string, body?: unknown, uid?: string) => Promise<Response>;
  register: () => Promise<string>; enabled: (value: boolean) => void; loseEnqueue: () => void;
}) => Promise<void>, fingerprintSecret = "test-secret") {
  const previousEnabled = process.env.ILLUSTRATIONS_ENABLED;
  const previousProviders = process.env.IMAGE_PROVIDERS;
  process.env.IMAGE_PROVIDERS = "";
  process.env.ILLUSTRATIONS_ENABLED = "true";
  const memory = new MemoryFirestore(), store = new BookAnalysisStore(memory.firestore);
  const tasks: { path: string; taskId: string; payload: Record<string, unknown> }[] = [];
  let enabled = true, loseEnqueue = false;
  const app = express();
  app.use(express.json({ limit: "1mb" }));
  app.use((req, _res, next) => { (req as express.Request & { uid: string }).uid = req.header("x-test-owner") ?? "owner"; next(); });
  app.use("/api/book-analysis", bookAnalysisApiRouter({ db: memory.firestore, fingerprintSecret,
    requireFeature: (_req, _res, next) => next(enabled ? undefined : new HttpError(503, "Service unavailable.")),
    enqueue: async (path, payload, taskId) => {
      tasks.push({ path, payload, taskId });
      if (loseEnqueue) { loseEnqueue = false; throw new HttpError(503, "Enqueue response lost."); }
    },
  }));
  app.use((error: unknown, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
    res.status(error instanceof HttpError ? error.status : 500).json({ error: error instanceof Error ? error.message : "Failed" });
  });
  const server = app.listen(0, "127.0.0.1");
  await new Promise<void>(resolve => server.once("listening", resolve));
  const address = server.address();
  assert(address && typeof address === "object");
  const request = (path: string, method = "GET", body?: unknown, uid = "owner") => fetch(`http://127.0.0.1:${address.port}/api/book-analysis${path}`, {
    method, headers: { "content-type": "application/json", "x-test-owner": uid }, ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  try {
    await action({ memory, store, tasks, request,
      register: async () => {
        const response = await request("/books", "POST", { fingerprint: "fixture", title: "Fixture", chapterCount: 2, uid: "intruder" });
        assert.equal(response.status, 200);
        return (await response.json() as { bookId: string }).bookId;
      },
      enabled: value => { enabled = value; process.env.ILLUSTRATIONS_ENABLED = String(value); },
      loseEnqueue: () => { loseEnqueue = true; },
    });
  } finally {
    await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    if (previousEnabled === undefined) delete process.env.ILLUSTRATIONS_ENABLED;
    else process.env.ILLUSTRATIONS_ENABLED = previousEnabled;
    if (previousProviders === undefined) delete process.env.IMAGE_PROVIDERS;
    else process.env.IMAGE_PROVIDERS = previousProviders;
  }
}

async function admitted(f: Parameters<Parameters<typeof fixture>[0]>[0], data = source()) {
  const bookId = await f.register();
  const response = await f.request(`/books/${bookId}/generations`, "POST", data.admission);
  assert.equal(response.status, 200);
  const { generationId } = await response.json() as AnalysisReceipt;
  return { bookId, generationId, ...data };
}
async function ready(f: Parameters<Parameters<typeof fixture>[0]>[0], data = source()) {
  const result = await admitted(f, data);
  for (let n = result.chunks.length - 1; n >= 0; n--) {
    assert.equal((await f.request(`/generations/${result.generationId}/manifest-pages/${n}`, "PUT", { chunks: [result.chunks[n]] })).status, 204);
  }
  return result;
}
async function extracted(f: Parameters<Parameters<typeof fixture>[0]>[0], data = source()) {
  const result = await ready(f, data);
  for (const input of result.inputs) {
    const response = await f.request(`/generations/${result.generationId}/chunks/${input.ordinal}`, "POST", input);
    assert.equal(response.status, 200);
    const { jobId } = await response.json() as AnalysisReceipt;
    const claimed = await f.store.claim(jobId!);
    assert(claimed);
    assert.equal(await f.store.beginProviderSubmission(claimed.claim), true);
    await f.store.commitExtraction(claimed.claim, []);
  }
  return result;
}

test("analysis registration has no image/profile/credit coupling; rollout-off reads are side-effect free", async () => {
  await fixture(async f => {
    f.memory.values.set("users/owner", { creditsRemaining: 0, creditsReserved: 2 });
    const { bookId, generationId } = await admitted(f);
    const book = f.memory.values.get(`users/owner/books/${bookId}`)!;
    assert.equal(book.uid, "owner");
    assert.equal(book.profile, undefined);
    assert.deepEqual(f.memory.values.get("users/owner"), { creditsRemaining: 0, creditsReserved: 2 });
    book.profile = { retained: true };
    assert.equal(await f.register(), bookId);
    assert.deepEqual(f.memory.values.get(`users/owner/books/${bookId}`)!.profile, { retained: true });
    assert.deepEqual(f.memory.values.get("users/owner"), { creditsRemaining: 0, creditsReserved: 2 });
    f.enabled(false);
    const before = f.memory.events.length;
    const config = await (await f.request("/config")).json() as Record<string, unknown>;
    assert.deepEqual(config, { enabled: false, model: "gpt-6-luna", accountKey: bookAnalysisAccountKey("owner", "test-secret") });
    const progress = await f.request(`/generations/${generationId}`);
    assert.equal(progress.status, 200);
    assert.equal((await progress.json() as Record<string, unknown>).uid, undefined);
    assert.equal((await f.request(`/generations/${generationId}/finalize`, "POST", {})).status, 503);
    assert.equal(f.memory.events.length, before);
    assert.equal(f.tasks.length, 0);
  });
  await fixture(async f => { await f.register(); assert.equal(f.memory.values.has("users/owner"), false); });
});

test("generation admissions adopt identical identity and reject conflicting header or foreign ownership", async () => {
  await fixture(async f => {
    const { admission, generationId, bookId } = await admitted(f);
    const retry = await f.request(`/books/${bookId}/generations`, "POST", admission);
    assert.equal(retry.status, 200);
    assert.equal((await retry.json() as AnalysisReceipt).generationId, generationId);
    assert.equal((await f.request(`/books/${bookId}/generations`, "POST", { ...admission, pageCount: 1 })).status, 409);
    assert.equal((await f.request(`/books/${bookId}/generations`, "POST", admission, "other")).status, 404);
    assert.equal((await f.request(`/generations/${generationId}`, "GET", undefined, "other")).status, 404);
    assert.equal((await f.request(`/generations/${generationId}/manifest-pages/0`, "PUT", { chunks: source().chunks }, "other")).status, 404);
    assert.equal((await f.request(`/generations/${generationId}/chunks/0`, "POST", source().inputs[0], "other")).status, 404);
    assert.equal((await f.request(`/generations/${generationId}/finalize`, "POST", {}, "other")).status, 404);
    f.memory.values.set(`users/owner/books/${bookId}`, { uid: "owner", deleted: true });
    assert.equal((await f.request(`/books/${bookId}/generations`, "POST", admission)).status, 410);
  });
});

test("manifest coverage requires all ordered descriptors while upload page delivery may be reversed", async () => {
  await fixture(async f => {
    const { generationId, chunks, inputs } = await admitted(f);
    const base = `/generations/${generationId}`;
    assert.equal((await f.request(`${base}/manifest-pages/1`, "PUT", { chunks: [chunks[1]] })).status, 204);
    assert.equal((await f.request(`${base}/chunks/0`, "POST", inputs[0])).status, 409);
    assert.equal((await f.request(`${base}/finalize`, "POST", {})).status, 409);
    assert.equal((await f.request(`${base}/manifest-pages/0`, "PUT", { chunks: [chunks[1]] })).status, 400);
    assert.equal((await f.request(`${base}/manifest-pages/0`, "PUT", { chunks: [chunks[0]] })).status, 204);
    assert.equal((await f.request(`${base}/manifest-pages/0`, "PUT", { chunks: [chunks[0]] })).status, 204);
    assert.equal((await f.request(`${base}/manifest-pages/0`, "PUT", { chunks: [chunks[1]] })).status, 409);
    assert.equal((await f.request(`${base}/chunks/1`, "POST", inputs[1])).status, 409);
    assert.deepEqual(await (await f.request(`${base}/chunks/1`, "POST", inputs[1])).json(), { error: "Earlier analysis window is incomplete." });
    assert.equal(f.tasks.length, 0);
  });
});

test("lost enqueue retries adopt exact job, TTL restoration preserves intent, and completed delivery never extracts again", async () => {
  await fixture(async f => {
    const { generationId, inputs } = await ready(f);
    const path = `/generations/${generationId}/chunks/0`;
    f.loseEnqueue();
    assert.equal((await f.request(path, "POST", inputs[0])).status, 503);
    const firstTask = f.tasks[0]!;
    const retry = await f.request(path, "POST", inputs[0]);
    assert.equal(retry.status, 200);
    const { jobId } = await retry.json() as AnalysisReceipt;
    assert.equal(firstTask.taskId, `analysis-extract-${jobId}`);
    assert.deepEqual(f.tasks[1], firstTask);
    const intent = { ...f.memory.values.get(`bookAnalysisJobs/${jobId}`)! };
    const originalRaw = f.memory.values.get(`bookAnalysisInputs/${jobId}`)!;
    assert.equal((originalRaw.expiresAt as Timestamp).toMillis() > Date.now() + 23 * 60 * 60 * 1000, true);
    f.memory.values.delete(`bookAnalysisInputs/${jobId}`);
    const claim = await f.store.claim(jobId!); assert(claim);
    assert.equal(await f.store.readInput(claim.claim), null);
    assert.equal(await f.store.beginProviderSubmission(claim.claim), false);
    assert.equal((await f.store.readGeneration("owner", generationId)).status, "extracting");
    assert.equal((await f.request(path, "POST", inputs[0])).status, 200);
    const restored = f.memory.values.get(`bookAnalysisInputs/${jobId}`)!;
    assert.deepEqual(restored.input, inputs[0]);
    assert.equal(f.memory.values.get(`bookAnalysisJobs/${jobId}`)!.inputHash, intent.inputHash);
    const active = await f.store.claim(jobId!); assert(active);
    assert.equal(await f.store.beginProviderSubmission(active.claim), true);
    await f.store.commitExtraction(active.claim, []);
    assert.equal(f.memory.values.has(`bookAnalysisInputs/${jobId}`), false);
    const tasks = f.tasks.length;
    assert.equal((await f.request(path, "POST", inputs[0])).status, 200);
    assert.equal(f.tasks.length, tasks);
    assert.equal(f.memory.values.has(`bookAnalysisInputs/${jobId}`), false);
    const wrong = { ...inputs[0], primary: [{ ...inputs[0]!.primary[0]!, text: "Changed prose" }] };
    assert.equal((await f.request(path, "POST", wrong)).status, 400);
  });
});

test("paid submission is fenced durably and terminal failed intent cannot be re-enqueued or restored", async () => {
  await fixture(async f => {
    const { generationId, inputs } = await ready(f);
    const path = `/generations/${generationId}/chunks/0`;
    const receipt = await (await f.request(path, "POST", inputs[0])).json() as AnalysisReceipt;
    const claimed = await f.store.claim(receipt.jobId!); assert(claimed);
    assert.equal(await f.store.beginProviderSubmission(claimed.claim), true);
    await assert.rejects(f.store.beginProviderSubmission(claimed.claim), error => error instanceof HttpError && error.status === 409);
    f.memory.values.delete(`bookAnalysisInputs/${receipt.jobId}`);
    assert.equal((await f.request(path, "POST", inputs[0])).status, 200);
    assert.equal(f.memory.values.has(`bookAnalysisInputs/${receipt.jobId}`), false);
    await f.store.fail(claimed.claim, "provider_incomplete");
    const count = f.tasks.length;
    assert.equal((await f.request(path, "POST", inputs[0])).status, 200);
    assert.equal(f.tasks.length, count);
    assert.equal((await f.store.readGeneration("owner", generationId)).error?.category, "provider_incomplete");
  });
});

test("UUID leases reject owned expiration but cancelled, superseded and tombstoned writes cannot publish", async () => {
  await fixture(async f => {
    const { bookId, generationId, inputs } = await ready(f);
    const receipt = await (await f.request(`/generations/${generationId}/chunks/0`, "POST", inputs[0])).json() as AnalysisReceipt;
    const active = await f.store.claim(receipt.jobId!); assert(active);
    assert.match(active.claim.token, /^[a-f0-9-]{36}$/);
    assert.equal(await f.store.claim(receipt.jobId!), null);
    const job = f.memory.values.get(`bookAnalysisJobs/${receipt.jobId}`)!;
    assert.equal((job.leaseUntil as Timestamp).toMillis() > Date.now() + 9 * 60 * 1000, true);
    job.leaseUntil = Timestamp.fromMillis(Date.now() - 1);
    await assert.rejects(f.store.fail(active.claim, "test_failure"), error => error instanceof HttpError && error.status === 409);
    const newer = await f.store.claim(receipt.jobId!); assert(newer);
    await assert.rejects(f.store.commitExtraction(active.claim, []), CancelledAnalysisClaim);
    const replacement = source(["A replacement.", "New passage."]);
    assert.equal((await f.request(`/books/${bookId}/generations`, "POST", replacement.admission)).status, 200);
    await assert.rejects(f.store.commitExtraction(newer.claim, []), CancelledAnalysisClaim);
    assert.equal(await f.store.claim(receipt.jobId!), null);
    f.memory.values.set("narrationAccountTombstones/owner", { deleted: true });
    assert.equal((await f.request(`/generations/${generationId}`)).status, 410);
    await assert.rejects(f.store.fail(newer.claim, "test_failure"), CancelledAnalysisClaim);
  });
});

test("client-driven finalization publishes only durable immutable result pages and preserves previous revision during replacement", async () => {
  await fixture(async f => {
    const { generationId, bookId } = await extracted(f);
    const base = `/generations/${generationId}`;
    const first = await (await f.request(`${base}/finalize`, "POST", {})).json() as AnalysisReceipt;
    const repeated = await (await f.request(`${base}/finalize`, "POST", {})).json() as AnalysisReceipt;
    assert.equal(first.jobId, repeated.jobId);
    const claimed = await f.store.claim(first.jobId!); assert(claimed);
    const page: AnalysisResultPage = { generationId, pageId: "entities-0", kind: "entities", ordinal: 0, entities: [] };
    await f.store.writeStagingPages(claimed.claim, [page]);
    assert.equal((await f.request(`${base}/pages/entities-0`)).status, 404);
    await assert.rejects(f.store.publish(claimed.claim, [f.store.pageDescriptor(page)]), error => error instanceof HttpError && error.status === 409);
    await f.store.commitFinalization(claimed.claim, { stage: "materialize", ordinal: 0 });
    for (const stage of ["index", "publish"] as const) {
      const receipt = await (await f.request(`${base}/finalize`, "POST", {})).json() as AnalysisReceipt;
      const unit = await f.store.claim(receipt.jobId!); assert(unit);
      await f.store.commitFinalization(unit.claim, { stage, ordinal: 0 });
    }
    const publishReceipt = await (await f.request(`${base}/finalize`, "POST", {})).json() as AnalysisReceipt;
    const publish = await f.store.claim(publishReceipt.jobId!); assert(publish);
    await assert.rejects(f.store.publish(publish.claim, [{ ...f.store.pageDescriptor(page), checksum: "0".repeat(64) }]), error => error instanceof HttpError && error.status === 409);
    await f.store.verifyPublicationBatch(publish.claim, [f.store.pageDescriptor(page)], 0);
    await f.store.publish(publish.claim, [f.store.pageDescriptor(page)]);
    assert.deepEqual(await (await f.request(`${base}/pages/entities-0`)).json(), page);
    assert.equal((await f.request(`${base}/pages/entities-0`, "GET", undefined, "other")).status, 404);
    const complete = await f.store.readGeneration("owner", generationId);
    assert.equal(complete.status, "complete");
    assert.equal(complete.processedChunks, 2);
    const count = f.tasks.length;
    assert.equal((await f.request(`${base}/finalize`, "POST", {})).status, 200);
    assert.equal(f.tasks.length, count);
    const replacement = source(["Replacement prose."]);
    const admittedResponse = await f.request(`/books/${bookId}/generations`, "POST", replacement.admission);
    assert.equal(admittedResponse.status, 200);
    const replacementId = (await admittedResponse.json() as AnalysisReceipt).generationId;
    assert.equal((await f.request(`/generations/${replacementId}/manifest-pages/0`, "PUT", { chunks: replacement.chunks })).status, 204);
    const replacementJob = await (await f.request(`/generations/${replacementId}/chunks/0`, "POST", replacement.inputs[0])).json() as AnalysisReceipt;
    const replacementClaim = await f.store.claim(replacementJob.jobId!); assert(replacementClaim);
    await f.store.fail(replacementClaim.claim, "provider_failed");
    assert.equal((await f.store.readGeneration("owner", replacementId)).status, "failed");
    assert.equal(f.memory.values.get(`users/owner/books/${bookId}`)!.latestAnalysisGenerationId, generationId);
    assert.deepEqual(await (await f.request(`${base}/pages/entities-0`)).json(), page);
    f.enabled(false);
    assert.equal((await f.request(`${base}/pages/entities-0`)).status, 200);
    f.memory.values.set(`users/owner/books/${bookId}`, { uid: "owner", deleted: true });
    assert.equal((await f.request(`${base}/pages/entities-0`)).status, 410);
  });
});

test("bounded pages and guarded batches reject overflow rather than truncating derived records", async () => {
  await fixture(async f => {
    const { generationId } = await extracted(f);
    const receipt = await (await f.request(`/generations/${generationId}/finalize`, "POST", {})).json() as AnalysisReceipt;
    const active = await f.store.claim(receipt.jobId!); assert(active);
    await assert.rejects(f.store.writeWorkRecords(active.claim, [{ key: "large", data: { value: "x".repeat(128 * 1024) } }]));
    await assert.rejects(f.store.writeWorkRecords(active.claim, Array.from({ length: 399 }, (_, n) => ({ key: String(n), data: {} }))), error => error instanceof HttpError && error.status === 400);
    assert.equal((await f.store.readGeneration("owner", generationId)).status, "finalizing");
  });
});

test("publication remains private until every checksum batch completes with the same descriptor identity", async () => {
  await fixture(async f => {
    const { generationId } = await extracted(f);
    const base = `/generations/${generationId}`;
    let receipt = await (await f.request(`${base}/finalize`, "POST", {})).json() as AnalysisReceipt;
    let unit = await f.store.claim(receipt.jobId!); assert(unit);
    const pages: AnalysisResultPage[] = Array.from({ length: 33 }, (_, ordinal) => ({
      generationId, pageId: `entities-${ordinal}`, kind: "entities", ordinal, entities: [],
    }));
    const descriptors = await f.store.writeStagingPages(unit.claim, pages);
    for (const stage of ["materialize", "index", "publish"] as const) {
      await f.store.commitFinalization(unit.claim, { stage, ordinal: 0 });
      receipt = await (await f.request(`${base}/finalize`, "POST", {})).json() as AnalysisReceipt;
      unit = await f.store.claim(receipt.jobId!); assert(unit);
    }
    assert.equal(await f.store.verifyPublicationBatch(unit.claim, descriptors, 0), 32);
    await assert.rejects(f.store.publish(unit.claim, descriptors), error => error instanceof HttpError && error.status === 409);
    assert.equal((await f.request(`${base}/pages/entities-0`)).status, 404);
    await f.store.commitFinalization(unit.claim, { stage: "publish", ordinal: 1 });
    receipt = await (await f.request(`${base}/finalize`, "POST", {})).json() as AnalysisReceipt;
    unit = await f.store.claim(receipt.jobId!); assert(unit);
    await assert.rejects(f.store.verifyPublicationBatch(unit.claim, [...descriptors].reverse(), 32),
      error => error instanceof HttpError && error.status === 409);
    assert.equal(await f.store.verifyPublicationBatch(unit.claim, descriptors, 32), 33);
    await f.store.publish(unit.claim, descriptors);
    assert.equal((await f.request(`${base}/pages/entities-32`)).status, 200);
    assert.equal((await f.store.readGeneration("owner", generationId)).status, "complete");
  });
});

test("expiry timestamps restore the same input before submission and book deletion fences delayed finalizers", async () => {
  await fixture(async f => {
    const { generationId, bookId, inputs } = await ready(f);
    const path = `/generations/${generationId}/chunks/0`;
    const { jobId } = await (await f.request(path, "POST", inputs[0])).json() as AnalysisReceipt;
    const raw = f.memory.values.get(`bookAnalysisInputs/${jobId}`)!;
    raw.expiresAt = Timestamp.fromMillis(Date.now() - 1);
    assert.equal((await f.request(path, "POST", inputs[0])).status, 200);
    assert.deepEqual(f.memory.values.get(`bookAnalysisInputs/${jobId}`)!.input, inputs[0]);
    const first = await f.store.claim(jobId!); assert(first);
    await f.store.commitExtraction(first.claim, []);
    const secondReceipt = await (await f.request(`/generations/${generationId}/chunks/1`, "POST", inputs[1])).json() as AnalysisReceipt;
    const second = await f.store.claim(secondReceipt.jobId!); assert(second);
    await f.store.commitExtraction(second.claim, []);
    const finalReceipt = await (await f.request(`/generations/${generationId}/finalize`, "POST", {})).json() as AnalysisReceipt;
    const finalizer = await f.store.claim(finalReceipt.jobId!); assert(finalizer);
    f.memory.values.set(`users/owner/books/${bookId}`, { uid: "owner", deleted: true });
    const writes = f.memory.events.length;
    const page: AnalysisResultPage = { generationId, pageId: "late", kind: "entities", ordinal: 0, entities: [] };
    await assert.rejects(f.store.writeStagingPages(finalizer.claim, [page]), CancelledAnalysisClaim);
    await assert.rejects(f.store.commitFinalization(finalizer.claim, { stage: "materialize", ordinal: 0 }), CancelledAnalysisClaim);
    await assert.rejects(f.store.publish(finalizer.claim, []), CancelledAnalysisClaim);
    assert.equal(f.memory.events.length, writes);
  });
});

test("empty documents can reconcile without raw inputs and manifest cursor identifies the next missing page", async () => {
  await fixture(async f => {
    const empty = await admitted(f, source([]));
    const emptyProgress = await f.store.readGeneration("owner", empty.generationId);
    assert.deepEqual(emptyProgress.cursor, { stage: "reconcile", ordinal: 0 });
    assert.equal((await f.request(`/generations/${empty.generationId}/finalize`, "POST", {})).status, 200);
    const full = await admitted(f);
    assert.equal((await f.request(`/generations/${full.generationId}/manifest-pages/0`, "PUT", { chunks: [full.chunks[0]] })).status, 204);
    assert.deepEqual((await f.store.readGeneration("owner", full.generationId)).cursor, { stage: "manifest", ordinal: 1 });
  });
});

test("missing owner fingerprint secret cannot issue an account key or register metadata", async () => {
  await fixture(async f => {
    assert.equal((await f.request("/config")).status, 503);
    const registration = await f.request("/books", "POST", {
      fingerprint: "fixture", title: "Fixture", chapterCount: 1,
    });
    assert.equal(registration.status, 503);
    assert.equal(f.memory.values.size, 0);
    assert.equal(f.tasks.length, 0);
  }, "");
});
