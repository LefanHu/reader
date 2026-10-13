import express from "express";
import type { Firestore } from "firebase-admin/firestore";
import { asyncRoute, HttpError, routeParam } from "./http.js";
import { BookAnalysisStore, CancelledAnalysisClaim, type AnalysisClaim, type StoredAnalysisGeneration } from "./book-analysis-store.js";
import { analysisJsonHash, validateAnalysisPageSize } from "./book-analysis-source.js";
import { AnalysisValidationError, validateAndNormalizeAnalysisWindow, validateEntityResolution, validateAnalysisWindowInput } from "./book-analysis-validation.js";
import { BookAnalysisProviderError } from "./book-analysis-provider.js";
import type {
  AnalysisIdentityCandidate, AnalysisWindowInput, AnalysisWindowOutput,
  AnalysisResultPage, AnalysisResultPageDescriptor, AnalysisEntityMapping, AnalysisPosition,
  AnalysisTime, AnalysisAssertion, BookAnalysisProvider, EntityResolutionBatch, AnalysisResultPageKind, WorldBaseline,
} from "./book-analysis-types.js";
import { ANALYSIS_IDENTITY_PROPERTY } from "./book-analysis-types.js";

type Row = Record<string, unknown>;
type Identity = { candidate: AnalysisIdentityCandidate; parent: string; rank: number; canonical: string; chunk: number; mapping?: AnalysisEntityMapping };
type State = { chunk: number; entity: number; shard: number; name?: number; peer?: number; depth?: number; time?: number };
const SHARD = 32;
const MAX_STEPS = 32;
const normalize = (text: string) => text.normalize("NFC").toLocaleLowerCase("und").replace(/\s+/gu, " ").trim();
const token = (text: string) => normalize(text).match(/[\p{L}\p{N}]+/u)?.[0] ?? normalize(text);
const key = (kind: string, value: unknown) => `${kind}:${analysisJsonHash(value)}`;
const fields = { entities: "entities", mentions: "mentions", entries: "entries", assertions: "assertions", times: "times" } as const;
const resultFields = { ...fields, entity_mappings: "entityMappings", time_mappings: "timeMappings",
  subject_indexes: "subjectIndexes", world_baselines: "worldBaselines", world_maps: "worldMaps" } as const;
const RESULT_BUFFER_BYTES = 60 * 1024;

/** All mutable lookup heads are derived data, updated only under the identical live task claim. */
class Work {
  constructor(readonly store: BookAnalysisStore, readonly claim: AnalysisClaim) {}
  async read<T = Row>(name: string): Promise<T | null> {
    return (await this.store.readWorkRecord(this.claim.generationId, name))?.data as T | undefined ?? null;
  }
  async update(name: string, change: (old: Row | null) => Row) {
    await this.store.db.runTransaction(async tx => {
      await this.store.liveClaim(tx, this.claim);
      const ref = this.store.recordReference(this.claim.generationId, "work", name);
      const prior = (await tx.get(ref)).data();
      const data = change(prior?.data as Row | undefined ?? null);
      const value = { recordType: "work", uid: this.claim.uid, bookId: this.claim.bookId,
        generationId: this.claim.generationId, key: name, data };
      validateAnalysisPageSize(value);
      tx.set(ref, value);
    });
  }
  async set(name: string, data: Row) { await this.update(name, () => data); }
  async append(name: string, id: string) {
    await this.store.db.runTransaction(async tx => {
      await this.store.liveClaim(tx, this.claim);
      const headRef = this.store.recordReference(this.claim.generationId, "work", name);
      const memberName = key("membership", [name, id]), memberRef = this.store.recordReference(this.claim.generationId, "work", memberName);
      const [headSnapshot, member] = await Promise.all([tx.get(headRef), tx.get(memberRef)]);
      if (member.exists) return;
      const count = ((headSnapshot.data()?.data as { count: number } | undefined)?.count ?? 0);
      const shardName = `${name}:${Math.floor(count / SHARD)}`, shardRef = this.store.recordReference(this.claim.generationId, "work", shardName);
      const shard = (await tx.get(shardRef)).data()?.data as { ids: string[] } | undefined;
      for (const [ref, recordKey, data] of [
        [headRef, name, { count: count + 1 }], [memberRef, memberName, { present: true }],
        [shardRef, shardName, { ids: [...(shard?.ids ?? []), id] }],
      ] as const) tx.set(ref, { recordType: "work", uid: this.claim.uid, bookId: this.claim.bookId,
        generationId: this.claim.generationId, key: recordKey, data });
    });
  }
  async mutate(records: { name: string; data: Row }[]) {
    await this.store.db.runTransaction(async tx => {
      await this.store.liveClaim(tx, this.claim);
      for (const { name, data } of records) {
        const value = { recordType: "work", uid: this.claim.uid, bookId: this.claim.bookId,
          generationId: this.claim.generationId, key: name, data };
        validateAnalysisPageSize(value);
        tx.set(this.store.recordReference(this.claim.generationId, "work", name), value);
      }
    });
  }
  async ids(name: string, shard: number): Promise<string[]> {
    return (await this.read<{ ids: string[] }>(`${name}:${shard}`))?.ids ?? [];
  }
  async root(id: string): Promise<{ id: string; identity: Identity }> {
    // Union by rank bounds depth by log2(identity count), not narrative length.
    for (let depth = 0; depth < 54; depth++) {
      const identity = await this.read<Identity>(key("identity", id));
      if (!identity) throw new Error("invalid_reference");
      if (identity.parent === id) return { id, identity };
      id = identity.parent;
    }
    throw new Error("invalid_identity_graph");
  }
}

/**
 * Write-back view for one indexing pass. Reads see pending writes; commit applies them in
 * order through a few transactions, each with one live-claim check, instead of a transaction
 * (and its four-document claim read) per record. Indexing runs after the paid provider call,
 * so an interrupted pass is never retried: the job then fails as provider_incomplete and its
 * partial derived records are unused.
 */
