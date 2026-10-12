import assert from "node:assert/strict";
import test from "node:test";
import { ResponsesBookAnalysisProvider, BookAnalysisProviderError } from "./book-analysis-provider.js";
import { AnalysisValidationError, validateAndNormalizeAnalysisWindow, validateEntityResolution, validateAnalysisTimeGraph } from "./book-analysis-validation.js";
import { analysisSpanHash, analysisChunkHash, analysisOverlapHash } from "./book-analysis-source.js";
import { ANALYSIS_PAGE_MAX_BYTES, type AnalysisWindowInput, type AnalysisWindowOutput, type AnalysisSourceSpan, type AnalysisEvidence, type AnalysisPosition, type EntityResolutionBatch, type EntityResolutionOutput } from "./book-analysis-types.js";
import type { ImageHttpOptions } from "./image-provider-http.js";

const position = (offset: number): AnalysisPosition => ({ sectionId: "section", blockId: "block", offset });
const evidence = (start: number, end: number): AnalysisEvidence => [{ start: position(start), end: position(end) }];
function fixture() {
  const text = "Mara meets A\u0301da 👩🏽‍🚀. Mara is also called Ash.";
  const source: AnalysisSourceSpan = { sectionOrdinal: 0, sectionId: "section", blockOrdinal: 0, blockId: "block", startOffset: 0, endOffset: text.length, blockLength: text.length, hash: "", text };
  source.hash = analysisSpanHash(source);
  const input: AnalysisWindowInput = { generationId: "generation", model: "gpt-6-luna", candidates: [], chunk: { ordinal: 0, hash: analysisChunkHash([source]), primary: [source], overlap: [], overlapHash: analysisOverlapHash([]) } };
  const ash = text.indexOf("Ash");
  const output: AnalysisWindowOutput = {
    entities: [{ id: "person", kind: "individual", names: [{ text: "Mara", role: "name", evidence: evidence(0, 4), revealAt: position(0) }, { text: "Ash", role: "alias", evidence: evidence(ash, ash + 3), revealAt: position(0) }], firstIntroduction: position(999) }],
    mentions: [{ id: "mention", entityId: "person", span: evidence(0, 4)[0], surface: "Mara", role: "name" }],
    entries: [{ id: "reveal", entryKind: "revelation", subjectIds: ["person"], informationKinds: ["individual"], summary: "A second name is disclosed.", evidence: evidence(text.indexOf("Mara", 4), text.length), revealAt: position(0), timeId: "moment", assertionIds: ["fact"], supersedesAssertionIds: [] }],
    assertions: [{ id: "fact", subjectId: "person", property: "same_identity", value: "Ash", evidence: evidence(ash, ash + 3), revealAt: position(0), validFromTimeId: "moment", validUntilTimeId: null, scope: "enduring", support: "asserted", worldCategory: null, retroactiveWorld: false }],
    times: [{ id: "moment", beforeIds: [], afterIds: [], evidence: evidence(0, 4) }],
  };
  return { input, output, text };
}
function response(value: unknown) {
  return { status: "completed", output: [{ type: "message", role: "assistant", status: "completed", content: [{ type: "output_text", text: JSON.stringify(value) }] }] };
}
function liveWire(output: AnalysisWindowOutput) {
  return { ...output, assertions: output.assertions.map(a => ({ ...a, objectEntityId: a.objectEntityId ?? null })), times: output.times.map(t => ({ ...t, label: t.label ?? null })) };
}
function injected(responseValue: Record<string, unknown>, inspect: (body: Record<string, unknown>) => void = () => {}) {
  let calls = 0, closed = 0;
  const provider = new ResponsesBookAnalysisProvider("private-key", {}, () => ({
    async postJson(url, headers, body) { calls++; assert.equal(url, "https://api.openai.com/api/responses"); assert.equal(headers.authorization, "Bearer private-key"); inspect(body); return responseValue; },
    close() { closed++; },
  }));
  return { provider, counts: () => ({ calls, closed }) };
}

