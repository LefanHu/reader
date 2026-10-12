import type { Firestore } from "firebase-admin/firestore";
import { bookReference } from "./fences.js";
import { ANALYSIS_COLLECTIONS, BookAnalysisStore, type StoredAnalysisGeneration } from "./book-analysis-store.js";
import type {
  AnalysisAssertion, AnalysisEntity, AnalysisEntry, AnalysisMention, AnalysisPosition, AnalysisResultPage,
  AnalysisTime, WorldBaseline,
} from "./book-analysis-types.js";
import type { IllustrationContext, IllustrationContextFact } from "./types.js";

/** Admitted context never exceeds this many UTF-16 units of serialized JSON. */
export const ILLUSTRATION_CONTEXT_MAX_UNITS = 8_000;
const RETROACTIVE_CATEGORIES = new Set(["geography", "architecture", "climate", "ambient_environment", "world_rule"]);

type Order = [number, number];

/**
 * Selects only facts that apply to the scene's story time and were revealed by the scene end
 * (world facts may be retroactive when vetted). Ambiguous or incomparable chronology omits the fact.
 * Reads the latest finalized generation only; never sends or stores the whole book log.
 */
export async function resolveIllustrationContext(db: Firestore, args: {
  uid: string; bookId: string; anchor: AnalysisPosition; sceneStart: AnalysisPosition; sceneEnd: AnalysisPosition;
}): Promise<IllustrationContext | null> {
  const book = (await bookReference(db, "books", args.uid, args.bookId).get()).data();
  const generationId = book?.latestAnalysisGenerationId;
  if (typeof generationId !== "string") return null;
  const generation = (await db.collection(ANALYSIS_COLLECTIONS.records).doc(generationId).get()).data() as StoredAnalysisGeneration | undefined;
  if (!generation || generation.uid !== args.uid || generation.bookId !== args.bookId || generation.status !== "complete" ||
    !generation.finalizedRevision || generation.admission.documentVersion !== args.sceneStart.version) return null;
  const store = new BookAnalysisStore(db);

  // Narrative order comes from admitted descriptors, never from lexical block IDs.
  const order = new Map<string, Order>();
  const chunks = await db.collection(ANALYSIS_COLLECTIONS.records)
    .where("generationId", "==", generationId).where("recordType", "==", "chunk").get();
  for (const doc of chunks.docs) for (const span of (doc.data().descriptor?.primary ?? []) as { sectionOrdinal: number; blockOrdinal: number; sectionId: string; blockId: string }[]) {
    order.set(`${span.sectionId}\u0000${span.blockId}`, [span.sectionOrdinal, span.blockOrdinal]);
  }
  const compare = (a: AnalysisPosition, b: AnalysisPosition): number | null => {
    const x = order.get(`${a.sectionId}\u0000${a.blockId}`), y = order.get(`${b.sectionId}\u0000${b.blockId}`);
    if (!x || !y) return null;
    return x[0] - y[0] || x[1] - y[1] || a.offset - b.offset;
  };
  const atOrBefore = (a: AnalysisPosition, b: AnalysisPosition) => { const c = compare(a, b); return c !== null && c <= 0; };
  const inScene = (p: AnalysisPosition) => atOrBefore(args.sceneStart, p) && atOrBefore(p, args.sceneEnd);

  const pages: AnalysisResultPage[] = [];
  for (const descriptor of generation.resultPages) {
    const page = await store.readStagingPage(generationId, "result", descriptor.pageId);
    if (!page) return null;
    pages.push(page);
  }
  const all = <T>(key: keyof AnalysisResultPage) => pages.flatMap(p => (p[key] as T[] | undefined) ?? []);
  const mapping = new Map(all<{ entityId: string; canonicalEntityId: string }>("entityMappings").map(m => [m.entityId, m.canonicalEntityId]));
  const canonical = (id: string) => mapping.get(id) ?? id;
  const entities = new Map<string, AnalysisEntity>();
  for (const e of all<AnalysisEntity>("entities")) {
    const prior = entities.get(e.id);
    entities.set(e.id, prior ? { ...prior, names: [...prior.names, ...e.names] } : e);
  }
  const assertions = all<AnalysisAssertion>("assertions"), entries = all<AnalysisEntry>("entries");
  const baselineIds = new Set(all<WorldBaseline>("worldBaselines").flatMap(b => b.assertionIds));

  // Later-edges of the partial story-time order; incomparable nodes never reach each other.
  const later = new Map<string, Set<string>>();
  const edge = (from: string, to: string) => { (later.get(from) ?? later.set(from, new Set()).get(from)!).add(to); };
  for (const t of all<AnalysisTime>("times")) {
    for (const b of t.beforeIds) edge(t.id, b);
    for (const a of t.afterIds) edge(a, t.id);
  }
  const reaches = (from: string, to: string) => {
    const seen = new Set<string>(), queue = [from];
    while (queue.length) {
      const id = queue.shift()!;
      if (id === to) return true;
      if (seen.has(id)) continue;
      seen.add(id);
      queue.push(...(later.get(id) ?? []));
    }
    return false;
  };

  // Scene story time comes from supporting entries inside the scene; none means unknown.
  const sceneTimes = [...new Set(entries.filter(e => e.timeId && e.evidence.some(s => inScene(s.start))).map(e => e.timeId!))];

  const mentions = all<AnalysisMention>("mentions").filter(m => inScene(m.span.start));
  const direct = new Set(mentions.map(m => canonical(m.entityId)));
  const subjectIds = new Set(direct);
  const byId = new Map(assertions.map(a => [a.id, a]));
  // Containing/referenced locations of directly mentioned subjects.
  for (const a of assertions) {
    if (a.objectEntityId && direct.has(canonical(a.subjectId)) && entities.get(canonical(a.objectEntityId))?.kind === "location") subjectIds.add(canonical(a.objectEntityId));
    if (a.objectEntityId && direct.has(canonical(a.objectEntityId)) && entities.get(canonical(a.subjectId))?.kind === "location") subjectIds.add(canonical(a.subjectId));
  }
  const supersededBy = new Map<string, string[]>();
  for (const entry of entries) for (const old of entry.supersedesAssertionIds) for (const id of entry.assertionIds) {
    (supersededBy.get(old) ?? supersededBy.set(old, []).get(old)!).push(id);
  }
  const applicable = (a: AnalysisAssertion): boolean => {
    if (!sceneTimes.length || !a.validFromTimeId || a.scope === "unknown") return false;
    if (a.scope === "scene" && !a.evidence.some(s => inScene(s.start))) return false;
    if (a.scope === "interval" && !a.validUntilTimeId) return false;
    return sceneTimes.every(t => {
      if (!reaches(a.validFromTimeId!, t)) return false;
      if (a.validUntilTimeId && (a.validUntilTimeId === t || !reaches(t, a.validUntilTimeId))) return false;
      // An established applicable replacement ends the old fact; unknown replacements do not.
      return !(supersededBy.get(a.id) ?? []).some(id => {
        const next = byId.get(id);
        return next?.support === "asserted" && next.validFromTimeId !== null && reaches(next.validFromTimeId, t);
      });
    });
  };
  const hiddenKinds = new Set(["individual", "group", "item_artifact"]);
  const candidates = assertions.filter(a => {
    const subject = canonical(a.subjectId);
    if (!subjectIds.has(subject) || a.support !== "asserted" || !applicable(a)) return false;
    const kind = entities.get(subject)?.kind;
    const owning = entries.filter(e => e.assertionIds.includes(a.id));
    const retro = a.retroactiveWorld && (kind === "location" || kind === "world") && a.worldCategory !== null &&
      RETROACTIVE_CATEGORIES.has(a.worldCategory) && baselineIds.has(a.id) &&
      !owning.some(e => e.informationKinds.some(k => hiddenKinds.has(k)) || e.subjectIds.some(id => hiddenKinds.has(entities.get(canonical(id))?.kind ?? "")));
    // Character, group, artifact and event facts are reveal-limited to the scene end.
    return retro || atOrBefore(a.revealAt, args.sceneEnd);
  });
  // Unresolved contradictions (same subject/property, different value, neither superseding) are not defaults.
  const conflicted = new Set<string>();
  for (const a of candidates) for (const b of candidates) {
    if (a.id < b.id && a.subjectId === b.subjectId && a.property === b.property &&
      (a.value !== b.value || a.objectEntityId !== b.objectEntityId)) { conflicted.add(a.id); conflicted.add(b.id); }
  }
  const nameOf = (id: string, limit: AnalysisPosition) => (entities.get(canonical(id))?.names ?? [])
    .filter(n => atOrBefore(n.revealAt, limit)).map(n => n.text);
  const rank = (a: AnalysisAssertion) => direct.has(canonical(a.subjectId)) ? 0 : entities.get(canonical(a.subjectId))?.kind === "location" ? 1 : 2;
  const facts: IllustrationContextFact[] = candidates.filter(a => !conflicted.has(a.id))
    .sort((a, b) => rank(a) - rank(b) || (compare(a.evidence[0].start, b.evidence[0].start) ?? 0) || a.id.localeCompare(b.id))
    .map(a => ({ assertionId: a.id, subject: nameOf(a.subjectId, args.sceneEnd)[0] ?? "unnamed", property: a.property, value: a.value,
      ...(a.objectEntityId ? { object: nameOf(a.objectEntityId, args.sceneEnd)[0] ?? "unnamed" } : {}),
      category: a.worldCategory, evidence: a.evidence, revealAt: a.revealAt }));
  const subjects = [...subjectIds].sort().map(id => ({ id, kind: entities.get(id)?.kind ?? "world", names: nameOf(id, args.sceneEnd) }))
    .filter(s => s.names.length > 0);
  const context: IllustrationContext = { schemaVersion: 1, analysisRevision: generation.finalizedRevision, generationId,
    sceneStart: args.sceneStart, sceneEnd: args.sceneEnd, subjects, facts: [] };
  for (const fact of facts) {
    const next = { ...context, facts: [...context.facts, fact] };
    if (JSON.stringify(next).length > ILLUSTRATION_CONTEXT_MAX_UNITS) break;
    context.facts.push(fact);
  }
  while (JSON.stringify(context).length > ILLUSTRATION_CONTEXT_MAX_UNITS && context.subjects.length) context.subjects.pop();
  return context;
}
