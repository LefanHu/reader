import assert from "node:assert/strict";
import test from "node:test";
import { Timestamp } from "firebase-admin/firestore";
import type { Storage } from "@google-cloud/storage";
import { bookReference } from "./fences.js";
import { illustrationBookDeletion } from "./illustration-books.js";
import { analysisChunkHash, analysisDocumentDigest, analysisSpanHash } from "./book-analysis-source.js";
import type { AnalysisReceipt, AnalysisResultPage, AnalysisTime, BookAnalysisProvider } from "./book-analysis-types.js";
import { BookAnalysisProviderError } from "./book-analysis-provider.js";
import { bookAnalysisFixture, bookAnalysisFixtureProvider, BOOK_ANALYSIS_FIXTURE_SECTIONS, startBookAnalysisFixtureHarness, type BookAnalysisFixtureHarness } from "./test-support/book-analysis-fixture.js";

async function withHarness(action: (h: BookAnalysisFixtureHarness) => Promise<void>, provider?: BookAnalysisProvider) {
  const h = await startBookAnalysisFixtureHarness({ provider });
  try { await action(h); } finally { await h.close(); }
}
async function completed(h: BookAnalysisFixtureHarness) {
  const receipt = await h.admit();
  await h.extract(receipt.generationId, 0); await h.extract(receipt.generationId, 1);
  const state = await h.finalize(receipt.generationId);
  assert.equal(state.status, "complete", JSON.stringify(state.error));
  return { ...receipt, state, pages: await h.pages(receipt.generationId) };
}
function records(pages: AnalysisResultPage[]) {
  return { entities: pages.flatMap(p => p.entities ?? []), mentions: pages.flatMap(p => p.mentions ?? []),
    entries: pages.flatMap(p => p.entries ?? []), assertions: pages.flatMap(p => p.assertions ?? []), times: pages.flatMap(p => p.times ?? []),
    mappings: pages.flatMap(p => p.entityMappings ?? []), baselines: pages.flatMap(p => p.worldBaselines ?? []), maps: pages.flatMap(p => p.worldMaps ?? []), subjects: pages.flatMap(p => p.subjectIndexes ?? []) };
}
function reaches(times: AnalysisTime[], start: string, end: string): boolean {
  const edges: Record<string, string[]> = {};
  for (const time of times) edges[time.id] = [...time.beforeIds];
  for (const time of times) for (const prior of time.afterIds) (edges[prior] ??= []).push(time.id);
  const visited = new Set<string>(), queue = [start];
  for (let n = 0; n < queue.length; n++) {
    const id = queue[n]!; if (id === end) return true;
    if (visited.has(id)) continue; visited.add(id); queue.push(...edges[id] ?? []);
  }
  return false;
}