test("normalization preserves exact Unicode mentions, stable IDs, candidate references and separate alias reveal", () => {
  const { input, output, text } = fixture();
  const a = validateAndNormalizeAnalysisWindow(input, output), b = validateAndNormalizeAnalysisWindow(input, structuredClone(output));
  assert.deepEqual(a, b); assert.match(a.entities[0]!.id, /^ba_[a-f0-9]{64}$/);
  assert.equal(a.entities[0]!.firstIntroduction.offset, 0);
  assert.equal(a.entities[0]!.names[1]!.revealAt.offset, text.indexOf("Ash") + 3);
  assert.equal(a.entries[0]!.revealAt.offset, text.length);
  assert.equal(a.assertions[0]!.subjectId, a.entities[0]!.id);
  assert.equal(a.assertions[0]!.validFromTimeId, a.times[0]!.id);
  assert.equal(a.mentions[0]!.surface, "Mara");
  const accent = text.indexOf("A\u0301da"), emoji = text.indexOf("👩");
  for (const [start, end] of [[accent, accent + 4], [emoji, emoji + "👩🏽‍🚀".length]]) {
    const valid = structuredClone(output); valid.mentions[0]!.span = evidence(start!, end!)[0]; valid.mentions[0]!.surface = text.slice(start, end);
    assert.equal(validateAndNormalizeAnalysisWindow(input, valid).mentions[0]!.surface, text.slice(start, end));
  }
  const candidate = { ...output.entities[0]!, description: "Known person.", evidence: evidence(0, 4), firstIntroduction: position(0) };
  input.candidates = [candidate]; output.entities = [];
  assert.equal(validateAndNormalizeAnalysisWindow(input, output).mentions[0]!.entityId, "person");
});

test("invalid Unicode, mismatched mentions, hashes, foreign references and overlap-only evidence are rejected, not snapped", () => {
  const { input, output, text } = fixture();
  const invalid: AnalysisWindowOutput[] = [];
  for (const offset of [text.indexOf("A\u0301da") + 1, text.indexOf("👩") + 1, text.indexOf("👩") + 2]) {
    const bad = structuredClone(output); bad.mentions[0]!.span = evidence(offset, offset + 1)[0]; bad.mentions[0]!.surface = text.slice(offset, offset + 1); invalid.push(bad);
  }
  const foreign = structuredClone(output); foreign.mentions[0]!.entityId = "missing"; invalid.push(foreign);
  const mismatched = structuredClone(output); mismatched.mentions[0]!.surface = "Ada"; invalid.push(mismatched);
  const time = structuredClone(output); time.assertions[0]!.validFromTimeId = "missing"; invalid.push(time);
  const assertion = structuredClone(output); assertion.entries[0]!.assertionIds = ["missing"]; invalid.push(assertion);
  const unrelatedName = structuredClone(output); unrelatedName.entities[0]!.names[0]!.text = "Nobody"; invalid.push(unrelatedName);
  for (const bad of invalid) assert.throws(() => validateAndNormalizeAnalysisWindow(input, bad), AnalysisValidationError);
  const badHash = structuredClone(input); badHash.chunk.primary[0]!.text = "x".repeat(text.length);
  assert.throws(() => validateAndNormalizeAnalysisWindow(badHash, output), AnalysisValidationError);
  const overlap = structuredClone(input); overlap.chunk.overlap = overlap.chunk.primary; overlap.chunk.overlapHash = analysisOverlapHash(overlap.chunk.overlap);
  overlap.chunk.primary = [{ ...overlap.chunk.primary[0]!, blockId: "next", blockOrdinal: 1 }]; overlap.chunk.primary[0]!.hash = analysisSpanHash(overlap.chunk.primary[0]!); overlap.chunk.hash = analysisChunkHash(overlap.chunk.primary);
  assert.throws(() => validateAndNormalizeAnalysisWindow(overlap, output), AnalysisValidationError);
});

