import { createHash } from "node:crypto";
import {
  ANALYSIS_DESCRIPTOR_PAGE_MAX_CHUNKS, ANALYSIS_INPUT_MAX_UNITS, ANALYSIS_MODEL,
  ANALYSIS_OVERLAP_MAX_UNITS, ANALYSIS_PAGE_MAX_BYTES,
  type AnalysisChunkDescriptor, type AnalysisChunkInput, type AnalysisDescriptorPage,
  type AnalysisGenerationAdmission, type AnalysisSourceManifest, type AnalysisSourceSpan,
  type AnalysisSpan, type AnalysisSpanDescriptor,
} from "./book-analysis-types.js";

const spanFields: readonly (keyof AnalysisSpanDescriptor)[] = [
  "version", "sectionOrdinal", "sectionId", "blockOrdinal", "blockId",
  "startOffset", "endOffset", "blockLength", "hash",
];
const chunkFields = ["ordinal", "hash", "primary", "overlap", "overlapHash"];
const admissionFields = [
  "schemaVersion", "analysisVersion", "promptVersion", "model", "documentVersion", "documentDigest",
  "sectionCount", "blockCount", "chunkCount", "pageCount", "sections",
];
const sectionFields = ["ordinal", "id", "blockCount"];

/** Sanitized validation error: never includes source text, identifiers or submitted JSON. */
export class AnalysisSourceValidationError extends Error {
  constructor() { super("Invalid book analysis source."); this.name = "AnalysisSourceValidationError"; }
}
function check(condition: unknown): asserts condition {
  if (!condition) throw new AnalysisSourceValidationError();
}
function record(value: unknown): Record<string, unknown> {
  check(value !== null && typeof value === "object" && !Array.isArray(value));
  return value as Record<string, unknown>;
}
function integer(value: unknown, minimum = 0): asserts value is number {
  check(typeof value === "number" && Number.isSafeInteger(value) && value >= minimum);
}
function identifier(value: unknown): asserts value is string {
  check(typeof value === "string" && value.length > 0);
}
function digest(value: unknown): asserts value is string {
  check(typeof value === "string" && /^[a-f0-9]{64}$/.test(value));
}
/** All hash inputs are compact JSON primitive arrays, shared verbatim with Dart jsonEncode. */
export function analysisJsonHash(value: unknown): string {
  return createHash("sha256").update(JSON.stringify(value), "utf8").digest("hex");
}
export function analysisSpanHash(span: AnalysisSourceSpan): string {
  return analysisJsonHash([span.version, span.sectionOrdinal, span.sectionId, span.blockOrdinal,
    span.blockId, span.startOffset, span.endOffset, span.text]);
}
export function analysisChunkHash(primary: readonly AnalysisSpanDescriptor[]): string {
  return analysisJsonHash(primary.map((span) => span.hash));
}
export function analysisOverlapHash(overlap: readonly AnalysisSpanDescriptor[]): string {
  return analysisJsonHash(overlap.map((span) => span.hash));
}
export function analysisDocumentDigest(chunks: readonly AnalysisChunkDescriptor[]): string {
  return analysisJsonHash(chunks.map((chunk) => [chunk.ordinal, chunk.hash]));
}
/** UTF-8 serialized bytes, not UTF-16 string length; oversized pages are rejected, not truncated. */
export function validateAnalysisPageSize(value: unknown): number {
  let json: string | undefined;
  try { json = JSON.stringify(value); } catch { throw new AnalysisSourceValidationError(); }
  check(json !== undefined);
  const bytes = Buffer.byteLength(json, "utf8");
  check(bytes <= ANALYSIS_PAGE_MAX_BYTES);
  return bytes;
}
function spanDescriptor(value: unknown): asserts value is AnalysisSpanDescriptor {
  const span = record(value);
  integer(span.version, 1); integer(span.sectionOrdinal); integer(span.blockOrdinal);
  identifier(span.sectionId); identifier(span.blockId);
  integer(span.startOffset); integer(span.endOffset); integer(span.blockLength); digest(span.hash);
  check(span.startOffset <= span.endOffset && span.endOffset <= span.blockLength);
  check(span.startOffset < span.endOffset || (span.startOffset === 0 && span.blockLength === 0));
  check(Object.keys(span).every((key) => (spanFields as readonly string[]).includes(key)));
}
function chunkDescriptor(value: unknown): asserts value is AnalysisChunkDescriptor {
  const chunk = record(value);
  check(Object.keys(chunk).every((key) => chunkFields.includes(key)));
  integer(chunk.ordinal); digest(chunk.hash); digest(chunk.overlapHash);
  check(Array.isArray(chunk.primary) && chunk.primary.length > 0 && Array.isArray(chunk.overlap));
  chunk.primary.forEach(spanDescriptor); chunk.overlap.forEach(spanDescriptor);
  const typed = chunk as AnalysisChunkDescriptor;
  check(typed.hash === analysisChunkHash(typed.primary));
  check(typed.overlapHash === analysisOverlapHash(typed.overlap));
  const overlapUnits = typed.overlap.reduce((n, s) => n + s.endOffset - s.startOffset, 0);
  const primaryUnits = typed.primary.reduce((n, s) => n + s.endOffset - s.startOffset, 0);
  check(overlapUnits <= ANALYSIS_OVERLAP_MAX_UNITS);
  check(primaryUnits + overlapUnits <= ANALYSIS_INPUT_MAX_UNITS);
  check(typed.overlap.every((s) => s.endOffset > s.startOffset));
}
/** Independent upload-page validation; whole-manifest validation must follow all pages. */
export function validateAnalysisDescriptorPage(value: unknown): asserts value is AnalysisDescriptorPage {
  validateAnalysisPageSize(value);
  const page = record(value);
  check(Object.keys(page).every((key) => key === "chunks"));
  check(Array.isArray(page.chunks) && page.chunks.length > 0 &&
    page.chunks.length <= ANALYSIS_DESCRIPTOR_PAGE_MAX_CHUNKS);
  page.chunks.forEach(chunkDescriptor);
  for (let i = 1; i < page.chunks.length; i++) {
    check((page.chunks[i] as AnalysisChunkDescriptor).ordinal ===
      (page.chunks[i - 1] as AnalysisChunkDescriptor).ordinal + 1);
  }
}
/** Validates immutable versions/counts before any prose or provider work is admitted. */
export function validateAnalysisAdmission(value: unknown): asserts value is AnalysisGenerationAdmission {
  validateAnalysisPageSize(value);
  const admission = record(value);
  check(Object.keys(admission).every((key) => admissionFields.includes(key)));
  check(admission.schemaVersion === 1 && admission.analysisVersion === 1 && admission.promptVersion === 1 &&
    admission.model === ANALYSIS_MODEL);
  integer(admission.documentVersion, 1); digest(admission.documentDigest);
  integer(admission.sectionCount); integer(admission.blockCount); integer(admission.chunkCount);
  integer(admission.pageCount);
  // Absolute bounds keep a tiny header from fanning out reads: 200 pages cover ~20,000 windows.
  check((admission.pageCount as number) <= 200 && (admission.chunkCount as number) <= 20_000);
  check(Array.isArray(admission.sections) && admission.sections.length === admission.sectionCount);
  const ids = new Set<string>();
  let blocks = 0;
  admission.sections.forEach((value, ordinal) => {
    const section = record(value);
    check(Object.keys(section).every((key) => sectionFields.includes(key)));
    check(section.ordinal === ordinal); identifier(section.id); integer(section.blockCount);
    check(!ids.has(section.id)); ids.add(section.id); blocks += section.blockCount;
  });
  check(Number.isSafeInteger(blocks) && blocks === admission.blockCount);
  check(admission.chunkCount === 0 ? blocks === 0 && admission.pageCount === 0 :
    blocks > 0 && admission.pageCount > 0 && admission.pageCount <= admission.chunkCount &&
    admission.chunkCount <= admission.pageCount * ANALYSIS_DESCRIPTOR_PAGE_MAX_CHUNKS);
}
function sameBlock(a: AnalysisSpanDescriptor, b: AnalysisSpanDescriptor): boolean {
  return a.version === b.version && a.sectionOrdinal === b.sectionOrdinal && a.sectionId === b.sectionId &&
    a.blockOrdinal === b.blockOrdinal && a.blockId === b.blockId && a.blockLength === b.blockLength;
}
/** Checks ordered exact-once primary coverage, including empty blocks and empty sections.
 * Descriptor hashes authenticate submitted text later; descriptors alone cannot prove grapheme boundaries.
 */