test("actual routers extract every section, reconcile evidence identities, and publish temporal/map shards without image credits", async () => {
  const provider = bookAnalysisFixtureProvider();
  await withHarness(async h => {
    const { generationId, bookId, state, pages } = await completed(h);
    const data = records(pages);
    assert.deepEqual([...new Set(data.entities.map(e => e.kind))].sort(), ["event", "group", "individual", "item_artifact", "location", "world"]);
    const mara = data.entities.find(e => e.names.some(n => n.text === "Mara") && e.firstIntroduction.sectionId === "s1")!;
    const raven = data.entities.find(e => e.names.some(n => n.text === "Raven"))!;
    assert.equal(data.mappings.find(m => m.entityId === raven.id)?.canonicalEntityId, mara.id);
    assert.equal(data.entities.filter(e => e.names.some(n => n.text === "Tomas")).length, 2);
    assert(!data.mappings.some(m => data.entities.filter(e => e.names.some(n => n.text === "Tomas")).some(e => e.id === m.entityId)));
    for (const mention of data.mentions) {
      const section = Number(mention.span.start.sectionId.slice(1)) - 1, block = Number(mention.span.start.blockId.slice(1)) - 1;
      assert.equal(BOOK_ANALYSIS_FIXTURE_SECTIONS[section]![block]!.slice(mention.span.start.offset, mention.span.end.offset), mention.surface);
    }
    assert(data.mentions.some(m => m.surface === "Élan")); assert(data.mentions.some(m => m.surface === "🧙🏽‍♀️"));
    assert.deepEqual([...new Set(data.entries.map(e => e.entryKind))].sort(), ["change", "description", "event", "introduction", "revelation"]);
    const braid = data.assertions.find(a => a.value === "long braid")!, short = data.assertions.find(a => a.value === "short hair")!;
    const dark = data.assertions.find(a => a.value === "permanent dark sky")!, daylight = data.assertions.find(a => a.value === "daylight")!;
    const silver = data.assertions.find(a => a.value === "silver with etched wings")!, stone = data.assertions.find(a => a.value === "stone")!;
    assert.equal(dark.revealAt.sectionId, "s2"); assert.equal(dark.validFromTimeId, braid.validFromTimeId);
    assert.equal(dark.validUntilTimeId, daylight.validFromTimeId); assert(dark.retroactiveWorld);
    assert.equal(silver.revealAt.sectionId, "s2"); assert(!silver.retroactiveWorld);
    assert.equal(stone.validFromTimeId, braid.validFromTimeId);
    assert(data.entries.some(e => e.entryKind === "revelation" && e.assertionIds.includes(stone.id)));
    assert(reaches(data.times, braid.validFromTimeId!, short.validFromTimeId!));
    assert(reaches(data.times, short.validFromTimeId!, daylight.validFromTimeId!));
    const flashback = data.entries.find(e => e.evidence[0].start.sectionId === "s2" && e.evidence[0].start.blockId === "b5")!;
    assert(reaches(data.times, flashback.timeId!, daylight.validFromTimeId!));
    assert(!reaches(data.times, flashback.timeId!, short.validFromTimeId!)); assert(!reaches(data.times, short.validFromTimeId!, flashback.timeId!));
    assert(data.subjects.some(s => s.supersessions.some(x => x.assertionId === short.id && x.supersedesAssertionIds.includes(braid.id))));
    const uniform = data.assertions.filter(a => a.property === "uniform");
    assert.equal(uniform.length, 2); assert(uniform.every(a => a.subjectId !== mara.id));
    const appearance = data.assertions.filter(a => a.property === "appearance");
    assert.equal(appearance.length, 3); assert(appearance.some(a => a.support === "reported")); assert(appearance.some(a => a.support === "uncertain"));
    assert(data.baselines.some(b => b.assertionIds.includes(dark.id))); assert(!data.baselines.some(b => b.assertionIds.includes(daylight.id) || b.assertionIds.includes(silver.id)));
    assert.equal(data.maps.length, 1);
    const relation = data.assertions.find(a => data.maps[0]!.relationAssertionIds.includes(a.id))!;
    assert.equal(relation.property, "inside"); assert.equal(relation.support, "asserted");
    assert.equal(state.processedChunks, 2); assert.equal(state.processedUnits, state.requiredUnits);
    assert(state.finalizedRevision); assert.equal((await bookReference(h.memory.firestore, "books", "owner", bookId).get()).data()?.latestAnalysisGenerationId, generationId);
    assert(![...h.memory.values.keys()].some(k => k.startsWith("bookAnalysisInputs/")));
    assert(![...h.memory.values.keys()].some(k => /^(accounts|creditReservations|illustrationJobs|illustrationScenes)\//u.test(k)));
    assert(!JSON.stringify(pages).includes(BOOK_ANALYSIS_FIXTURE_SECTIONS[0][0]));
    assert.equal(provider.extractionInputs.length, 2); assert(provider.extractionInputs[1]!.chunk.overlap.length > 0);
    for (const input of provider.extractionInputs) assert(JSON.stringify({ candidates: input.candidates, knownTimes: input.knownTimes, knownAssertions: input.knownAssertions }).length <= 16000);
    for (const input of provider.resolutionInputs) { assert(input.candidates.length <= 64); assert(JSON.stringify({ candidates: input.candidates, acceptedMappings: input.acceptedMappings }).length <= 16000); }
    const repeat = await h.extract(generationId, 0); assert(repeat.jobId); assert.equal(provider.extractionInputs.length, 2);
    assert.equal((await h.finalize(generationId)).finalizedRevision, state.finalizedRevision);
    assert.equal((await h.request(`/v1/book-analysis/generations/${generationId}/pages/${pages[0]!.pageId}`, "GET", undefined, "intruder")).status, 404);
  }, provider);
});

test("incomplete extraction and missing immutable shards cannot publish a baseline", async () => {
  await withHarness(async h => {
    const { generationId } = await h.admit();
    assert.equal((await h.request(`/v1/book-analysis/generations/${generationId}/chunks/1`, "POST", h.fixture.chunks[1])).status, 409);
    await h.extract(generationId, 0);
    assert.equal((await h.request(`/v1/book-analysis/generations/${generationId}/finalize`, "POST")).status, 409);
    assert.equal((await h.request(`/v1/book-analysis/generations/${generationId}/pages/entities-0`)).status, 404);
    await h.extract(generationId, 1);
    await h.store.recordReference(generationId, "extraction", "assertions-0").delete();
    const state = await h.finalize(generationId);
    assert.equal(state.status, "failed"); assert.equal(state.finalizedRevision, null); assert.deepEqual(state.resultPages, []);
    assert.equal((await h.request(`/v1/book-analysis/generations/${generationId}/pages/world_baselines-0`)).status, 404);
  });
});

for (const category of ["provider_refusal", "provider_incomplete"] as const) test(`${category} fails terminally, erases prose, and never resubmits paid extraction`, async () => {
  let calls = 0;
  const provider: BookAnalysisProvider = { async extractAnalysisWindow() { calls++; throw new BookAnalysisProviderError(category); }, async resolveAnalysisEntities() { throw new Error("Unexpected resolution."); } };
  await withHarness(async h => {
    const { generationId } = await h.admit();
    const receipt = await h.extract(generationId, 0);
    const state = await h.progress(generationId);
    assert.equal(state.status, "failed"); assert.equal(state.error?.category, category);
    assert(![...h.memory.values.keys()].some(k => k.startsWith("bookAnalysisInputs/")));
    await h.extract(generationId, 0); assert.equal(calls, 1);
    assert.equal((await h.store.jobReference(receipt.jobId!).get()).data()?.providerSubmitted, true);
    assert.equal((await h.finalize(generationId)).status, "failed");
  }, provider);
});

test("injected invalid UTF-16/grapheme mention spans are rejected rather than snapped", async () => {
  const base = bookAnalysisFixtureProvider();
  const provider: BookAnalysisProvider = { ...base, async extractAnalysisWindow(input) {
    const output = await base.extractAnalysisWindow(input);
    const emoji = output.mentions.find(m => m.surface === "🧙🏽‍♀️")!;
    emoji.span.end.offset = emoji.span.start.offset + 1; emoji.surface = "\ud83e";
    return output;
  } };
  await withHarness(async h => {
    const { generationId } = await h.admit(); await h.extract(generationId, 0);
    assert.equal((await h.progress(generationId)).status, "failed");
    assert(![...h.memory.values.values()].some(v => v.recordType === "extraction"));
    assert(![...h.memory.values.keys()].some(k => k.startsWith("bookAnalysisInputs/")));
  }, provider);
});

test("a previously finalized pointer survives a failed replacement generation", async () => {
  const base = bookAnalysisFixtureProvider();
  let replacing = false;
  const provider: BookAnalysisProvider = { ...base, async extractAnalysisWindow(input) {
    if (replacing) throw new BookAnalysisProviderError("provider_incomplete");
    return base.extractAnalysisWindow(input);
  } };
  await withHarness(async h => {
    const previous = await completed(h);
    const replacement = bookAnalysisFixture();
    const source = replacement.chunks[0]!.primary[0]!;
    source.text += " "; source.endOffset++; source.blockLength++; source.hash = analysisSpanHash(source);
    replacement.chunks[0]!.hash = analysisChunkHash(replacement.chunks[0]!.primary);
    replacement.manifest.chunks = replacement.chunks.map(c => ({ ...c, primary: c.primary.map(({ text: _text, ...s }) => s), overlap: c.overlap.map(({ text: _text, ...s }) => s) }));
    replacement.manifest.documentDigest = analysisDocumentDigest(replacement.manifest.chunks);
    const { chunks: _chunks, ...admission } = replacement.manifest;
    const response = await h.request(`/v1/book-analysis/books/${previous.bookId}/generations`, "POST", admission);
    assert.equal(response.status, 200); const receipt = await response.json() as AnalysisReceipt;
    assert.notEqual(receipt.generationId, previous.generationId);
    assert.equal((await h.request(`/v1/book-analysis/generations/${receipt.generationId}/manifest-pages/0`, "PUT", { chunks: replacement.manifest.chunks })).status, 204);
    replacing = true;
    const submission = await h.request(`/v1/book-analysis/generations/${receipt.generationId}/chunks/0`, "POST", replacement.chunks[0]);
    const job = await submission.json() as AnalysisReceipt;
    assert.equal((await h.request(`/internal/book-analysis/extract/${job.jobId}`, "POST")).status, 204);
    assert.equal((await h.progress(receipt.generationId)).error?.category, "provider_incomplete");
    assert(![...h.memory.values.keys()].some(k => k.startsWith("bookAnalysisInputs/")));
    assert.equal((await bookReference(h.memory.firestore, "books", "owner", previous.bookId).get()).data()?.latestAnalysisGenerationId, previous.generationId);
    assert.equal((await h.pages(previous.generationId)).length, previous.pages.length);
    assert.equal((await h.progress(receipt.generationId)).status, "failed");
  }, provider);
});

test("missing unsubmitted TTL input releases a claim until exact chunk restoration", async () => {
  const provider = bookAnalysisFixtureProvider();
  await withHarness(async h => {
    const { generationId } = await h.admit();
    const response = await h.request(`/v1/book-analysis/generations/${generationId}/chunks/0`, "POST", h.fixture.chunks[0]);
    const receipt = await response.json() as AnalysisReceipt;
    await h.store.inputReference(receipt.jobId!).update({ expiresAt: Timestamp.fromMillis(0) });
    assert.equal((await h.request(`/internal/book-analysis/extract/${receipt.jobId}`, "POST")).status, 204);
    assert.equal(provider.extractionInputs.length, 0);
    assert.equal((await h.store.jobReference(receipt.jobId!).get()).data()?.status, "pending");
    await h.extract(generationId, 0); assert.equal(provider.extractionInputs.length, 1);
    assert.equal((await h.progress(generationId)).processedChunks, 1);
  }, provider);
});

test("tombstone-first real deletion purges prose and derived shards and fences a delayed provider", async () => {
  const base = bookAnalysisFixtureProvider();
  let release!: () => void, submitted!: () => void;
  const barrier = new Promise<void>(resolve => { release = resolve; });
  const started = new Promise<void>(resolve => { submitted = resolve; });
  const provider: BookAnalysisProvider = { ...base, async extractAnalysisWindow(input) { submitted(); await barrier; return base.extractAnalysisWindow(input); } };
  await withHarness(async h => {
    const storage = { bucket: () => ({ deleteFiles: async () => {} }) } as unknown as Storage;
    h.app.delete("/fixture/books/:bookId", illustrationBookDeletion({ db: h.memory.firestore, storage, bucket: "fixture" }));
    const { generationId, bookId } = await h.admit();
    const response = await h.request(`/v1/book-analysis/generations/${generationId}/chunks/0`, "POST", h.fixture.chunks[0]);
    const receipt = await response.json() as AnalysisReceipt;
    const delayed = h.request(`/internal/book-analysis/extract/${receipt.jobId}`, "POST");
    await started;
    assert.equal((await h.request(`/fixture/books/${bookId}`, "DELETE")).status, 204);
    release(); assert.equal((await delayed).status, 204);
    assert(![...h.memory.values.values()].some(v => v.bookId === bookId && v.generationId === generationId));
    assert.equal((await h.request(`/v1/book-analysis/generations/${generationId}`)).status, 404);
    // The purge finished, so the same source may register again as a fresh book...
    assert.equal((await h.request("/v1/book-analysis/books", "POST", { schemaVersion: 2, fingerprint: "temporal-fixture", title: "Reimport", chapterCount: 2 })).status, 200);
    // ...without resurrecting the purged generation.
    assert.equal((await h.request(`/v1/book-analysis/generations/${generationId}`)).status, 404);
  }, provider);
});

test("active duplicates adopt 204; owned expired claims return 409 without retrying a submitted provider", async () => {
  const base = bookAnalysisFixtureProvider();
  let release!: () => void, submitted!: () => void;
  const barrier = new Promise<void>(resolve => { release = resolve; });
  const started = new Promise<void>(resolve => { submitted = resolve; });
  let calls = 0;
  const provider: BookAnalysisProvider = { ...base, async extractAnalysisWindow(input) { calls++; submitted(); await barrier; return base.extractAnalysisWindow(input); } };
  await withHarness(async h => {
    const { generationId } = await h.admit();
    const response = await h.request(`/v1/book-analysis/generations/${generationId}/chunks/0`, "POST", h.fixture.chunks[0]);
    const receipt = await response.json() as AnalysisReceipt;
    const delayed = h.request(`/internal/book-analysis/extract/${receipt.jobId}`, "POST");
    await started;
    assert.equal((await h.request(`/internal/book-analysis/extract/${receipt.jobId}`, "POST")).status, 204);
    assert.equal(calls, 1);
    await h.store.jobReference(receipt.jobId!).update({ leaseUntil: Timestamp.fromMillis(0) });
    release(); assert.equal((await delayed).status, 409);
    assert.equal((await h.progress(generationId)).status, "extracting");
    assert.equal((await h.request(`/internal/book-analysis/extract/${receipt.jobId}`, "POST")).status, 204);
    assert.equal((await h.progress(generationId)).error?.category, "provider_incomplete");
    assert.equal(calls, 1);
    assert(![...h.memory.values.keys()].some(k => k.startsWith("bookAnalysisInputs/")));
  }, provider);
});

test("injected cyclic partial-order times fail before extraction coverage commits", async () => {
  const base = bookAnalysisFixtureProvider();
  const provider: BookAnalysisProvider = { ...base, async extractAnalysisWindow(input) {
    const output = await base.extractAnalysisWindow(input);
    output.times[0]!.beforeIds = [output.times[0]!.id];
    return output;
  } };
  await withHarness(async h => {
    const { generationId } = await h.admit(); await h.extract(generationId, 0);
    const state = await h.progress(generationId);
    assert.equal(state.status, "failed"); assert.equal(state.processedChunks, 0); assert.equal(state.finalizedRevision, null);
  }, provider);
});

test("reported identity relations cannot become accepted canonical aliases", async () => {
  const base = bookAnalysisFixtureProvider();
  const provider: BookAnalysisProvider = {
    ...base,
    async extractAnalysisWindow(input) {
      const output = await base.extractAnalysisWindow(input);
      for (const assertion of output.assertions) if (assertion.property === "same_identity") assertion.support = "reported";
      return output;
    },
    async resolveAnalysisEntities(input) {
      const identities = input.candidates.filter(c => c.names.some(n => n.text === "Mara"));
      const proof = identities.flatMap(c => c.identitySupports ?? []).find(s => s.support === "reported");
      if (!proof || identities.length < 2) return { decisions: [], unresolvedEntityIds: input.candidates.map(c => c.id) };
      const ids = identities.map(c => c.id);
      return { decisions: [{ entityIds: ids as [string, string, ...string[]], sameIdentity: true,
        evidence: proof.evidence, revealAt: proof.evidence[0].end }], unresolvedEntityIds: input.candidates.filter(c => !ids.includes(c.id)).map(c => c.id) };
    },
  };
  await withHarness(async h => {
    const { generationId } = await h.admit();
    await h.extract(generationId, 0); await h.extract(generationId, 1);
    const state = await h.finalize(generationId);
    assert.equal(state.status, "failed"); assert.equal(state.error?.category, "invalid_provider_result");
    assert.equal(state.finalizedRevision, null); assert.deepEqual(state.resultPages, []);
  }, provider);
});
