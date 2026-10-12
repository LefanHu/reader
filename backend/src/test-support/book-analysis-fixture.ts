import express from "express";
import type { Server } from "node:http";
import type { AnalysisAssertion, AnalysisChunkInput, AnalysisEntity, AnalysisEvidence, AnalysisPosition, AnalysisSourceManifest, AnalysisSourceSpan, AnalysisSpan, AnalysisWindowInput, AnalysisWindowOutput, BookAnalysisProvider, EntityResolutionBatch, AnalysisProgress, AnalysisReceipt, AnalysisResultPage } from "../book-analysis-types.js";
import { bookAnalysisApiRouter } from "../book-analysis-api.js";
import { bookAnalysisWorkerRouter } from "../book-analysis-worker.js";
import { BookAnalysisStore } from "../book-analysis-store.js";
import { HttpError } from "../http.js";
import { MemoryFirestore } from "./firestore.js";
import { analysisChunkHash, analysisDocumentDigest, analysisOverlapHash, analysisSpanHash } from "../book-analysis-source.js";

/** Two sections intentionally distinguish disclosure, change, partial story time and identity. */
export const BOOK_ANALYSIS_FIXTURE_SECTIONS = [
  [
    "Mara arrived in the valley with a long braid, carrying the named blade Starfall.",
    "The Northwatch patrol wore blue uniforms. Mara was not a member of Northwatch.",
    "The tower stood inside the valley beside the Northwatch patrol.",
    "Tomas the baker greeted Tomas the sailor; they were two different people.",
    "A passerby claimed that Starfall was golden, but nobody could confirm the rumor.",
    "Élan waved beside a multi-code-unit lantern emoji 🧙🏽‍♀️.",
    "The Arrival was the name the villagers gave Mara's arrival.",
  ],
  [
    "The valley had always lain beneath a permanent dark sky, including when Mara arrived.",
    "Mara cut off her long braid. Her hair was now short.",
    "The Northwatch patrol changed from blue to red uniforms in a collective outfit change. Mara remained a nonmember.",
    "After the haircut and the uniform change, a spell called Daybreak made daylight return to the valley.",
    "A flashback showed the valley before Daybreak, still beneath its dark sky; its relation to the haircut was unknown.",
    "Starfall's true appearance was revealed: beneath its cover it was silver and etched with wings, not golden.",
    "Mara revealed that she herself was also called Raven; this was an alias, not another person.",
    "The tower had been stone since before Mara arrived; its material was merely disclosed now, not transformed.",
    "Another unverified report claimed Starfall was black. The conflicting reports remained uncertain.",
  ],
] as const;