test("partial time graph rejects cycles, self edges and dangling references without inventing order", () => {
  const { input, output } = fixture();
  output.times.push({ id: "other", beforeIds: [], afterIds: [], evidence: evidence(0, 4) });
  assert.equal(validateAndNormalizeAnalysisWindow(input, output).times.length, 2);
  output.times[0]!.beforeIds = ["other"]; output.times[1]!.beforeIds = ["moment"];
  assert.throws(() => validateAndNormalizeAnalysisWindow(input, output), AnalysisValidationError);
  assert.throws(() => validateAnalysisTimeGraph([{ id: "one", beforeIds: ["one"], afterIds: [], evidence: evidence(0, 4) }]), AnalysisValidationError);
  assert.throws(() => validateAnalysisTimeGraph([{ id: "one", beforeIds: ["missing"], afterIds: [], evidence: evidence(0, 4) }]), AnalysisValidationError);
  output.times[1]!.beforeIds = []; input.knownTimes = [output.times.pop()!];
  assert.equal(validateAndNormalizeAnalysisWindow(input, output).times[0]!.beforeIds[0], "other");
});

test("Responses submission is immutable, strict, prose-preserving and closed once; worker receives local IDs", async () => {
  const { input, output } = fixture();
  const f = injected(response(liveWire(output)), body => {
    assert.equal(body.model, input.model); assert.equal(body.store, false); assert.deepEqual(body.reasoning, { effort: "none" }); assert.deepEqual(body.tools, []); assert.equal(body.max_output_tokens, 16384);
    const text = body.text;
    assert(text && typeof text === "object" && "format" in text);
    const format = text.format;
    assert(format && typeof format === "object" && "name" in format && "strict" in format && "schema" in format);
    assert.equal(format.name, "book_window_analysis"); assert.equal(format.strict, true);
    const schema = format.schema;
    assert(schema && typeof schema === "object" && "additionalProperties" in schema);
    assert.equal(schema.additionalProperties, false);
    assert(Array.isArray(body.input));
    const userInput = body.input[0];
    assert(userInput && typeof userInput === "object" && Array.isArray(userInput.content));
    assert.equal(userInput.content[0].text, JSON.stringify(input));
  });
  assert.equal((await f.provider.extractAnalysisWindow(input)).entities[0]!.id, "person"); assert.deepEqual(f.counts(), { calls: 1, closed: 1 });
});

test("refusal, incomplete, failed, malformed, extra fields and output overflow fail without retries or leaked contents", async () => {
  const { input, output } = fixture();
  const malformed = response(liveWire(output)); malformed.output[0]!.content[0]!.text = "private malformed prose";
  const extra = { ...liveWire(output), privateChapter: "private prose" };
  const overflow = response({ entities: [], mentions: [], entries: [], assertions: [], times: [], padding: "x".repeat(ANALYSIS_PAGE_MAX_BYTES) });
  const refusals = { status: "completed", output: [{ type: "message", role: "assistant", status: "completed", content: [{ type: "refusal", refusal: "private refusal prose" }] }] };
  for (const reply of [refusals, { status: "incomplete", incomplete_details: { reason: "private prose" } }, { status: "failed", error: { message: "private-key" } }, malformed, response(extra), overflow, response(output)]) {
    const f = injected(reply);
    await assert.rejects(f.provider.extractAnalysisWindow(input), error => error instanceof BookAnalysisProviderError && !error.message.includes("private"));
    assert.deepEqual(f.counts(), { calls: 1, closed: 1 });
  }
  const tooLarge = structuredClone(output); tooLarge.mentions = Array.from({ length: 1500 }, (_, n) => ({ ...tooLarge.mentions[0]!, id: `m${n}`, surface: "x".repeat(100) }));
  assert.throws(() => validateAndNormalizeAnalysisWindow(input, tooLarge), AnalysisValidationError);
});

