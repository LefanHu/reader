/** Immutable analysis identity; independent of image profiles, styles and credits. */
export const ANALYSIS_MODEL = "gpt-6-luna";
export const ANALYSIS_OVERLAP_MAX_UNITS = 1_000;
export const ANALYSIS_INPUT_MAX_UNITS = 8_000;
export const ANALYSIS_PAGE_MAX_BYTES = 128 * 1024;
export const ANALYSIS_DESCRIPTOR_PAGE_MAX_CHUNKS = 100;
/** Reserved assertion property for explicit same-identity/alias relations (objectEntityId is the other identity). */
export const ANALYSIS_IDENTITY_PROPERTY = "same_identity";

/** Exact normalized document position, with an end-exclusive UTF-16 grapheme offset. */
export type AnalysisPosition = { sectionId: string; blockId: string; offset: number };
/** Evidence is nonempty and block-local; cross-block support uses multiple spans. */
export type AnalysisSpan = { start: AnalysisPosition; end: AnalysisPosition };
export type AnalysisEvidence = [AnalysisSpan, ...AnalysisSpan[]];
export type EntityKind = "individual" | "event" | "group" | "location" | "item_artifact" | "world";
export type InformationKind = Exclude<EntityKind, "world">;
export type AnalysisMentionRole = "name" | "alias" | "title" | "resolved_reference";
/** Labels carry their own disclosure anchor, never a retroactively visible canonical name. */
export type AnalysisName = {
  text: string; role: Exclude<AnalysisMentionRole, "resolved_reference">;
  evidence: AnalysisEvidence; revealAt: AnalysisPosition;
};
/** Provider-local IDs become generation-stable IDs before persistence. */
export type AnalysisEntity = {
  id: string; kind: EntityKind; names: AnalysisName[]; firstIntroduction: AnalysisPosition;
};
/** Surface must equal the exact source substring; ambiguous references remain unattached. */
export type AnalysisMention = {
  id: string; entityId: string; span: AnalysisSpan; surface: string; role: AnalysisMentionRole;
};
/** Narrative disclosure and story applicability are deliberately separate. */
export type AnalysisEntry = {
  id: string; entryKind: "introduction" | "description" | "event" | "change" | "revelation";
  subjectIds: [string, ...string[]]; informationKinds: InformationKind[]; summary: string;
  evidence: AnalysisEvidence; revealAt: AnalysisPosition; timeId: string | null;
  assertionIds: string[]; supersedesAssertionIds: string[];
};
/** Null temporal endpoints mean unknown, never the start/end of the book. */
export type AnalysisAssertion = {
  id: string; subjectId: string; property: string; value: string; objectEntityId?: string;
  evidence: AnalysisEvidence; revealAt: AnalysisPosition;
  validFromTimeId: string | null; validUntilTimeId: string | null;
  scope: "enduring" | "scene" | "interval" | "unknown";
  support: "asserted" | "reported" | "uncertain";
  worldCategory: "geography" | "architecture" | "climate" | "ambient_environment" | "world_rule" | null;
  retroactiveWorld: boolean;
};
/** A partial-order node: beforeIds are later nodes, afterIds are earlier nodes. Reject cycles. */
export type AnalysisTime = {
  id: string; label?: string; beforeIds: string[]; afterIds: string[]; evidence: AnalysisEvidence;
};
/** Selected supported facts, not generated lore or a book-global latest-state snapshot. */
export type WorldBaseline = {
  id: string; assertionIds: string[]; evidence: AnalysisEvidence;
  validFromTimeId: string | null; validUntilTimeId: string | null;
};
/** Textual, evidence-backed location relations; no inferred coordinates. */
export type WorldMap = {
  id: string; locationEntityIds: string[]; relationAssertionIds: string[]; evidence: AnalysisEvidence;
};

/** Empty blocks use startOffset=endOffset=blockLength=0 only for primary coverage. */
export type AnalysisSpanDescriptor = {
  sectionOrdinal: number; sectionId: string; blockOrdinal: number;
  blockId: string; startOffset: number; endOffset: number; blockLength: number; hash: string;
};
/** Transport text is already normalized; never trim or normalize it again. */
export type AnalysisSourceSpan = AnalysisSpanDescriptor & { text: string };
/** Hashes use compact primitive JSON arrays, not object-key canonicalization. */
export type AnalysisChunkDescriptor = {
  ordinal: number; hash: string; primary: AnalysisSpanDescriptor[];
  overlap: AnalysisSpanDescriptor[]; overlapHash: string;
};
export type AnalysisChunkInput = {
  ordinal: number; hash: string; primary: AnalysisSourceSpan[];
  overlap: AnalysisSourceSpan[]; overlapHash: string;
};
/** Section order is immutable, including sections with no blocks. */
export type AnalysisSectionDescriptor = { ordinal: number; id: string; blockCount: number };
/** Admission is prose-free and omits chunks; descriptor pages supply them separately. */
export type AnalysisGenerationAdmission = {
  model: "gpt-6-luna";
  documentDigest: string; sectionCount: number; blockCount: number;
  chunkCount: number; pageCount: number; sections: AnalysisSectionDescriptor[];
};
export type AnalysisSourceManifest = AnalysisGenerationAdmission & { chunks: AnalysisChunkDescriptor[] };
export type AnalysisDescriptorPage = { chunks: AnalysisChunkDescriptor[] };
export type AnalysisGenerationStatus = "manifest" | "extracting" | "finalizing" | "complete" | "failed";
export type AnalysisStage = "manifest" | "extract" | "reconcile" | "materialize" | "index" | "publish";
/** Authenticated API owns dispatch; the cursor admits one bounded worker operation. */
export type AnalysisOperationCursor = { stage: AnalysisStage; ordinal: number };
export type AnalysisFailure = { category: string };
export type AnalysisResultPageKind = "entities" | "mentions" | "entries" | "assertions" | "times" |
  "entity_mappings" | "time_mappings" | "world_baselines" | "world_maps" | "subject_indexes";