class WorkBatch {
  private readonly pending = new Map<string, Row>();
  constructor(readonly work: Work) {}
  async read<T = Row>(name: string): Promise<T | null> {
    return this.pending.has(name) ? this.pending.get(name) as T : this.work.read<T>(name);
  }
  set(name: string, data: Row) { this.pending.set(name, data); }
  async update(name: string, change: (old: Row | null) => Row) { this.set(name, change(await this.read(name))); }
  /** Same sharded membership layout as Work.append. */
  async append(name: string, id: string) {
    const memberName = key("membership", [name, id]);
    if (await this.read(memberName)) return;
    const count = (await this.read<{ count: number }>(name))?.count ?? 0;
    const shardName = `${name}:${Math.floor(count / SHARD)}`;
    const shard = await this.read<{ ids: string[] }>(shardName);
    this.set(name, { count: count + 1 });
    this.set(memberName, { present: true });
    this.set(shardName, { ids: [...(shard?.ids ?? []), id] });
  }
  async commit() {
    const records = [...this.pending].map(([name, data]) => ({ name, data }));
    // Firestore allows 500 writes per transaction; leave room for the claim reads.
    for (let start = 0; start < records.length; start += 400) await this.work.mutate(records.slice(start, start + 400));
    this.pending.clear();
  }
}

/** Reads independent records concurrently, in bounded groups, preserving input order. */
async function readAll<T, R>(items: T[], read: (item: T) => Promise<R>): Promise<R[]> {
  const results: R[] = [];
  for (let start = 0; start < items.length; start += 64) results.push(...await Promise.all(items.slice(start, start + 64).map(read)));
  return results;
}

function comparePosition(g: StoredAnalysisGeneration, a: AnalysisPosition, b: AnalysisPosition): number {
  const sections = g.admission.sections;
  const sa = sections.findIndex(s => s.id === a.sectionId), sb = sections.findIndex(s => s.id === b.sectionId);
  if (sa !== sb) return sa - sb;
  // Block order is recorded at extraction, not guessed from arbitrary block IDs.
  return a.blockId === b.blockId ? a.offset - b.offset : 0;
}
async function earliest(work: Work, g: StoredAnalysisGeneration, a: string, b: string) {
  const x = (await work.read<Identity>(key("identity", a)))!, y = (await work.read<Identity>(key("identity", b)))!;
  const px = await work.read<{ ordinal: number }>(key("position", [x.candidate.firstIntroduction.sectionId, x.candidate.firstIntroduction.blockId]));
  const py = await work.read<{ ordinal: number }>(key("position", [y.candidate.firstIntroduction.sectionId, y.candidate.firstIntroduction.blockId]));
  const order = comparePosition(g, x.candidate.firstIntroduction, y.candidate.firstIntroduction) ||
    (px?.ordinal ?? 0) - (py?.ordinal ?? 0) || x.candidate.firstIntroduction.offset - y.candidate.firstIntroduction.offset;
  return order < 0 || (order === 0 && a < b) ? a : b;
}
async function merge(work: Work, g: StoredAnalysisGeneration, ids: string[], mapping: Omit<AnalysisEntityMapping, "entityId" | "canonicalEntityId">) {
  let root = await work.root(ids[0]!);
  for (const id of ids.slice(1)) {
    let other = await work.root(id);
    if (root.id === other.id) continue;
    if (root.identity.candidate.kind !== other.identity.candidate.kind) throw new Error("invalid_identity_merge");
    const canonical = await earliest(work, g, root.identity.canonical, other.identity.canonical);
    if (root.identity.rank < other.identity.rank || (root.identity.rank === other.identity.rank && root.id > other.id)) [root, other] = [other, root];
    await work.set(key("identity", other.id), { ...other.identity, parent: root.id,
      mapping: { entityId: other.id, canonicalEntityId: canonical, ...mapping } });
    root.identity = { ...root.identity, canonical, rank: root.identity.rank + (root.identity.rank === other.identity.rank ? 1 : 0),
      ...(root.id === canonical ? {} : { mapping: { entityId: root.id, canonicalEntityId: canonical, ...mapping } }) };
    await work.set(key("identity", root.id), root.identity);
  }
}
async function extraction(store: BookAnalysisStore, g: StoredAnalysisGeneration, ordinal: number): Promise<AnalysisWindowOutput> {
  const job = await store.readExtractionJob(g.generationId, ordinal);
  if (!job || job.status !== "complete" || !job.resultPages || job.resultPages.length !== 5) throw new Error("incomplete_extraction");
  const output: AnalysisWindowOutput = { entities: [], mentions: [], entries: [], assertions: [], times: [] };
  for (const descriptor of job.resultPages) {
    const page = await store.readStagingPage(g.generationId, "extraction", descriptor.pageId);
    if (!page || analysisJsonHash(page) !== descriptor.checksum || store.pageDescriptor(page).byteLength !== descriptor.byteLength || !(page.kind in fields)) throw new Error("incomplete_extraction");
    const kind = page.kind as keyof typeof fields;
    Object.assign(output, { [kind]: page[kind] });
  }
  return output;
}
function page(g: StoredAnalysisGeneration, kind: AnalysisResultPageKind, ordinal: number, data: Row): AnalysisResultPage {
  return { generationId: g.generationId, pageId: `${kind}-${ordinal}`, kind, ordinal, ...data };
}
/** Pack across windows: sparse/large books do not pay one descriptor per empty kind/window.
 * Bytes stay bounded, and buffer+input receipts+catalog move atomically after immutable pages are durable.
 */