export function validateAnalysisSourceManifest(value: unknown): asserts value is AnalysisSourceManifest {
  const raw = record(value);
  // The aggregate is not a Firestore document: each descriptor page is bounded separately.
  const { chunks, ...header } = raw;
  validateAnalysisAdmission(header);
  check(Array.isArray(chunks) && chunks.length === header.chunkCount);
  const manifest = raw as AnalysisSourceManifest;
  let sectionOrdinal = 0, blockOrdinal = 0, offset = 0;
  let active: AnalysisSpanDescriptor | undefined;
  const seenIds = new Set<string>();
  const coveredBlocks: AnalysisSpanDescriptor[] = [];
  const coveredById = new Map<string, number>();
  const advanceEmptySections = () => {
    while (sectionOrdinal < manifest.sections.length &&
      blockOrdinal === manifest.sections[sectionOrdinal]!.blockCount) {
      sectionOrdinal++; blockOrdinal = 0;
    }
  };
  advanceEmptySections();
  manifest.chunks.forEach((chunk, ordinal) => {
    chunkDescriptor(chunk); check(chunk.ordinal === ordinal);
    // Overlap is a contiguous suffix of already-covered source, never future input.
    let previous: AnalysisSpanDescriptor | undefined;
    let previousIndex = -1;
    for (const span of chunk.overlap) {
      const index = coveredById.get(JSON.stringify([span.sectionId, span.blockId]));
      check(index !== undefined);
      const covered = coveredBlocks[index]!;
      check(sameBlock(covered, span) && span.endOffset <= covered.endOffset);
      if (previous) {
        check(index >= previousIndex);
        if (index === previousIndex) check(previous.endOffset === span.startOffset);
        else {
          check(previous.endOffset === previous.blockLength && span.startOffset === 0);
          for (let skipped = previousIndex + 1; skipped < index; skipped++) {
            check(coveredBlocks[skipped]!.blockLength === 0);
          }
        }
      }
      previous = span; previousIndex = index;
    }
    if (previous) {
      check(previous.endOffset === coveredBlocks[previousIndex]!.endOffset);
      for (let skipped = previousIndex + 1; skipped < coveredBlocks.length; skipped++) {
        check(coveredBlocks[skipped]!.blockLength === 0);
      }
    }
    for (const span of chunk.primary) {
      const section = manifest.sections[sectionOrdinal];
      check(section && span.version === manifest.documentVersion && span.sectionOrdinal === sectionOrdinal &&
        span.sectionId === section.id && span.blockOrdinal === blockOrdinal && span.startOffset === offset);
      if (active) check(sameBlock(active, span));
      else {
        const key = JSON.stringify([span.sectionId, span.blockId]);
        check(!seenIds.has(key)); seenIds.add(key); active = span;
      }
      offset = span.endOffset;
      const key = JSON.stringify([span.sectionId, span.blockId]);
      const coveredIndex = coveredById.get(key);
      if (coveredIndex === undefined) {
        coveredById.set(key, coveredBlocks.length); coveredBlocks.push(span);
      } else coveredBlocks[coveredIndex] = { ...span, startOffset: 0 };
      if (offset === span.blockLength) {
        blockOrdinal++; offset = 0; active = undefined; advanceEmptySections();
      }
    }
  });
  check(sectionOrdinal === manifest.sections.length && !active);
  check(manifest.documentDigest === analysisDocumentDigest(manifest.chunks));
}
const segmenter = new Intl.Segmenter("und", { granularity: "grapheme" });
/** Returns exact UTF-16 boundaries; invalid evidence is never snapped to nearby prose. */
export function analysisGraphemeBoundaries(text: string): Set<number> {
  const result = new Set<number>([0, text.length]);
  for (const segment of segmenter.segment(text)) result.add(segment.index);
  return result;
}
/** Optional normalized block lookup proves original split boundaries as well as local text.
 * Without it, admission verifies exact hashes/lengths and local Unicode; the deterministic mapper
 * owns full-block split boundaries. Never normalize submitted text to repair a mismatch.
 */
