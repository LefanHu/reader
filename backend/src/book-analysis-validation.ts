import { ANALYSIS_MODEL, ANALYSIS_PAGE_MAX_BYTES, type AnalysisEvidence, type AnalysisIdentityCandidate, type AnalysisPosition, type AnalysisSpan, type AnalysisTime, type AnalysisWindowInput, type AnalysisWindowOutput, type EntityResolutionBatch, type EntityResolutionOutput } from "./book-analysis-types.js";
import { analysisGraphemeBoundaries, analysisJsonHash, validateAnalysisChunkInput } from "./book-analysis-source.js";

export class AnalysisValidationError extends Error {
  readonly category = "invalid_analysis_result";
  constructor() { super("Invalid book analysis result."); this.name = "AnalysisValidationError"; }
}
function check(value: unknown): asserts value { if (!value) throw new AnalysisValidationError(); }
type Schema = { type?: string | string[]; properties?: Record<string, Schema>; required?: string[]; additionalProperties?: boolean; items?: Schema; enum?: unknown[]; minLength?: number; maxLength?: number; minItems?: number; maxItems?: number; minimum?: number; pattern?: string };
const str = (maxLength = 256): Schema => ({ type: "string", minLength: 1, maxLength });
const id = str(256);
const integer: Schema = { type: "integer", minimum: 0 };
const choice = (...values: unknown[]): Schema => ({ type: values.includes(null) ? ["string", "null"] : "string", enum: values });
const nullableId: Schema = { type: ["string", "null"], minLength: 1, maxLength: 256 };
const array = (items: Schema, minItems = 0, maxItems = 2048): Schema => ({ type: "array", items, minItems, maxItems });
const object = (properties: Record<string, Schema>): Schema => ({ type: "object", properties, required: Object.keys(properties), additionalProperties: false });
const position = object({ version: { ...integer, minimum: 1 }, sectionId: id, blockId: id, offset: integer });
const span = object({ start: position, end: position });
const evidence = array(span, 1, 64);
const kind = choice("individual", "event", "group", "location", "item_artifact", "world");
const name = object({ text: str(), role: choice("name", "alias", "title"), evidence, revealAt: position });
const entity = object({ id, kind, names: array(name, 0, 64), firstIntroduction: position });
const mention = object({ id, entityId: id, span, surface: str(1024), role: choice("name", "alias", "title", "resolved_reference") });
const entry = object({ id, entryKind: choice("introduction", "description", "event", "change", "revelation"), subjectIds: array(id, 1, 64), informationKinds: array(choice("individual", "event", "group", "location", "item_artifact"), 0, 5), summary: str(1024), evidence, revealAt: position, timeId: nullableId, assertionIds: array(id), supersedesAssertionIds: array(id) });
const assertion = object({ id, subjectId: id, property: { ...str(96), pattern: "^[a-z][a-z0-9_.:-]*$" }, value: str(1024), objectEntityId: nullableId, evidence, revealAt: position, validFromTimeId: nullableId, validUntilTimeId: nullableId, scope: choice("enduring", "scene", "interval", "unknown"), support: choice("asserted", "reported", "uncertain"), worldCategory: choice("geography", "architecture", "climate", "ambient_environment", "world_rule", null), retroactiveWorld: { type: "boolean" } });
const time = object({ id, label: { type: ["string", "null"], maxLength: 256 }, beforeIds: array(id), afterIds: array(id), evidence });
/** Nullable wire-only optional fields satisfy Responses strict schemas; persistence omits them. */
export const BOOK_WINDOW_ANALYSIS_SCHEMA = object({ entities: array(entity), mentions: array(mention), entries: array(entry), assertions: array(assertion), times: array(time) });
export const BOOK_ENTITY_RESOLUTION_SCHEMA = object({ decisions: array(object({ entityIds: array(id, 2, 64), sameIdentity: { type: "boolean" }, evidence, revealAt: position }), 0, 128), unresolvedEntityIds: array(id, 0, 64) });