async function recordPages(store: BookAnalysisStore, work: Work, g: StoredAnalysisGeneration, input: AnalysisResultPage[], flush = false) {
  const changes: { name: string; data: Row }[] = [], ready: AnalysisResultPage[] = [];
  const kinds = flush ? Object.keys(resultFields) as AnalysisResultPageKind[] : input.map(p => p.kind);
  for (const kind of kinds) {
    const field = resultFields[kind], source = input.find(p => p.kind === kind);
    const supplied = source?.[field] as unknown[] | undefined ?? [];
    if (!flush && supplied.length === 0) continue;
    const receipt = key("buffered_input", [work.claim.jobId, source?.pageId ?? kind]);
    if (!flush && await work.read(receipt)) continue;
    const bufferName = `result_buffer:${kind}`;
    const buffer = await work.read<{ recordsJson: string; bytes: number; ordinal: number }>(bufferName);
    let records = JSON.parse(buffer?.recordsJson ?? "[]") as unknown[], bytes = buffer?.bytes ?? 0, ordinal = buffer?.ordinal ?? 0;
    for (const record of supplied) {
      const length = Buffer.byteLength(JSON.stringify(record), "utf8");
      if (records.length && bytes + length > RESULT_BUFFER_BYTES) {
        ready.push(page(g, kind, ordinal++, { [field]: records })); records = []; bytes = 0;
      }
      records.push(record); bytes += length;
      if (bytes > RESULT_BUFFER_BYTES) {
        // A large individual record is never truncated; the durable writer enforces its true document bound.
        ready.push(page(g, kind, ordinal++, { [field]: records })); records = []; bytes = 0;
      }
    }
    if (flush && records.length) { ready.push(page(g, kind, ordinal++, { [field]: records })); records = []; bytes = 0; }
    changes.push({ name: bufferName, data: { recordsJson: JSON.stringify(records), bytes, ordinal } });
    if (!flush) changes.push({ name: receipt, data: { applied: true } });
  }
  const descriptors = await store.writeStagingPages(work.claim, ready);
  const catalog = await work.read<{ pages: AnalysisResultPageDescriptor[] }>("result_catalog");
  const prior = catalog?.pages ?? [];
  changes.push({ name: "result_catalog", data: { pages: [...prior, ...descriptors.filter(d => !prior.some(p => p.pageId === d.pageId))] } });
  await work.mutate(changes);
  return descriptors;
}
async function candidates(work: Work, g: StoredAnalysisGeneration, chunk: AnalysisWindowInput["chunk"]) {
  const text = normalize([...chunk.primary, ...chunk.overlap].map(s => s.text).join("\n"));
  const ids = new Set<string>();
  // A window holds at most ~2,000 distinct tokens; scanning all keeps a late name from being skipped.
  const words = [...new Set(text.match(/[\p{L}\p{N}]+/gu) ?? [])].map(word => key("names", word));
  const heads = await readAll(words, name => work.read<{ count: number }>(name));
  const shards = await readAll(words.flatMap((name, n) => {
    const head = heads[n];
    return head ? [...new Set([0, Math.floor((head.count - 1) / SHARD)])].map(shard => ({ name, shard })) : [];
  }), ({ name, shard }) => work.ids(name, shard));
  for (const shard of shards) for (const id of shard) ids.add(id);
  // Direct surfaces precede the most recent references and earliest introductions. Omitted rows remain indexed.
  const recent = await work.read<{ ids: string[] }>("recent");
  for (const id of recent?.ids ?? []) ids.add(id);
  for (const id of await work.ids("introductions", 0)) ids.add(id);
  const rows: Array<{ identity: Identity; matched: boolean; recent: number; blockOrdinal: number }> = [];
  const loaded = await readAll([...ids].slice(0, 512), async id => {
    const identity = await work.read<Identity>(key("identity", id));
    if (!identity) return null;
    const anchor = identity.candidate.firstIntroduction;
    return { id, identity, position: await work.read<{ ordinal: number }>(key("position", [anchor.sectionId, anchor.blockId])) };
  });
  for (const entry of loaded) {
    if (!entry) continue;
    const { id, identity, position } = entry;
    const reference = recent?.ids.indexOf(id) ?? -1;
    rows.push({ identity, matched: identity.candidate.names.some(n => text.includes(normalize(n.text))),
      recent: reference < 0 ? Number.MAX_SAFE_INTEGER : reference, blockOrdinal: position?.ordinal ?? 0 });
  }
  rows.sort((a, b) => Number(b.matched) - Number(a.matched) || a.recent - b.recent ||
    comparePosition(g, a.identity.candidate.firstIntroduction, b.identity.candidate.firstIntroduction) ||
    a.blockOrdinal - b.blockOrdinal || a.identity.candidate.firstIntroduction.offset - b.identity.candidate.firstIntroduction.offset ||
    a.identity.candidate.id.localeCompare(b.identity.candidate.id));
  const selected: AnalysisIdentityCandidate[] = [], knownTimes: AnalysisTime[] = [], knownAssertions: AnalysisAssertion[] = [];
  for (const { identity } of rows) {
    if (selected.length >= 64) break;
    const candidate = identity.candidate;
    if (JSON.stringify({ candidates: [...selected, candidate], knownTimes, knownAssertions }).length > 16_000) continue;
    selected.push(candidate);
    const supported = await work.read<{ assertions: AnalysisAssertion[] }>(key("support", candidate.id));
    for (const assertion of supported?.assertions ?? []) {
      const times: AnalysisTime[] = [];
      for (const id of [assertion.validFromTimeId, assertion.validUntilTimeId]) if (id && !knownTimes.some(t => t.id === id)) {
        const time = await work.read<{ time: AnalysisTime }>(key("time", id));
        if (time) times.push(time.time);
      }
      if (JSON.stringify({ candidates: selected, knownTimes: [...knownTimes, ...times], knownAssertions: [...knownAssertions, assertion] }).length <= 16_000) {
        knownAssertions.push(assertion); knownTimes.push(...times);
      }
    }
  }
  return { candidates: selected, knownTimes, knownAssertions };
}
async function indexExtraction(claimed: Work, input: AnalysisWindowInput, output: AnalysisWindowOutput) {
  const work = new WorkBatch(claimed);
  for (const span of input.chunk.primary) await work.set(key("position", [span.sectionId, span.blockId]), { ordinal: span.blockOrdinal });
  for (const entity of output.entities) {
    const existing = await work.read<Identity>(key("identity", entity.id));
    const supported = output.assertions.filter(a => a.subjectId === entity.id);
    const evidence = [...entity.names.flatMap(n => n.evidence), ...supported.filter(a => a.support === "asserted").flatMap(a => a.evidence)];
    if (!evidence.length) evidence.push(...output.mentions.filter(m => m.entityId === entity.id).map(m => m.span));
    if (!evidence.length) evidence.push(...output.entries.filter(e => e.subjectIds.includes(entity.id)).flatMap(e => e.evidence));
    if (!evidence.length) throw new Error("invalid_entity_evidence");
    const names = entity.names.slice(0, 8).map(n => ({ ...n, evidence: n.evidence.slice(0, 2) as typeof n.evidence }));
    const identitySupports = supported.filter(a => a.property === ANALYSIS_IDENTITY_PROPERTY).slice(0, 4)
      .map(a => ({ evidence: a.evidence.slice(0, 2) as typeof a.evidence, support: a.support }));
    const candidate: AnalysisIdentityCandidate = { ...entity, names, evidence: evidence.slice(0, 8) as AnalysisIdentityCandidate["evidence"], identitySupports,
      description: supported.filter(a => a.support === "asserted").slice(0, 4).map(a => `${a.property}: ${a.value}`).join("; ").slice(0, 1000) };
    const combined = existing ? { ...candidate, names: [...existing.candidate.names.slice(0, 1), ...candidate.names.filter(n =>
      !existing.candidate.names.slice(0, 1).some(old => analysisJsonHash(old) === analysisJsonHash(n)))].slice(0, 8), firstIntroduction: existing.candidate.firstIntroduction } : candidate;
    await work.set(key("identity", entity.id), existing ? { ...existing, candidate: combined, chunk: input.chunk.ordinal } :
      { candidate, parent: entity.id, rank: 0, canonical: entity.id, chunk: input.chunk.ordinal });
    for (const word of new Set(entity.names.map(n => token(n.text)))) await work.append(key("names", word), entity.id);
    for (const name of entity.names) await work.update(key("surface", [entity.id, normalize(name.text)]), old => old ?? { name });
    await work.append("introductions", entity.id);
    await work.set(key("support", entity.id), { assertions: supported.slice(0, 16) });
  }
  for (const subjectId of new Set(output.assertions.map(a => a.subjectId))) {
    const prior = await work.read<{ assertions: AnalysisAssertion[] }>(key("support", subjectId));
    const current = output.assertions.filter(a => a.subjectId === subjectId);
    await work.set(key("support", subjectId), { assertions: [...current, ...(prior?.assertions ?? [])].filter((a, n, all) => all.findIndex(b => b.id === a.id) === n).slice(0, 16) });
    const identity = await work.read<Identity>(key("identity", subjectId));
    if (identity) {
      const addedSupports = current.filter(a => a.property === ANALYSIS_IDENTITY_PROPERTY)
        .map(a => ({ evidence: a.evidence.slice(0, 2) as typeof a.evidence, support: a.support }));
      await work.set(key("identity", subjectId), { ...identity, chunk: input.chunk.ordinal, candidate: { ...identity.candidate,
        identitySupports: [...addedSupports, ...(identity.candidate.identitySupports ?? [])].slice(0, 4),
      } });
    }
  }
  for (const assertion of output.assertions) if (assertion.objectEntityId && assertion.property === ANALYSIS_IDENTITY_PROPERTY) {
    await work.append(key("related", assertion.subjectId), assertion.objectEntityId);
    await work.append(key("related", assertion.objectEntityId), assertion.subjectId);
    // The relation proves both endpoints, so the object carries the same support.
    const object = await work.read<Identity>(key("identity", assertion.objectEntityId));
    if (object) await work.set(key("identity", assertion.objectEntityId), { ...object, candidate: { ...object.candidate,
      identitySupports: [{ evidence: assertion.evidence.slice(0, 2) as typeof assertion.evidence, support: assertion.support },
        ...(object.candidate.identitySupports ?? [])].slice(0, 4) } });
  }
  for (const time of output.times) await work.set(key("time", time.id), { time, color: 0 });
  const previous = await work.read<{ ids: string[] }>("recent");
  work.set("recent", { ids: [...new Set([...output.mentions.map(m => m.entityId).reverse(), ...output.entities.map(e => e.id), ...(previous?.ids ?? [])])].slice(0, 64) });
  await work.commit();
}