export function validateAnalysisChunkInput(
  value: unknown, descriptor: AnalysisChunkDescriptor,
  blockText?: (span: AnalysisSpanDescriptor) => string,
): asserts value is AnalysisChunkInput {
  chunkDescriptor(descriptor);
  const input = record(value);
  check(Object.keys(input).every((key) => chunkFields.includes(key)));
  check(input.ordinal === descriptor.ordinal && input.hash === descriptor.hash && input.overlapHash === descriptor.overlapHash);
  for (const key of ["primary", "overlap"] as const) {
    const sources = input[key];
    check(Array.isArray(sources) && sources.length === descriptor[key].length);
    sources.forEach((value, index) => {
      const source = record(value), expected = descriptor[key][index]!;
      check(Object.keys(source).every((key) => key === "text" || Object.hasOwn(expected, key)));
      for (const field of spanFields) check(source[field] === expected[field]);
      check(typeof source.text === "string" && source.text.length === expected.endOffset - expected.startOffset &&
        !/\p{Surrogate}/u.test(source.text));
      const typed = source as AnalysisSourceSpan;
      check(analysisSpanHash(typed) === expected.hash);
      if (blockText) {
        const text = blockText(expected), boundaries = analysisGraphemeBoundaries(text);
        check(text.length === expected.blockLength && text.slice(expected.startOffset, expected.endOffset) === source.text &&
          boundaries.has(expected.startOffset) && boundaries.has(expected.endOffset));
      }
    });
  }
  const typed = input as AnalysisChunkInput;
  check(typed.primary.concat(typed.overlap).reduce((n, s) => n + s.text.length, 0) <= ANALYSIS_INPUT_MAX_UNITS);
  check(typed.overlap.reduce((n, s) => n + s.text.length, 0) <= ANALYSIS_OVERLAP_MAX_UNITS);
}
/** Validates exact block-local evidence against a loaded source span, including surface equality. */
export function validateAnalysisEvidenceSpan(span: AnalysisSpan, source: AnalysisSourceSpan, surface?: string): void {
  const start = record(record(span).start), end = record(record(span).end);
  integer(start.offset); integer(end.offset);
  for (const position of [start, end]) check(position.version === source.version &&
    position.sectionId === source.sectionId && position.blockId === source.blockId);
  check(start.offset >= source.startOffset && end.offset <= source.endOffset && start.offset < end.offset);
  const boundaries = analysisGraphemeBoundaries(source.text);
  const from = start.offset - source.startOffset, to = end.offset - source.startOffset;
  check(boundaries.has(from) && boundaries.has(to));
  if (surface !== undefined) check(source.text.slice(from, to) === surface);
}