function validateSchema(value: unknown, schema: Schema): void {
  if (schema.enum) { check(schema.enum.includes(value)); return; }
  const types = Array.isArray(schema.type) ? schema.type : [schema.type];
  const type = value === null ? "null" : Array.isArray(value) ? "array" : typeof value;
  check(types.includes(type) || (type === "number" && types.includes("integer") && Number.isSafeInteger(value)));
  if (typeof value === "string") {
    check(value.length >= (schema.minLength ?? 0) && value.length <= (schema.maxLength ?? Infinity) && !/\p{Surrogate}/u.test(value));
    if (schema.pattern) check(new RegExp(schema.pattern).test(value));
  } else if (typeof value === "number") check(Number.isSafeInteger(value) && value >= (schema.minimum ?? 0));
  else if (Array.isArray(value)) {
    check(value.length >= (schema.minItems ?? 0) && value.length <= (schema.maxItems ?? Infinity));
    for (const item of value) validateSchema(item, schema.items!);
  } else if (value !== null && typeof value === "object") {
    const record = value as Record<string, unknown>;
    check(Object.keys(record).every(key => Object.hasOwn(schema.properties!, key)));
    for (const key of schema.required!) check(Object.hasOwn(record, key));
    for (const [key, item] of Object.entries(record)) validateSchema(item, schema.properties![key]!);
  }
}
function bounded(value: unknown): void {
  try { const json = JSON.stringify(value); check(typeof json === "string" && Buffer.byteLength(json, "utf8") <= ANALYSIS_PAGE_MAX_BYTES); }
  catch { throw new AnalysisValidationError(); }
}
function unique(ids: readonly string[]): void { check(new Set(ids).size === ids.length); }
/** Live Responses output must satisfy required nullable fields before local normalization. */
export function validateAnalysisWindowResponse(value: unknown): void {
  bounded(value); validateSchema(value, BOOK_WINDOW_ANALYSIS_SCHEMA);
}
const positionKey = (p: AnalysisPosition) => JSON.stringify([p.version, p.sectionId, p.blockId, p.offset]);
const evidenceSpanKey = (s: AnalysisSpan) => JSON.stringify([s.start.version, s.start.sectionId, s.start.blockId, s.start.offset, s.end.version, s.end.sectionId, s.end.blockId, s.end.offset]);
function positionShape(p: AnalysisPosition): void { validateSchema(p, position); }
function evidenceShape(e: AnalysisEvidence): void {
  validateSchema(e, evidence);
  for (const s of e) check(s.start.version === s.end.version && s.start.sectionId === s.end.sectionId && s.start.blockId === s.end.blockId && s.start.offset < s.end.offset);
}
function candidatesShape(candidates: AnalysisIdentityCandidate[]): void {
  check(Array.isArray(candidates) && candidates.length <= 64);
  unique(candidates.map(c => c.id));
  for (const c of candidates) {
    validateSchema(c.id, id); validateSchema(c.kind, kind); validateSchema(c.names, array(name, 0, 64));
    validateSchema(c.description, { type: "string", maxLength: 2048 }); evidenceShape(c.evidence); positionShape(c.firstIntroduction);
    for (const n of c.names) evidenceShape(n.evidence);
    validateSchema(c.identitySupports ?? [], array(object({ evidence, support: choice("asserted", "reported", "uncertain") }), 0, 64));
    for (const identity of c.identitySupports ?? []) {
      evidenceShape(identity.evidence);
    }
  }
}
/** Applies to injected providers too, before any paid submission. */
export function validateAnalysisWindowInput(input: AnalysisWindowInput): void {
  try {
    check(input.model === ANALYSIS_MODEL && input.promptVersion === 1); validateSchema(input.generationId, id);
    const { primary, overlap, ...rest } = input.chunk;
    validateAnalysisChunkInput(input.chunk, {
      ...rest,
      primary: primary.map(({ text: _text, ...s }) => s),
      overlap: overlap.map(({ text: _text, ...s }) => s),
    });
    candidatesShape(input.candidates);
    check(JSON.stringify({ candidates: input.candidates, knownTimes: input.knownTimes ?? [], knownAssertions: input.knownAssertions ?? [] }).length <= 16_000);
    unique((input.knownTimes ?? []).map(t => t.id)); unique((input.knownAssertions ?? []).map(a => a.id));
    for (const t of input.knownTimes ?? []) { validateSchema({ ...t, label: t.label ?? null }, time); evidenceShape(t.evidence); unique(t.beforeIds); unique(t.afterIds); }
    const candidateIds = new Set(input.candidates.map(c => c.id));
    for (const a of input.knownAssertions ?? []) {
      validateSchema({ ...a, objectEntityId: a.objectEntityId ?? null }, assertion); evidenceShape(a.evidence); check(candidateIds.has(a.subjectId));
    }
  } catch { throw new AnalysisValidationError(); }
}
export function validateEntityResolutionInput(input: EntityResolutionBatch): void {
  try {
    check(input.model === ANALYSIS_MODEL && input.promptVersion === 1 && Number.isSafeInteger(input.ordinal) && input.ordinal >= 0);
    validateSchema(input.generationId, id); candidatesShape(input.candidates);
    check(JSON.stringify({ candidates: input.candidates, acceptedMappings: input.acceptedMappings }).length <= 16_000);
    check(Array.isArray(input.acceptedMappings));
    for (const m of input.acceptedMappings) { validateSchema(m.entityId, id); validateSchema(m.canonicalEntityId, id); evidenceShape(m.evidence); positionShape(m.revealAt); }
  } catch { throw new AnalysisValidationError(); }
}
/** Closed partial-order graph; beforeIds point later and afterIds point earlier. */
export function validateAnalysisTimeGraph(times: readonly AnalysisTime[]): void {
  unique(times.map(t => t.id));
  const edges = new Map(times.map(t => [t.id, new Set<string>()]));
  for (const t of times) {
    unique(t.beforeIds); unique(t.afterIds);
    for (const later of t.beforeIds) { check(edges.has(later) && later !== t.id); edges.get(t.id)!.add(later); }
    for (const earlier of t.afterIds) { check(edges.has(earlier) && earlier !== t.id); edges.get(earlier)!.add(t.id); }
  }
  const indegree = new Map(times.map(t => [t.id, 0]));
  for (const targets of edges.values()) for (const target of targets) indegree.set(target, indegree.get(target)! + 1);
  const queue = [...indegree].filter(([, n]) => n === 0).map(([id]) => id);
  let count = 0;
  for (let i = 0; i < queue.length; i++) { count++; for (const target of edges.get(queue[i]!)!) { const n = indegree.get(target)! - 1; indegree.set(target, n); if (n === 0) queue.push(target); } }
  check(count === times.length);
}