async function reconcile(store: BookAnalysisStore, work: Work, g: StoredAnalysisGeneration, provider: BookAnalysisProvider) {
  const state = await work.read<State>("reconcile_state") ?? { chunk: 0, entity: 0, shard: 0, name: 0, peer: 0 };
  if (state.chunk >= g.admission.chunkCount) { await store.commitFinalization(work.claim, { stage: "materialize", ordinal: 0 }); return; }
  const output = await extraction(store, g, state.chunk);
  const entity = output.entities[state.entity];
  if (!entity) {
    await work.set("reconcile_state", { chunk: state.chunk + 1, entity: 0, shard: 0, name: 0, peer: 0 });
    await store.commitFinalization(work.claim, { stage: "reconcile", ordinal: g.cursor.ordinal + 1 }); return;
  }
  const names = [...new Set(entity.names.map(n => token(n.text)))].sort();
  const name = names[state.name ?? 0];
  const related = (state.name ?? 0) === names.length;
  if (name === undefined && !related) { state.entity++; state.name = 0; state.shard = 0; state.peer = 0; }
  else {
    const bucket = related ? key("related", entity.id) : key("names", name!);
    const head = await work.read<{ count: number }>(bucket);
    if (state.shard * SHARD >= (head?.count ?? 0)) { state.name = (state.name ?? 0) + 1; state.shard = 0; state.peer = 0; }
    else {
      const peers = await work.ids(bucket, state.shard);
      const found = await work.read<Identity>(key("identity", entity.id));
      if (!found) throw new Error("invalid_reference");
      const summarize = (candidate: AnalysisIdentityCandidate): AnalysisIdentityCandidate => {
        const identitySupports = candidate.identitySupports?.slice(0, 1).map(s => ({ ...s, evidence: s.evidence.slice(0, 1) as typeof s.evidence }));
        return { ...candidate, names: candidate.names.slice(0, 1).map(n => ({ ...n, evidence: n.evidence.slice(0, 1) as typeof n.evidence })),
          evidence: candidate.evidence.slice(0, 1) as typeof candidate.evidence, description: candidate.description.slice(0, 256),
          ...(identitySupports ? { identitySupports } : {}) };
      };
      const anchorName = entity.names.find(n => token(n.text) === name);
      const selected = [summarize(anchorName ? { ...found.candidate, names: [anchorName] } : found.candidate)];
      for (; (state.peer ?? 0) < peers.length; state.peer = (state.peer ?? 0) + 1) {
        const id = peers[state.peer ?? 0]!;
        if (id === entity.id) continue;
        const other = await work.read<Identity>(key("identity", id));
        if (!other || other.candidate.kind !== entity.kind) continue;
        let matchedName = other.candidate.names.find(n => entity.names.some(e => normalize(e.text) === normalize(n.text)));
        if (!related && !matchedName) for (const alias of entity.names) {
          const stored = await work.read<{ name: AnalysisIdentityCandidate["names"][number] }>(key("surface", [id, normalize(alias.text)]));
          if (stored) { matchedName = stored.name; break; }
        }
        if (!related && !matchedName) continue;
        if (await work.read(key("considered", [entity.id, id].sort()))) continue;
        if ((await work.root(entity.id)).id === (await work.root(id)).id) continue;
        const summary = summarize(matchedName ? { ...other.candidate, names: [matchedName] } : other.candidate);
        if (JSON.stringify([...selected, summary]).length > 14_000) {
          if (selected.length === 1) throw new Error("resolution_context_overflow");
          break; // Next authenticated cursor resumes at this candidate; no truncation of the component.
        }
        selected.push(summary);
      }
      if (selected.length > 1) await resolveBatch(store, work, g, provider, selected);
      if ((state.peer ?? 0) >= peers.length) { state.shard++; state.peer = 0; }
    }
  }
  await work.set("reconcile_state", state);
  await store.commitFinalization(work.claim, { stage: "reconcile", ordinal: g.cursor.ordinal + 1 });
}
async function resolveBatch(store: BookAnalysisStore, work: Work, g: StoredAnalysisGeneration, provider: BookAnalysisProvider, candidates: AnalysisIdentityCandidate[]) {
  const acceptedMappings: AnalysisEntityMapping[] = [];
  for (const candidate of candidates) {
    const root = await work.root(candidate.id);
    const prior = await work.read<Identity>(key("identity", candidate.id));
    if (root.identity.canonical !== candidate.id) acceptedMappings.push({ entityId: candidate.id, canonicalEntityId: root.identity.canonical,
      evidence: prior?.mapping?.evidence ?? candidate.evidence, revealAt: prior?.mapping?.revealAt ?? candidate.firstIntroduction });
  }
  // Accepted mappings are context, not a new disclosure claim. Never exceed the provider's fixed bound.
  const batch: EntityResolutionBatch = { generationId: g.generationId, model: g.admission.model,
    ordinal: g.cursor.ordinal, candidates, acceptedMappings };
  while (JSON.stringify(batch).length > 16_000 && batch.acceptedMappings.length) batch.acceptedMappings.pop();
  if (JSON.stringify(batch).length > 16_000) throw new Error("resolution_context_overflow");
  if (!await store.beginProviderSubmission(work.claim)) return;
  const result = validateEntityResolution(batch, await provider.resolveAnalysisEntities(batch));
  for (const decision of result.decisions) if (decision.sameIdentity) {
    let revealAt = decision.evidence[0].end;
    for (const span of decision.evidence.slice(1)) {
      const a = await work.read<{ ordinal: number }>(key("position", [revealAt.sectionId, revealAt.blockId]));
      const b = await work.read<{ ordinal: number }>(key("position", [span.end.sectionId, span.end.blockId]));
      const order = comparePosition(g, revealAt, span.end) || (a?.ordinal ?? 0) - (b?.ordinal ?? 0) || revealAt.offset - span.end.offset;
      if (order < 0) revealAt = span.end;
    }
    await merge(work, g, decision.entityIds, { evidence: decision.evidence, revealAt });
  }
  for (const other of candidates.slice(1)) await work.set(key("considered", [candidates[0]!.id, other.id].sort()), { complete: true });
}