test("transport exceptions are sanitized, operation closes on failure and bounded HTTP transport keeps redirect rejection", async () => {
  const { input } = fixture(); let closed = 0;
  const provider = new ResponsesBookAnalysisProvider("key", {}, () => ({ async postJson() { throw new Error("https://private.example/token=secret user prose"); }, close() { closed++; } }));
  await assert.rejects(provider.extractAnalysisWindow(input), error => error instanceof BookAnalysisProviderError && error.category === "provider_transport" && !error.message.includes("secret")); assert.equal(closed, 1);
  const observed: { signal?: AbortSignal | null } = {}; let calls = 0;
  const http: ImageHttpOptions = { fetch: async (_url, init) => { calls++; assert.equal(init?.redirect, "error"); observed.signal = init?.signal; return new Response(JSON.stringify(response({ entities: [], mentions: [], entries: [], assertions: [], times: [] }))); } };
  await new ResponsesBookAnalysisProvider("key", http).extractAnalysisWindow(input);
  assert.equal(calls, 1); assert(observed.signal?.aborted);
  const oversizedInput = structuredClone(input); oversizedInput.candidates = Array.from({ length: 65 }, (_, n) => ({ id: `c${n}`, kind: "individual", names: [], description: "", evidence: evidence(0, 4), firstIntroduction: position(0) }));
  const f = injected(response({})); await assert.rejects(f.provider.extractAnalysisWindow(oversizedInput), AnalysisValidationError); assert.equal(f.counts().calls, 0);
  let now = 0;
  const deadline = new ResponsesBookAnalysisProvider("key", { now: () => now, fetch: async () => {
    now = 120_001;
    return new Response(JSON.stringify(response({ entities: [], mentions: [], entries: [], assertions: [], times: [] })));
  } });
  await assert.rejects(deadline.extractAnalysisWindow(input), error => error instanceof BookAnalysisProviderError && error.category === "provider_transport");
});

function resolutionFixture() {
  const candidates = ["first", "second"].map(id => ({ id, kind: "individual" as const, names: [{ text: "Mara", role: "name" as const, evidence: evidence(0, 4), revealAt: position(4) }], description: "Explicitly identified by a second name.", evidence: evidence(10, 40), firstIntroduction: position(0), identitySupports: [{ evidence: evidence(10, 40), support: "asserted" as const }] }));
  const batch: EntityResolutionBatch = { generationId: "generation", model: "gpt-6-luna", ordinal: 0, candidates, acceptedMappings: [] };
  const output: EntityResolutionOutput = { decisions: [{ entityIds: ["first", "second"], sameIdentity: true, evidence: evidence(10, 40), revealAt: position(40) }], unresolvedEntityIds: [] };
  return { batch, output };
}