/** SHA-256 checksum of serialized immutable page bytes, checked before pointer publication. */
export type AnalysisResultPageDescriptor = {
  pageId: string; kind: AnalysisResultPageKind; ordinal: number; checksum: string; byteLength: number;
};
/** Alias mapping avoids rewriting immutable extraction shards. */
export type AnalysisEntityMapping = {
  entityId: string; canonicalEntityId: string; evidence: AnalysisEvidence; revealAt: AnalysisPosition;
};
export type AnalysisTimeMapping = { timeId: string; canonicalTimeId: string; evidence: AnalysisEvidence };
/** Supersession provenance remains explicit; contradictory facts are not last-write-wins. */
export type AnalysisSubjectIndex = {
  subjectId: string; assertionIds: string[]; entryIds: string[];
  supersessions: { assertionId: string; supersedesAssertionIds: string[]; entryId: string }[];
};
/** Pages contain only derived records and references, never raw chapter prose. */
export type AnalysisResultPage = {
  generationId: string; pageId: string; kind: AnalysisResultPageKind; ordinal: number;
  entities?: AnalysisEntity[]; mentions?: AnalysisMention[]; entries?: AnalysisEntry[];
  assertions?: AnalysisAssertion[]; times?: AnalysisTime[]; entityMappings?: AnalysisEntityMapping[];
  timeMappings?: AnalysisTimeMapping[]; worldBaselines?: WorldBaseline[]; worldMaps?: WorldMap[];
  subjectIndexes?: AnalysisSubjectIndex[];
};
/** `GET /api/book-analysis/config` body; public DTOs expose accountKey instead of uid. */
export type AnalysisConfiguration = {
  enabled: boolean; model: "gpt-6-luna"; accountKey: string;
};
/** `POST /api/book-analysis/books` body. */
export type AnalysisRegistration = { bookId: string; accountKey: string };
export type AnalysisReceipt = {
  generationId: string; jobId?: string; status: AnalysisGenerationStatus; cursor?: AnalysisOperationCursor;
};
/** Read-only status does not register books, submit work, or initialize image credits. */
export type AnalysisProgress = {
  generationId: string; bookId: string; accountKey: string; documentDigest: string;
  status: AnalysisGenerationStatus; stage: AnalysisStage; processedChunks: number; requiredChunks: number;
  processedUnits: number; requiredUnits: number; nextCursor: AnalysisOperationCursor | null;
  error: AnalysisFailure | null; finalizedRevision: string | null; resultPages: AnalysisResultPageDescriptor[];
};
/** Bounded known-identity summaries are retrieval candidates, never proof of identity. */
export type AnalysisIdentityCandidate = {
  id: string; kind: EntityKind; names: AnalysisName[]; description: string;
  evidence: AnalysisEvidence; firstIntroduction: AnalysisPosition;
  /** Provider context only: explicit identity evidence retains its extraction support level. */
  identitySupports?: { evidence: AnalysisEvidence; support: AnalysisAssertion["support"] }[];
};
/** Only primary source may emit new records; overlap supplies preceding context. */
export type AnalysisWindowInput = {
  generationId: string; model: "gpt-6-luna";
  chunk: AnalysisChunkInput; candidates: AnalysisIdentityCandidate[];
  knownTimes?: AnalysisTime[];
  knownAssertions?: AnalysisAssertion[];
};
/** IDs in this response are provider-local and all references must validate before commit. */
export type AnalysisWindowOutput = {
  entities: AnalysisEntity[]; mentions: AnalysisMention[]; entries: AnalysisEntry[];
  assertions: AnalysisAssertion[]; times: AnalysisTime[];
};
/** At most 64 identities and 16,000 UTF-16 context units per paid resolution call. */
export type EntityResolutionBatch = {
  generationId: string; model: "gpt-6-luna"; ordinal: number;
  candidates: AnalysisIdentityCandidate[]; acceptedMappings: AnalysisEntityMapping[];
};
/** Unsupported/uncertain candidates stay unresolved; name equality alone cannot merge. */
export type EntityResolutionOutput = {
  decisions: { entityIds: [string, string, ...string[]]; sameIdentity: boolean;
    evidence: AnalysisEvidence; revealAt: AnalysisPosition }[];
  unresolvedEntityIds: string[];
};
export type BookAnalysisProvider = {
  extractAnalysisWindow(input: AnalysisWindowInput): Promise<AnalysisWindowOutput>;
  resolveAnalysisEntities(input: EntityResolutionBatch): Promise<EntityResolutionOutput>;
};