async function materialize(store: BookAnalysisStore, work: Work, g: StoredAnalysisGeneration) {
  const ordinal = g.cursor.ordinal;
  if (ordinal >= g.admission.chunkCount) { await store.commitFinalization(work.claim, { stage: "index", ordinal: 0 }); return; }
  const output = await extraction(store, g, ordinal);
  const referenced = [...new Set([...output.entities.map(e => e.id), ...output.mentions.map(m => m.entityId), ...output.entries.flatMap(e => e.subjectIds),
    ...output.assertions.flatMap(a => [a.subjectId, ...(a.objectEntityId ? [a.objectEntityId] : [])])])];
  const roots = await readAll(referenced, id => work.root(id));
  const canonical = new Map(referenced.map((id, n) => [id, roots[n]!.identity.canonical]));
  // Derived records are buffered and committed before pages are recorded and again before the
  // cursor advances, preserving the durable order of the per-record writes they replace.
  const batch = new WorkBatch(work);
  const resolve = (id: string) => canonical.get(id) ?? id;
  const mappings: AnalysisEntityMapping[] = [];
  for (const entity of output.entities) {
    const id = resolve(entity.id);
    if (id !== entity.id) {
      const identity = (await batch.read<Identity>(key("identity", entity.id)))!;
      mappings.push({ entityId: entity.id, canonicalEntityId: id, evidence: identity.mapping?.evidence ?? identity.candidate.evidence,
        revealAt: identity.mapping?.revealAt ?? entity.firstIntroduction });
    }
  }
  output.mentions = output.mentions.map(m => ({ ...m, entityId: resolve(m.entityId) }));
  output.entries = output.entries.map(e => ({ ...e, subjectIds: [...new Set(e.subjectIds.map(resolve))] as typeof e.subjectIds }));
  output.assertions = output.assertions.map(a => ({ ...a, subjectId: resolve(a.subjectId), ...(a.objectEntityId ? { objectEntityId: resolve(a.objectEntityId) } : {}) }));
  // Exact provenance deduplication, not value-based last-write-wins. Contradictions survive.
  for (const kind of ["entities", "mentions", "assertions", "entries", "times"] as const) {
    if (kind === "entries") for (const entry of output.entries) {
      for (const field of ["assertionIds", "supersedesAssertionIds"] as const) {
        const ids: string[] = [];
        for (const id of entry[field]) ids.push((await batch.read<{ canonical: string }>(key("record_alias", id)))?.canonical ?? id);
        entry[field] = [...new Set(ids)];
      }
    }
    const kept: typeof output[typeof kind] = [];
    for (const record of output[kind]) {
      const provenance = "span" in record ? [record.span, record.entityId, record.role] :
        "property" in record ? [record.evidence, record.subjectId, record.property, record.value, record.objectEntityId ?? null, record.support,
          record.scope, record.worldCategory, record.retroactiveWorld, record.validFromTimeId, record.validUntilTimeId] :
        "entryKind" in record ? [record.evidence, record.entryKind, record.subjectIds, record.assertionIds, record.supersedesAssertionIds] :
        "kind" in record ? [record.id, record.names] : [record.id];
      const name = key("dedup", [kind, provenance]), existing = await batch.read<{ id: string; jobId: string }>(name);
      if (!existing) { await batch.set(name, { id: record.id, jobId: work.claim.jobId }); (kept as unknown[]).push(record); }
      else if (existing.id === record.id && existing.jobId === work.claim.jobId) (kept as unknown[]).push(record);
      else if (existing.id !== record.id) await batch.set(key("record_alias", record.id), { canonical: existing.id });
    }
    Object.assign(output, { [kind]: kept });
  }
  const pages = (Object.keys(fields) as Array<keyof typeof fields>).map(kind => page(g, kind, ordinal, { [kind]: output[kind] }));
  pages.push(page(g, "entity_mappings", ordinal, { entityMappings: mappings }));
  pages.push(page(g, "time_mappings", ordinal, { timeMappings: [] }));
  const subjectIndexes = output.assertions.map(assertion => ({ subjectId: assertion.subjectId, assertionIds: [assertion.id],
    entryIds: output.entries.filter(e => e.assertionIds.includes(assertion.id)).map(e => e.id),
    supersessions: output.entries.filter(e => e.assertionIds.includes(assertion.id) && e.supersedesAssertionIds.length).map(e => ({ assertionId: assertion.id, supersedesAssertionIds: e.supersedesAssertionIds, entryId: e.id })) }));
  for (const assertion of output.assertions) {
    await batch.set(key("assertion", assertion.id), { assertion });
    await batch.append(key("property", [assertion.subjectId, assertion.property]), assertion.id);
  }
  for (const entry of output.entries) for (const oldId of entry.supersedesAssertionIds) {
    for (const assertionId of entry.assertionIds) {
      const replacement = output.assertions.find(a => a.id === assertionId);
      const previous = (await batch.read<{ assertion: AnalysisAssertion }>(key("assertion", oldId)))?.assertion;
      if (replacement?.validFromTimeId && replacement.support === "asserted" && previous?.subjectId === replacement.subjectId &&
        previous.property === replacement.property) await batch.append(key("ends", oldId), replacement.validFromTimeId);
    }
  }
  for (const entry of output.entries) for (const subjectId of entry.subjectIds) if (!subjectIndexes.some(s => s.subjectId === subjectId && s.entryIds.includes(entry.id))) subjectIndexes.push({ subjectId, assertionIds: [], entryIds: [entry.id], supersessions: [] });
  pages.push(page(g, "subject_indexes", ordinal, { subjectIndexes }));
  const worldBaselines: WorldBaseline[] = [], worldMaps = [];
  for (const assertion of output.assertions) {
    const subject = (await batch.read<Identity>(key("identity", assertion.subjectId)))!.candidate;
    const exposesHiddenSubject = output.entries.some(e => e.assertionIds.includes(assertion.id) && e.informationKinds.some(k => k !== "location"));
    if (!exposesHiddenSubject && (subject.kind === "world" || subject.kind === "location") && assertion.worldCategory && assertion.support === "asserted" &&
      assertion.retroactiveWorld && assertion.validFromTimeId !== null && (assertion.scope === "enduring" || assertion.scope === "interval")) {
      worldBaselines.push({ id: key("baseline", assertion.id), assertionIds: [assertion.id], evidence: assertion.evidence,
        validFromTimeId: assertion.validFromTimeId, validUntilTimeId: assertion.validUntilTimeId });
    }
    if (subject.kind === "location" && assertion.objectEntityId && assertion.support === "asserted" &&
      (await batch.read<Identity>(key("identity", assertion.objectEntityId)))?.candidate.kind === "location") {
      worldMaps.push({ id: key("map", assertion.id), locationEntityIds: [assertion.subjectId, assertion.objectEntityId],
        relationAssertionIds: [assertion.id], evidence: assertion.evidence });
    }
  }
  await batch.set(`baseline_candidates:${ordinal}`, { worldBaselines });
  pages.push(page(g, "world_maps", ordinal, { worldMaps }));
  await batch.commit();
  const descriptors = await recordPages(store, work, g, pages);
  // Store graph edges in their stated direction. No calendar or total narrative order is invented.
  for (const time of output.times) {
    for (const later of time.beforeIds) await batch.append(key("edges", time.id), later);
    for (const earlier of time.afterIds) await batch.append(key("edges", earlier), time.id);
  }
  await batch.commit();
  await store.commitFinalization(work.claim, { stage: "materialize", ordinal: ordinal + 1 }, descriptors);
}