export function validateAndNormalizeAnalysisWindow(input: AnalysisWindowInput, value: unknown): AnalysisWindowOutput {
  validateAnalysisWindowInput(input); bounded(value);
  // Optional TS fields may be absent in injected providers; strict live schema uses null.
  const raw = value as AnalysisWindowOutput;
  check(raw && typeof raw === "object" && Array.isArray(raw.assertions) && Array.isArray(raw.times));
  check(raw.assertions.every(a => a !== null && typeof a === "object") && raw.times.every(t => t !== null && typeof t === "object"));
  const wire = { ...raw, assertions: raw.assertions.map(a => ({ ...a, objectEntityId: a.objectEntityId ?? null })), times: raw.times.map(t => ({ ...t, label: t.label ?? null })) };
  validateSchema(wire, BOOK_WINDOW_ANALYSIS_SCHEMA);
  const output = structuredClone(wire) as unknown as AnalysisWindowOutput;
  const sources = [...input.chunk.primary, ...input.chunk.overlap];
  const boundaryCache = new Map<typeof sources[number], Set<number>>();
  const locate = (s: AnalysisSpan, primaryOnly = false) => {
    validateSchema(s, span);
    const source = (primaryOnly ? input.chunk.primary : sources).find(source => s.start.version === source.version && s.end.version === source.version && s.start.sectionId === source.sectionId && s.end.sectionId === source.sectionId && s.start.blockId === source.blockId && s.end.blockId === source.blockId && s.start.offset >= source.startOffset && s.end.offset <= source.endOffset && s.start.offset < s.end.offset);
    check(source);
    let boundaries = boundaryCache.get(source);
    if (!boundaries) { boundaries = analysisGraphemeBoundaries(source.text); boundaryCache.set(source, boundaries); }
    check(boundaries.has(s.start.offset - source.startOffset) && boundaries.has(s.end.offset - source.startOffset));
    return source;
  };
  const compare = (a: AnalysisPosition, b: AnalysisPosition) => {
    const source = (p: AnalysisPosition) => sources.find(s => s.version === p.version && s.sectionId === p.sectionId && s.blockId === p.blockId)!;
    const aa = source(a), bb = source(b); check(aa && bb);
    return aa.sectionOrdinal - bb.sectionOrdinal || aa.blockOrdinal - bb.blockOrdinal || a.offset - b.offset;
  };
  const validateEvidence = (e: AnalysisEvidence) => {
    evidenceShape(e); e.forEach(s => locate(s)); check(e.some(s => { try { locate(s, true); return true; } catch { return false; } }));
    return [...e].sort((a, b) => compare(a.start, b.start));
  };
  const reveal = (e: AnalysisEvidence) => { validateEvidence(e); return structuredClone(e.map(s => s.end).sort(compare).at(-1)!); };
  const entityIds = new Set([...input.candidates.map(c => c.id), ...output.entities.map(e => e.id)]);
  const timeIds = new Set([...(input.knownTimes ?? []).map(t => t.id), ...output.times.map(t => t.id)]);
  const assertionIds = new Set([...output.assertions.map(a => a.id), ...(input.knownAssertions ?? []).map(a => a.id)]);
  const all = [...output.entities, ...output.mentions, ...output.entries, ...output.assertions, ...output.times];
  unique(all.map(record => record.id));
  const existingIds = new Set([...input.candidates.map(c => c.id), ...(input.knownTimes ?? []).map(t => t.id), ...(input.knownAssertions ?? []).map(a => a.id)]);
  const reusedEntityIds = new Set(output.entities.filter(e => input.candidates.some(c => c.id === e.id && c.kind === e.kind)).map(e => e.id));
  check(all.every(record => !existingIds.has(record.id) || (output.entities.some(e => e === record) && reusedEntityIds.has(record.id))));
  const requireEntity = (id: string) => check(entityIds.has(id));
  const requireTime = (id: string | null) => check(id === null || timeIds.has(id));
  for (const m of output.mentions) {
    requireEntity(m.entityId); const source = locate(m.span, true);
    check(source.text.slice(m.span.start.offset - source.startOffset, m.span.end.offset - source.startOffset) === m.surface);
  }
  for (const e of output.entities) {
    const supporting: AnalysisSpan[] = [];
    for (const n of e.names) {
      n.revealAt = reveal(n.evidence);
      check(n.evidence.some(s => { const source = locate(s); return source.text.slice(s.start.offset - source.startOffset, s.end.offset - source.startOffset) === n.text; }));
      supporting.push(...n.evidence);
    }
    supporting.push(...output.mentions.filter(m => m.entityId === e.id).map(m => m.span));
    const primary = supporting.filter(s => { try { locate(s, true); return true; } catch { return false; } });
    // A subject may appear unnamed before its first disclosed name.
    for (const a of output.assertions.filter(a => a.subjectId === e.id)) primary.push(...validateEvidence(a.evidence).filter(s => { try { locate(s, true); return true; } catch { return false; } }));
    for (const entry of output.entries.filter(entry => entry.subjectIds.includes(e.id))) primary.push(...validateEvidence(entry.evidence).filter(s => { try { locate(s, true); return true; } catch { return false; } }));
    check(primary.length);
    const existing = input.candidates.find(c => c.id === e.id);
    e.firstIntroduction = structuredClone(existing?.firstIntroduction ?? primary.sort((a, b) => compare(a.start, b.start))[0]!.start);
  }
  for (const a of output.assertions) {
    requireEntity(a.subjectId); if (a.objectEntityId != null) requireEntity(a.objectEntityId); else delete a.objectEntityId;
    requireTime(a.validFromTimeId); requireTime(a.validUntilTimeId); a.revealAt = reveal(a.evidence);
    const subject = output.entities.find(e => e.id === a.subjectId) ?? input.candidates.find(c => c.id === a.subjectId)!;
    if (a.retroactiveWorld) {
      const object = a.objectEntityId ? output.entities.find(e => e.id === a.objectEntityId) ?? input.candidates.find(c => c.id === a.objectEntityId) : null;
      check(a.support === "asserted" && (subject.kind === "world" || subject.kind === "location") && a.worldCategory !== null && (!object || object.kind === "world" || object.kind === "location"));
    }
    if (a.worldCategory !== null) check(subject.kind === "world" || subject.kind === "location");
  }
  for (const e of output.entries) {
    unique(e.subjectIds); e.subjectIds.forEach(requireEntity); unique(e.informationKinds); requireTime(e.timeId);
    unique(e.assertionIds); unique(e.supersedesAssertionIds);
    for (const id of e.assertionIds) { const a = output.assertions.find(a => a.id === id); check(a && e.subjectIds.includes(a.subjectId)); }
    for (const id of e.supersedesAssertionIds) {
      const prior = output.assertions.find(a => a.id === id) ?? (input.knownAssertions ?? []).find(a => a.id === id);
      check(assertionIds.has(id) && !e.assertionIds.includes(id) && prior && e.subjectIds.includes(prior.subjectId));
    }
    check(e.supersedesAssertionIds.length === 0 || e.entryKind === "change");
    e.revealAt = reveal(e.evidence);
  }
  for (const t of output.times) { validateEvidence(t.evidence); if (t.label == null) delete t.label; }
  // Known nodes can reference older, omitted context; only new edges must be closed in this bounded graph.
  const known = (input.knownTimes ?? []).map(t => ({ ...t, beforeIds: t.beforeIds.filter(id => timeIds.has(id)), afterIds: t.afterIds.filter(id => timeIds.has(id)) }));
  validateAnalysisTimeGraph([...known, ...output.times]);
  const mappings = new Map<string, string>();
  const stable = (local: string, recordKind: string, anchor: AnalysisPosition) => `ba_${analysisJsonHash([input.generationId, anchor.version, anchor.sectionId, anchor.blockId, anchor.offset, recordKind, local])}`;
  const primaryAnchor = (e: AnalysisEvidence) => validateEvidence(e).find(s => { try { locate(s, true); return true; } catch { return false; } })!.start;
  for (const e of output.entities) mappings.set(e.id, reusedEntityIds.has(e.id) ? e.id : stable(e.id, e.kind, e.firstIntroduction));
  for (const m of output.mentions) mappings.set(m.id, stable(m.id, "mention", m.span.start));
  for (const e of output.entries) mappings.set(e.id, stable(e.id, e.entryKind, primaryAnchor(e.evidence)));
  for (const a of output.assertions) mappings.set(a.id, stable(a.id, "assertion", primaryAnchor(a.evidence)));
  for (const t of output.times) mappings.set(t.id, stable(t.id, "time", primaryAnchor(t.evidence)));
  const mapped = (id: string) => mappings.get(id) ?? id;
  const mappedTime = (id: string | null) => id === null ? null : mapped(id);
  for (const e of output.entities) e.id = mapped(e.id);
  for (const m of output.mentions) { m.id = mapped(m.id); m.entityId = mapped(m.entityId); }
  for (const a of output.assertions) { a.id = mapped(a.id); a.subjectId = mapped(a.subjectId); if (a.objectEntityId) a.objectEntityId = mapped(a.objectEntityId); a.validFromTimeId = mappedTime(a.validFromTimeId); a.validUntilTimeId = mappedTime(a.validUntilTimeId); }
  for (const e of output.entries) { e.id = mapped(e.id); e.subjectIds = e.subjectIds.map(mapped) as typeof e.subjectIds; e.assertionIds = e.assertionIds.map(mapped); e.supersedesAssertionIds = e.supersedesAssertionIds.map(mapped); e.timeId = mappedTime(e.timeId); }
  for (const t of output.times) { t.id = mapped(t.id); t.beforeIds = t.beforeIds.map(mapped); t.afterIds = t.afterIds.map(mapped); }
  bounded(output); return output;
}