export type BookAnalysisFixture = { manifest: AnalysisSourceManifest; chunks: AnalysisChunkInput[]; span(section: number, block: number, surface?: string, occurrence?: number): AnalysisSpan; position(section: number, block: number, offset?: number): AnalysisPosition };
export function bookAnalysisFixture(): BookAnalysisFixture {
  const chunks: AnalysisChunkInput[] = BOOK_ANALYSIS_FIXTURE_SECTIONS.map((blocks, sectionOrdinal) => {
    const primary: AnalysisSourceSpan[] = blocks.map((text, blockOrdinal) => {
      const span = { sectionOrdinal, sectionId: `s${sectionOrdinal + 1}`, blockOrdinal,
        blockId: `b${blockOrdinal + 1}`, startOffset: 0, endOffset: text.length, blockLength: text.length, hash: "", text };
      span.hash = analysisSpanHash(span); return span;
    });
    const previous = sectionOrdinal === 0 ? [] : BOOK_ANALYSIS_FIXTURE_SECTIONS[0].slice(-1).map((text, i) => {
      const span = { sectionOrdinal: 0, sectionId: "s1", blockOrdinal: BOOK_ANALYSIS_FIXTURE_SECTIONS[0].length - 1 + i,
        blockId: `b${BOOK_ANALYSIS_FIXTURE_SECTIONS[0].length + i}`, startOffset: 0, endOffset: text.length, blockLength: text.length, hash: "", text };
      span.hash = analysisSpanHash(span); return span;
    });
    return { ordinal: sectionOrdinal, hash: analysisChunkHash(primary), primary, overlap: previous, overlapHash: analysisOverlapHash(previous) };
  });
  const descriptors = chunks.map(c => ({ ...c, primary: c.primary.map(({ text: _text, ...s }) => s), overlap: c.overlap.map(({ text: _text, ...s }) => s) }));
  const position = (section: number, block: number, offset = 0): AnalysisPosition => ({ sectionId: `s${section + 1}`, blockId: `b${block + 1}`, offset });
  return { chunks, manifest: { model: "gpt-6-luna", 
    documentDigest: analysisDocumentDigest(descriptors), sectionCount: 2, blockCount: BOOK_ANALYSIS_FIXTURE_SECTIONS.reduce((n, s) => n + s.length, 0),
    chunkCount: 2, pageCount: 1, sections: BOOK_ANALYSIS_FIXTURE_SECTIONS.map((s, ordinal) => ({ ordinal, id: `s${ordinal + 1}`, blockCount: s.length })), chunks: descriptors },
    position, span(section, block, surface, occurrence = 0) {
      const text = BOOK_ANALYSIS_FIXTURE_SECTIONS[section]![block]!;
      let offset = 0;
      if (surface) {
        offset = text.indexOf(surface);
        for (let n = 0; n < occurrence; n++) offset = text.indexOf(surface, offset + surface.length);
        if (offset < 0) throw new Error("Fixture surface missing.");
      }
      return { start: position(section, block, offset), end: position(section, block, offset + (surface?.length ?? text.length)) };
    } };
}