/** Restartable DFS uses disk frames/colors; neither graph nor an unbounded frontier enters memory. */
async function index(store: BookAnalysisStore, work: Work, g: StoredAnalysisGeneration) {
  if (await work.read("graph_complete")) { await indexBaselines(store, work, g); return; }
  const state = await work.read<State>("index_state") ?? { chunk: 0, entity: 0, shard: 0, depth: 0, time: 0 };
  for (let step = 0; step < MAX_STEPS; step++) {
    if (state.depth === 0) {
      if (state.chunk >= g.admission.chunkCount) {
        await work.set("graph_complete", { complete: true });
        await store.commitFinalization(work.claim, { stage: "index", ordinal: g.cursor.ordinal + 1 }); return;
      }
      const output = await extraction(store, g, state.chunk);
      const time = output.times[state.time!];
      if (!time) { state.chunk++; state.time = 0; await work.set("index_state", state); continue; }
      state.time!++;
      const row = await work.read<{ time: AnalysisTime; color: number }>(key("time", time.id));
      if (!row) throw new Error("invalid_time_reference");
      if (row.color === 2) { await work.set("index_state", state); continue; }
      state.depth = 1;
      await work.mutate([{ name: key("time", time.id), data: { time: row.time, color: 1 } },
        { name: "dfs:0", data: { id: time.id, edge: 0 } }, { name: "index_state", data: state }]);
      continue;
    }
    const frame = (await work.read<{ id: string; edge: number }>(`dfs:${state.depth! - 1}`))!;
    const edges = await work.ids(key("edges", frame.id), Math.floor(frame.edge / SHARD));
    const next = edges[frame.edge % SHARD];
    if (!next) {
      const row = (await work.read<{ time: AnalysisTime }>(key("time", frame.id)))!;
      state.depth!--;
      await work.mutate([{ name: key("time", frame.id), data: { time: row.time, color: 2 } }, { name: "index_state", data: state }]);
      continue;
    }
    frame.edge++;
    const row = await work.read<{ time: AnalysisTime; color: number }>(key("time", next));
    if (!row) throw new Error("invalid_time_reference");
    if (row.color === 1) throw new Error("temporal_cycle");
    const changes: { name: string; data: Row }[] = [{ name: `dfs:${state.depth! - 1}`, data: frame }];
    if (row.color !== 2) {
      changes.push({ name: key("time", next), data: { time: row.time, color: 1 } }, { name: `dfs:${state.depth}`, data: { id: next, edge: 0 } });
      state.depth!++;
    }
    changes.push({ name: "index_state", data: state });
    await work.mutate(changes);
  }
  await work.set("index_state", state);
  await store.commitFinalization(work.claim, { stage: "index", ordinal: g.cursor.ordinal + 1 });
}