export function validateEntityResolution(input: EntityResolutionBatch, value: unknown): EntityResolutionOutput {
  validateEntityResolutionInput(input); bounded(value); validateSchema(value, BOOK_ENTITY_RESOLUTION_SCHEMA);
  const result = structuredClone(value) as EntityResolutionOutput;
  const candidates = new Map(input.candidates.map(c => [c.id, c]));
  unique(result.unresolvedEntityIds); result.unresolvedEntityIds.forEach(id => check(candidates.has(id)));
  const covered = new Set(result.unresolvedEntityIds), decisions = new Set<string>();
  const roots = new Map(input.candidates.map(c => [c.id, c.id]));
  const root = (id: string): string => {
    let current = id;
    while (roots.get(current) !== current) current = roots.get(current)!;
    return current;
  };
  for (const mapping of input.acceptedMappings) {
    const source = candidates.get(mapping.entityId), canonical = candidates.get(mapping.canonicalEntityId);
    if (source && canonical) { check(source.kind === canonical.kind); roots.set(root(source.id), root(canonical.id)); }
  }
  for (const d of result.decisions) {
    unique(d.entityIds); d.entityIds.forEach(id => { check(candidates.has(id)); covered.add(id); });
    const decisionKey = JSON.stringify([...d.entityIds].sort()); check(!decisions.has(decisionKey)); decisions.add(decisionKey);
    const members = d.entityIds.map(id => candidates.get(id)!);
    check(!d.sameIdentity || members.every(c => c.kind === members[0]!.kind));
    const priorMappings = input.acceptedMappings.filter(m => d.entityIds.includes(m.entityId) && d.entityIds.includes(m.canonicalEntityId));
    const supplied = [...members.flatMap(c => [...c.evidence, ...c.names.flatMap(n => n.evidence), ...(c.identitySupports ?? []).flatMap(s => s.evidence)]), ...priorMappings.flatMap(m => m.evidence)];
    evidenceShape(d.evidence); check(d.evidence.every(s => supplied.some(allowed => evidenceSpanKey(allowed) === evidenceSpanKey(s))));
    if (d.sameIdentity) {
      const nameSpans = new Set(members.flatMap(c => c.names.flatMap(n => n.evidence)).map(evidenceSpanKey));
      check(d.evidence.some(s => !nameSpans.has(evidenceSpanKey(s)))); // Shared names are retrieval, never merge proof.
      const identitySupports = members.flatMap(c => c.identitySupports ?? []);
      const selected = new Set(d.evidence.map(evidenceSpanKey));
      check(!identitySupports.some(s => s.support !== "asserted" && s.evidence.some(e => selected.has(evidenceSpanKey(e)))));
      const selectedAll = (evidence: readonly Parameters<typeof evidenceSpanKey>[0][]) => evidence.every(e => selected.has(evidenceSpanKey(e)));
      // Every merged identity needs its own selected asserted support or accepted mapping endpoint.
      check(members.every(c =>
        (c.identitySupports ?? []).some(s => s.support === "asserted" && selectedAll(s.evidence)) ||
        priorMappings.some(m => (m.entityId === c.id || m.canonicalEntityId === c.id) && selectedAll(m.evidence))));
      d.entityIds.forEach(id => check(!result.unresolvedEntityIds.includes(id)));
      const canonical = root(d.entityIds[0]);
      for (const id of d.entityIds.slice(1)) roots.set(root(id), canonical);
    }
    // Derive from an actual evidence endpoint, never a subject's earlier introduction.
    // Cross-block order is not encoded by these IDs; retain the selected supported endpoint.
    check(d.evidence.some(s => positionKey(s.end) === positionKey(d.revealAt)));
    const first = d.evidence[0]!.end;
    if (d.evidence.every(s => s.end.version === first.version && s.end.sectionId === first.sectionId && s.end.blockId === first.blockId)) {
      d.revealAt = structuredClone(d.evidence.reduce((latest, s) => s.end.offset > latest.offset ? s.end : latest, first));
    } else d.revealAt = structuredClone(d.evidence.find(s => positionKey(s.end) === positionKey(d.revealAt))!.end);
  }
  check(covered.size === candidates.size);
  for (const d of result.decisions.filter(d => !d.sameIdentity)) {
    unique(d.entityIds.map(root));
  }
  return result;
}