/** Local-ID structured provider; the actual worker performs all validation and stable normalization. */
export function bookAnalysisFixtureProvider(fixture = bookAnalysisFixture()): BookAnalysisProvider & { extractionInputs: AnalysisWindowInput[]; resolutionInputs: EntityResolutionBatch[] } {
  const extractionInputs: AnalysisWindowInput[] = [], resolutionInputs: EntityResolutionBatch[] = [];
  return {
    extractionInputs, resolutionInputs,
    async extractAnalysisWindow(input) {
      extractionInputs.push(structuredClone(input));
      const section = input.chunk.ordinal, output: AnalysisWindowOutput = { entities: [], mentions: [], assertions: [], entries: [], times: [] };
      const evidence = (block: number): AnalysisEvidence => [fixture.span(section, block)];
      const entity = (id: string, kind: AnalysisEntity["kind"], block: number, names: string[]) => {
        output.entities.push({ id, kind, names: names.map(text => ({ text, role: text === "Raven" ? "alias" : "name", evidence: [fixture.span(section, block, text)], revealAt: fixture.position(section, block) })), firstIntroduction: fixture.position(section, block) });
        for (const text of names) output.mentions.push({ id: `${id}-mention-${text}`, entityId: id, span: fixture.span(section, block, text), surface: text, role: text === "Raven" ? "alias" : "name" });
        return id;
      };
      const mention = (id: string, subject: string, block: number, text: string) => output.mentions.push({ id, entityId: subject, span: fixture.span(section, block, text), surface: text, role: "name" });
      const time = (id: string, block: number, beforeIds: string[] = [], afterIds: string[] = []) => { output.times.push({ id, beforeIds, afterIds, evidence: evidence(block) }); return id; };
      const assertion = (id: string, subjectId: string, property: string, value: string, block: number, validFromTimeId: string | null, extra: Partial<AnalysisAssertion> = {}) => {
        output.assertions.push({ id, subjectId, property, value, evidence: evidence(block), revealAt: fixture.position(section, block), validFromTimeId,
          validUntilTimeId: null, scope: validFromTimeId === null ? "unknown" : "enduring", support: "asserted", worldCategory: null, retroactiveWorld: false, ...extra }); return id;
      };
      const entry = (id: string, kind: AnalysisWindowOutput["entries"][number]["entryKind"], subjectIds: [string, ...string[]], block: number, timeId: string | null, assertionIds: string[], supersedesAssertionIds: string[] = []) => {
        const entityKind = (id: string) => output.entities.find(e => e.id === id)?.kind ?? input.candidates.find(e => e.id === id)?.kind;
        output.entries.push({ id, entryKind: kind, subjectIds, informationKinds: [...new Set(subjectIds.map(entityKind).filter((k): k is Exclude<AnalysisEntity["kind"], "world"> => !!k && k !== "world"))], summary: `${kind} supported by the selected source evidence.`, evidence: evidence(block), revealAt: fixture.position(section, block), timeId, assertionIds, supersedesAssertionIds });
      };
      if (section === 0) {
        const mara = entity("mara", "individual", 0, ["Mara"]), blade = entity("blade", "item_artifact", 0, ["Starfall"]), valley = entity("valley", "location", 0, ["valley"]);
        const patrol = entity("patrol", "group", 1, ["Northwatch"]), tower = entity("tower", "location", 2, ["tower"]);
        const baker = entity("baker", "individual", 3, ["Tomas"]);
        output.entities.push({ id: "sailor", kind: "individual", names: [{ text: "Tomas", role: "name", evidence: [fixture.span(0, 3, "Tomas", 1)], revealAt: fixture.position(0, 3) }], firstIntroduction: fixture.position(0, 3) });
        output.mentions.push({ id: "sailor-mention", entityId: "sailor", span: fixture.span(0, 3, "Tomas", 1), surface: "Tomas", role: "name" });
        const elan = entity("elan", "individual", 5, ["Élan"]), arrival = entity("arrival-event", "event", 6, ["The Arrival"]);
        const world = entity("world", "world", 5, []);
        output.mentions.push({ id: "emoji", entityId: world, span: fixture.span(0, 5, "🧙🏽‍♀️"), surface: "🧙🏽‍♀️", role: "resolved_reference" });
        const at = time("arrival-time", 0);
        const braid = assertion("long-braid", mara, "hair", "long braid", 0, at);
        const blue = assertion("blue", patrol, "uniform", "blue uniforms", 1, at);
        const membership = assertion("nonmember", mara, "membership.northwatch", "not a member", 1, at);
        const inside = assertion("inside", tower, "inside", "inside the valley", 2, at, { objectEntityId: valley, worldCategory: "geography" });
        const rumor = assertion("gold-rumor", blade, "appearance", "golden", 4, null, { support: "reported" });
        entry("mara-intro", "introduction", [mara, blade, valley], 0, at, [braid]);
        entry("patrol-description", "description", [patrol, mara], 1, at, [blue, membership]);
        entry("map-description", "description", [tower, valley], 2, at, [inside]);
        entry("two-people", "introduction", [baker, "sailor"], 3, at, []);
        entry("rumor-entry", "revelation", [blade], 4, null, [rumor]);
        entry("unicode-entry", "introduction", [elan, world], 5, at, []);
        entry("arrival-entry", "event", [arrival, mara], 6, at, []);
      } else {
        const known = (name: string) => { const found = input.candidates.find(c => c.names.some(n => n.text === name)); if (!found) throw new Error("Fixture candidate missing."); return found.id; };
        const mara = known("Mara"), blade = known("Starfall"), valley = known("valley"), patrol = known("Northwatch"), tower = known("tower");
        const at = input.knownAssertions?.find(a => a.subjectId === mara && a.property === "hair")?.validFromTimeId;
        if (!at) throw new Error("Fixture arrival time missing.");
        const cut = time("cut-time", 1, [], [at]);
        const redTime = time("uniform-time", 2, [], [at]);
        const day = time("day-time", 3, [], [cut, redTime]);
        const flash = time("flashback-time", 4, [day]);
        const reveal = time("reveal-time", 5, [], [day]);
        const dark = assertion("dark-sky", valley, "sky", "permanent dark sky", 0, at, { validUntilTimeId: day, scope: "interval", worldCategory: "ambient_environment", retroactiveWorld: true });
        const hair = assertion("short-hair", mara, "hair", "short hair", 1, cut);
        const red = assertion("red", patrol, "uniform", "red uniforms", 2, redTime);
        const light = assertion("daylight", valley, "sky", "daylight", 3, day, { worldCategory: "ambient_environment" });
        const silver = assertion("silver", blade, "appearance", "silver with etched wings", 5, at);
        const alias = entity("raven", "individual", 6, ["Mara", "Raven"]);
        const aliasFact = assertion("alias-proof", alias, "same_identity", "Mara is also Raven, the same individual", 6, reveal, { objectEntityId: mara });
        const stone = assertion("stone", tower, "material", "stone", 7, at, { worldCategory: "architecture", retroactiveWorld: true });
        const black = assertion("black-rumor", blade, "appearance", "black", 8, null, { support: "uncertain" });
        const daybreak = entity("daybreak", "event", 3, ["Daybreak"]);
        const previous = (subject: string, property: string) => input.knownAssertions?.find(a => a.subjectId === subject && a.property === property)?.id;
        const braid = previous(mara, "hair"), blue = previous(patrol, "uniform");
        entry("baseline-entry", "revelation", [valley], 0, at, [dark]);
        entry("cut-entry", "change", [mara], 1, cut, [hair], braid ? [braid] : []);
        entry("red-entry", "change", [patrol], 2, redTime, [red], blue ? [blue] : []);
        entry("daylight-entry", "change", [valley, daybreak], 3, day, [light], [dark]);
        entry("flashback-entry", "description", [valley], 4, flash, []);
        entry("artifact-entry", "revelation", [blade], 5, reveal, [silver]);
        entry("alias-entry", "revelation", [alias], 6, reveal, [aliasFact]);
        entry("stone-entry", "revelation", [tower], 7, reveal, [stone]);
        entry("black-entry", "revelation", [blade], 8, null, [black]);
        for (const [id, subject, block, name] of [["mara-cut", mara, 1, "Mara"], ["patrol-red", patrol, 2, "Northwatch"], ["valley-day", valley, 3, "valley"], ["blade-reveal", blade, 5, "Starfall"], ["tower-reveal", tower, 7, "tower"]] as const) mention(id, subject, block, name);
      }
      return output;
    },
    async resolveAnalysisEntities(input) {
      resolutionInputs.push(structuredClone(input));
      const mara = input.candidates.filter(c => c.names.some(n => n.text === "Mara"));
      const proof = mara.find(c => c.description.includes("same_identity"));
      if (proof && mara.length >= 2) {
        const evidence = proof.identitySupports?.find(s => s.support === "asserted")?.evidence[0];
        if (!evidence) return { decisions: [], unresolvedEntityIds: input.candidates.map(c => c.id) };
        const merged = mara.map(c => c.id);
        return { decisions: [{ entityIds: merged as [string, string, ...string[]], sameIdentity: true, evidence: [evidence], revealAt: evidence.end }], unresolvedEntityIds: input.candidates.filter(c => !merged.includes(c.id)).map(c => c.id) };
      }
      return { decisions: [], unresolvedEntityIds: input.candidates.map(c => c.id) };
    },
  };
}