/** Conflicting/unknown applicability never becomes a hidden baseline. Scan one property shard per cursor. */
async function indexBaselines(store: BookAnalysisStore, work: Work, g: StoredAnalysisGeneration) {
  const state = await work.read<{ chunk: number; candidate: number; shard: number; excluded: boolean }>("baseline_state") ??
    { chunk: 0, candidate: 0, shard: 0, excluded: false };
  if (state.chunk >= g.admission.chunkCount) {
    const descriptors = await recordPages(store, work, g, [], true);
    await store.commitFinalization(work.claim, { stage: "publish", ordinal: 0 }, descriptors); return;
  }
  const source = await work.read<{ worldBaselines: WorldBaseline[] }>(`baseline_candidates:${state.chunk}`);
  if (!source) throw new Error("incomplete_indexes");
  const candidate = source.worldBaselines[state.candidate];
  if (!candidate) {
    const selected = await work.read<{ worldBaselines: WorldBaseline[] }>(`selected_baselines:${state.chunk}`);
    const descriptors = await recordPages(store, work, g, [page(g, "world_baselines", state.chunk, { worldBaselines: selected?.worldBaselines ?? [] })]);
    await work.set("baseline_state", { chunk: state.chunk + 1, candidate: 0, shard: 0, excluded: false });
    await store.commitFinalization(work.claim, { stage: "index", ordinal: g.cursor.ordinal + 1 }, descriptors); return;
  }
  const assertion = (await work.read<{ assertion: AnalysisAssertion }>(key("assertion", candidate.assertionIds[0]!)))?.assertion;
  if (!assertion) throw new Error("incomplete_indexes");
  const ends = await work.read<{ count: number }>(key("ends", assertion.id));
  let endpoint = assertion.validUntilTimeId;
  if (ends?.count === 1) {
    const explicitEnd = (await work.ids(key("ends", assertion.id), 0))[0]!;
    if (endpoint !== null && endpoint !== explicitEnd) state.excluded = true;
    endpoint = explicitEnd;
  }
  if ((ends?.count ?? 0) > 1) state.excluded = true;
  const bucket = key("property", [assertion.subjectId, assertion.property]);
  const head = await work.read<{ count: number }>(bucket);
  for (const otherId of await work.ids(bucket, state.shard)) {
    if (otherId === assertion.id) continue;
    const other = (await work.read<{ assertion: AnalysisAssertion }>(key("assertion", otherId)))?.assertion;
    if (!other) throw new Error("incomplete_indexes");
    if (other.value === assertion.value && other.objectEntityId === assertion.objectEntityId) continue;
    const otherEnds = await work.read<{ count: number }>(key("ends", other.id));
    let otherEndpoint = other.validUntilTimeId;
    if (otherEnds?.count === 1) otherEndpoint = (await work.ids(key("ends", other.id), 0))[0]!;
    // End-exclusive intervals are disjoint when an established end reaches the other's start in the partial order.
    const disjoint = (otherEnds?.count ?? 0) <= 1 &&
      ((endpoint !== null && other.validFromTimeId !== null && await reaches(work, endpoint, other.validFromTimeId)) ||
        (otherEndpoint !== null && assertion.validFromTimeId !== null && await reaches(work, otherEndpoint, assertion.validFromTimeId)));
    if (!disjoint) state.excluded = true;
  }
  state.shard++;
  if (state.shard * SHARD >= (head?.count ?? 0)) {
    if (!state.excluded) await work.update(`selected_baselines:${state.chunk}`, old => {
      const prior = old?.worldBaselines as WorldBaseline[] | undefined ?? [];
      return { worldBaselines: prior.some(b => b.id === candidate.id) ? prior : [...prior, { ...candidate, validUntilTimeId: endpoint }] };
    });
    state.candidate++; state.shard = 0; state.excluded = false;
  }
  await work.set("baseline_state", state);
  await store.commitFinalization(work.claim, { stage: "index", ordinal: g.cursor.ordinal + 1 });
}