test("bulk resolution requires same-kind supported evidence, complete coverage, exact anchors, never matching names alone", async () => {
  const { batch, output } = resolutionFixture();
  assert.deepEqual(validateEntityResolution(batch, output), output);
  const f = injected(response(output), body => {
    const text = body.text; assert(text && typeof text === "object" && "format" in text);
    const format = text.format; assert(format && typeof format === "object" && "name" in format);
    assert.equal(format.name, "book_entity_resolution");
  });
  assert.deepEqual(await f.provider.resolveAnalysisEntities(batch), output); assert.deepEqual(f.counts(), { calls: 1, closed: 1 });
  const namesOnly = structuredClone(output); namesOnly.decisions[0]!.evidence = evidence(0, 4); namesOnly.decisions[0]!.revealAt = position(4);
  assert.throws(() => validateEntityResolution(batch, namesOnly), AnalysisValidationError);
  const wrongKind = structuredClone(batch); wrongKind.candidates[1]!.kind = "location";
  assert.throws(() => validateEntityResolution(wrongKind, output), AnalysisValidationError);
  const invented = structuredClone(output); invented.decisions[0]!.evidence = evidence(10, 39); invented.decisions[0]!.revealAt = position(39);
  assert.throws(() => validateEntityResolution(batch, invented), AnalysisValidationError);
  const early = structuredClone(output); early.decisions[0]!.revealAt = position(0);
  assert.throws(() => validateEntityResolution(batch, early), AnalysisValidationError);
  for (const support of ["reported", "uncertain"] as const) {
    const untrusted = structuredClone(batch);
    for (const candidate of untrusted.candidates) candidate.identitySupports![0]!.support = support;
    assert.throws(() => validateEntityResolution(untrusted, output), AnalysisValidationError);
  }
  const unsupported = structuredClone(batch); unsupported.candidates.forEach(c => delete c.identitySupports);
  assert.throws(() => validateEntityResolution(unsupported, output), AnalysisValidationError);
  const prior = structuredClone(unsupported); prior.acceptedMappings = [{ entityId: "first", canonicalEntityId: "second", evidence: evidence(10, 40), revealAt: position(40) }];
  assert.deepEqual(validateEntityResolution(prior, output), output);
  assert.throws(() => validateEntityResolution(batch, { decisions: [], unresolvedEntityIds: ["first"] }), AnalysisValidationError);
  assert.deepEqual(validateEntityResolution(batch, { decisions: [], unresolvedEntityIds: ["first", "second"] }), { decisions: [], unresolvedEntityIds: ["first", "second"] });
  const tooMuch = structuredClone(batch); tooMuch.candidates = Array.from({ length: 64 }, (_, n) => ({ ...batch.candidates[0]!, id: `person${n}`, description: "x".repeat(2048) }));
  await assert.rejects(f.provider.resolveAnalysisEntities(tooMuch), AnalysisValidationError); assert.equal(f.counts().calls, 1);
  const conflictBatch = structuredClone(batch);
  conflictBatch.candidates.push({ ...batch.candidates[0]!, id: "third" });
  const contradictory: EntityResolutionOutput = { decisions: [
    { ...output.decisions[0]!, entityIds: ["first", "second"] },
    { ...output.decisions[0]!, entityIds: ["second", "third"] },
    { ...output.decisions[0]!, entityIds: ["first", "third"], sameIdentity: false },
  ], unresolvedEntityIds: [] };
  assert.throws(() => validateEntityResolution(conflictBatch, contradictory), AnalysisValidationError);
});

test("bounded carry and invalid retroactive categories are rejected before publication; candidate alias updates keep identity", () => {
  const { input, output, text } = fixture();
  const candidate = { ...output.entities[0]!, firstIntroduction: position(0), description: "Known subject.", evidence: evidence(0, 4) };
  input.candidates = [candidate];
  output.entities[0]!.names = [output.entities[0]!.names[1]!];
  const normalized = validateAndNormalizeAnalysisWindow(input, output);
  assert.equal(normalized.entities[0]!.id, "person");
  assert.equal(normalized.entities[0]!.firstIntroduction.offset, 0);
  assert.equal(normalized.entities[0]!.names[0]!.revealAt.offset, text.indexOf("Ash") + 3);
  output.assertions[0]!.worldCategory = "world_rule"; output.assertions[0]!.retroactiveWorld = true;
  assert.throws(() => validateAndNormalizeAnalysisWindow(input, output), AnalysisValidationError);
  const carry = fixture(); carry.input.candidates = Array.from({ length: 10 }, (_, n) => ({ ...candidate, id: `candidate${n}`, description: "x".repeat(2048) }));
  assert.throws(() => validateAndNormalizeAnalysisWindow(carry.input, carry.output), AnalysisValidationError);
  const enumCase = fixture(); enumCase.output.entities[0]!.kind = "unsupported" as typeof enumCase.output.entities[number]["kind"];
  assert.throws(() => validateAndNormalizeAnalysisWindow(enumCase.input, enumCase.output), AnalysisValidationError);
});