export type BookAnalysisFixtureHarness = {
  fixture: BookAnalysisFixture; provider: BookAnalysisProvider; memory: MemoryFirestore; store: BookAnalysisStore;
  tasks: { path: string; payload: Record<string, unknown>; taskId: string }[];
  app: express.Express; server: Server; baseUrl: string;
  request(path: string, method?: string, body?: unknown, uid?: string): Promise<Response>;
  progress(generationId: string): Promise<AnalysisProgress>;
  close(): Promise<void>;
  admit(fingerprint?: string): Promise<{ bookId: string; generationId: string }>;
  extract(generationId: string, ordinal: number): Promise<AnalysisReceipt>;
  finalize(generationId: string): Promise<AnalysisProgress>;
  pages(generationId: string): Promise<AnalysisResultPage[]>;
};

/** Actual public/worker routers on loopback; no auth service, task service or live provider. */
export async function startBookAnalysisFixtureHarness(options: { provider?: BookAnalysisProvider; fixture?: BookAnalysisFixture } = {}): Promise<BookAnalysisFixtureHarness> {
  const fixture = options.fixture ?? bookAnalysisFixture();
  const provider = options.provider ?? bookAnalysisFixtureProvider(fixture);
  const memory = new MemoryFirestore(), store = new BookAnalysisStore(memory.firestore);
  const tasks: { path: string; payload: Record<string, unknown>; taskId: string }[] = [];
  const app = express();
  app.use(express.json({ limit: "1mb" }));
  app.use((req, _res, next) => { (req as express.Request & { uid: string }).uid = req.header("x-test-owner") ?? "owner"; next(); });
  app.use("/api/book-analysis", bookAnalysisApiRouter({ db: memory.firestore, fingerprintSecret: "fixture-secret",
    requireFeature: (_req, _res, next) => next(), enqueue: async (path, payload, taskId) => { tasks.push({ path, payload, taskId }); } }));
  app.use("/internal/book-analysis", bookAnalysisWorkerRouter({ db: memory.firestore, provider }));
  app.use((error: unknown, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
    res.status(error instanceof HttpError ? error.status : 500).json({ error: error instanceof Error ? error.message : "Failed." });
  });
  const server: Server = app.listen(0, "127.0.0.1");
  await new Promise<void>(resolve => server.once("listening", resolve));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("Fixture server did not start.");
  const baseUrl = `http://127.0.0.1:${address.port}`;
  const request = (path: string, method = "GET", body?: unknown, uid = "owner") => fetch(`${baseUrl}${path}`, { method,
    headers: { "content-type": "application/json", "x-test-owner": uid }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  const json = async <T>(path: string, method = "GET", body?: unknown): Promise<T> => {
    const response = await request(path, method, body);
    if (!response.ok) throw new Error(`Fixture HTTP ${response.status}: ${await response.text()}`);
    return response.json() as Promise<T>;
  };
  const progress = (generationId: string) => json<AnalysisProgress>(`/api/book-analysis/generations/${generationId}`);
  return { fixture, provider, memory, store, tasks, app, server, baseUrl, request, progress,
    async close() { await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve())); },
    async admit(fingerprint = "temporal-fixture") {
      const registration = await json<{ bookId: string }>("/api/book-analysis/books", "POST", { fingerprint, title: "Temporal fixture", chapterCount: 2 });
      const { chunks: _chunks, ...admission } = fixture.manifest;
      const receipt = await json<AnalysisReceipt>(`/api/book-analysis/books/${registration.bookId}/generations`, "POST", admission);
      const response = await request(`/api/book-analysis/generations/${receipt.generationId}/manifest-pages/0`, "PUT", { chunks: fixture.manifest.chunks });
      if (response.status !== 204) throw new Error(`Fixture manifest HTTP ${response.status}.`);
      return { bookId: registration.bookId, generationId: receipt.generationId };
    },
    async extract(generationId: string, ordinal: number) {
      const receipt = await json<AnalysisReceipt>(`/api/book-analysis/generations/${generationId}/chunks/${ordinal}`, "POST", fixture.chunks[ordinal]);
      const response = await request(`/internal/book-analysis/extract/${receipt.jobId}`, "POST");
      if (response.status !== 204) throw new Error(`Fixture extraction HTTP ${response.status}.`);
      return receipt;
    },
    async finalize(generationId: string) {
      for (let n = 0; n < 1000; n++) {
        const state = await progress(generationId);
        if (state.status === "complete" || state.status === "failed") return state;
        const receipt = await json<AnalysisReceipt>(`/api/book-analysis/generations/${generationId}/finalize`, "POST");
        const response = await request(`/internal/book-analysis/finalize/${receipt.jobId}`, "POST");
        if (response.status !== 204) throw new Error(`Fixture finalization HTTP ${response.status}.`);
      }
      throw new Error("Fixture finalization cursor did not terminate.");
    },
    async pages(generationId: string): Promise<AnalysisResultPage[]> {
      const state = await progress(generationId);
      const pages: AnalysisResultPage[] = [];
      for (const descriptor of state.resultPages) pages.push(await json<AnalysisResultPage>(`/api/book-analysis/generations/${generationId}/pages/${descriptor.pageId}`));
      return pages;
    },
  };
}