export function bookAnalysisWorkerRouter(deps: { db: Firestore; provider: BookAnalysisProvider }): express.Router {
  const router = express.Router(), store = new BookAnalysisStore(deps.db);
  for (const operation of ["extract", "finalize"] as const) router.post(`/${operation}/:jobId`, asyncRoute(async (req, res) => {
    const acquired = await store.claim(routeParam(req, "jobId"));
    if (!acquired) { res.status(204).end(); return; }
    const { claim, job, generation: g } = acquired, work = new Work(store, claim);
    try {
      if (job.operation !== operation) throw new Error("invalid_operation");
      if (job.providerSubmitted) { await store.fail(claim, "provider_incomplete"); res.status(204).end(); return; }
      if (operation === "extract") {
        const chunk = await store.readInput(claim);
        if (!chunk) { await store.releaseMissingInput(claim); res.status(204).end(); return; }
        const input: AnalysisWindowInput = { generationId: g.generationId, model: g.admission.model, chunk,
          ...await candidates(work, g, chunk) };
        validateAnalysisWindowInput(input);
        if (!await store.beginProviderSubmission(claim)) { res.status(204).end(); return; }
        const output = validateAndNormalizeAnalysisWindow(input, await deps.provider.extractAnalysisWindow(input));
        const pages = (Object.keys(fields) as Array<keyof typeof fields>).map(kind => page(g, kind, chunk.ordinal, { [kind]: output[kind] }));
        const descriptors = await store.writeStagingPages(claim, pages, true);
        await indexExtraction(work, input, output);
        await store.commitExtraction(claim, descriptors);
      } else if (g.cursor.stage === "reconcile") await reconcile(store, work, g, deps.provider);
      else if (g.cursor.stage === "materialize") await materialize(store, work, g);
      else if (g.cursor.stage === "index") await index(store, work, g);
      else if (g.cursor.stage === "publish") {
        const catalog = await work.read<{ pages: AnalysisResultPageDescriptor[] }>("result_catalog");
        const descriptors = catalog?.pages ?? [];
        const count = await store.verifyPublicationBatch(claim, descriptors, g.publicationVerifiedCount ?? 0);
        if (count === descriptors.length) await store.publish(claim, descriptors);
        else await store.commitFinalization(claim, { stage: "publish", ordinal: g.cursor.ordinal + 1 });
      } else throw new Error("invalid_stage");
      res.status(204).end();
    } catch (error) {
      if (error instanceof CancelledAnalysisClaim) { res.status(204).end(); return; }
      if (error instanceof HttpError && error.status === 409 && error.message === "Book analysis claim expired.") throw error;
      const category = error instanceof BookAnalysisProviderError ? error.category :
        error instanceof AnalysisValidationError ? "invalid_provider_result" : "analysis_failed";
      // Sanitized diagnostics only: operation, category and a fixed reason/code location; never prose or provider text.
      console.error(JSON.stringify({ component: "book-analysis", operation: "extract_or_finalize", jobId: claim.jobId, category,
        ...(error instanceof BookAnalysisProviderError && error.reason ? { reason: error.reason } : {}) }));
      try { await store.fail(claim, category); }
      catch (failure) { if (!(failure instanceof CancelledAnalysisClaim)) throw failure; }
      res.status(204).end();
    }
  }));
  return router;
}

/** Bounded BFS over validated before-edges; equal nodes count (adjoining end-exclusive intervals). Unknown stays false. */
async function reaches(work: Work, from: string, to: string): Promise<boolean> {
  const seen = new Set<string>(), queue = [from];
  while (queue.length && seen.size < 512) {
    const id = queue.shift()!;
    if (id === to) return true;
    if (seen.has(id)) continue;
    seen.add(id);
    const node = await work.read<{ time: AnalysisTime }>(key("time", id));
    queue.push(...(node?.time.beforeIds ?? []));
  }
  return false;
}
