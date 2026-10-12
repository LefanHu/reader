import assert from "node:assert/strict";
import { test } from "node:test";
import type {
  AnalysisChunkDescriptor, AnalysisChunkInput, AnalysisSourceManifest, AnalysisSourceSpan, AnalysisSpanDescriptor,
} from "./book-analysis-types.js";
import {
  AnalysisSourceValidationError, analysisChunkHash, analysisDocumentDigest, analysisOverlapHash, analysisSpanHash,
  validateAnalysisChunkInput, validateAnalysisDescriptorPage, validateAnalysisEvidenceSpan,
  validateAnalysisPageSize, validateAnalysisSourceManifest,
} from "./book-analysis-source.js";

function source(text: string, blockOrdinal = 0, startOffset = 0, blockLength = text.length): AnalysisSourceSpan {
  const span: AnalysisSourceSpan = { version: 1, sectionOrdinal: 0, sectionId: "s", blockOrdinal,
    blockId: `b${blockOrdinal}`, startOffset, endOffset: startOffset + text.length, blockLength, text, hash: "" };
  span.hash = analysisSpanHash(span);
  return span;
}
function descriptor(span: AnalysisSourceSpan): AnalysisSpanDescriptor {
  const { text: _text, ...result } = span;
  return result;
}
function chunk(ordinal: number, primary: AnalysisSourceSpan[], overlap: AnalysisSourceSpan[] = []): AnalysisChunkInput {
  return { ordinal, primary, overlap, hash: analysisChunkHash(primary), overlapHash: analysisOverlapHash(overlap) };
}
function manifest(inputs: AnalysisChunkInput[], blockCount: number): AnalysisSourceManifest {
  const chunks: AnalysisChunkDescriptor[] = inputs.map((input) => ({ ...input,
    primary: input.primary.map(descriptor), overlap: input.overlap.map(descriptor) }));
  return { schemaVersion: 1, analysisVersion: 1, promptVersion: 1, model: "gpt-6-luna",
    documentVersion: 1, documentDigest: analysisDocumentDigest(chunks), sectionCount: 2,
    blockCount, chunkCount: chunks.length, pageCount: chunks.length ? 1 : 0,
    sections: [{ ordinal: 0, id: "s", blockCount }, { ordinal: 1, id: "empty", blockCount: 0 }], chunks };
}

test("primitive-array hash preserves combining accents, emoji and original whitespace", () => {
  const span = { ...source("e\u0301😀\n"), blockId: "b" };
  assert.equal(analysisSpanHash(span), "67584d0116c4d0c25f86497defc735a6fa070df9fdb5e8f6fc2da12ce73f8f7d");
  assert.notEqual(analysisSpanHash(span), analysisSpanHash({ ...span, text: span.text.normalize("NFC") }));
});

test("primary coverage preserves empty blocks and empty sections without accepting empty evidence", () => {
  const input = chunk(0, [source(""), source("hello", 1)]);
  const result = manifest([input], 2);
  validateAnalysisSourceManifest(result);
  validateAnalysisChunkInput(input, result.chunks[0]!);
  const position = { version: 1, sectionId: "s", blockId: "b0", offset: 0 };
  assert.throws(() => validateAnalysisEvidenceSpan({ start: position, end: position }, input.primary[0]!),
    AnalysisSourceValidationError);
  validateAnalysisSourceManifest(manifest([], 0));
});

test("oversized blocks retain original offsets and overlap is only prior contiguous source", () => {
  const first = chunk(0, [source("ab", 0, 0, 4)]);
  const second = chunk(1, [source("cd", 0, 2, 4)], [source("b", 0, 1, 4)]);
  const result = manifest([first, second], 1);
  validateAnalysisSourceManifest(result);
  validateAnalysisChunkInput(second, result.chunks[1]!, () => "abcd");
  const future = chunk(1, second.primary, [source("c", 0, 2, 4)]);
  assert.throws(() => validateAnalysisSourceManifest(manifest([first, future], 1)), AnalysisSourceValidationError);
  const notSuffix = chunk(1, second.primary, [source("a", 0, 0, 4)]);
  assert.throws(() => validateAnalysisSourceManifest(manifest([first, notSuffix], 1)), AnalysisSourceValidationError);
});

test("gaps, duplicate block identities, reordered chunks and incomplete coverage are rejected", () => {
  const first = chunk(0, [source("ab", 0, 0, 4)]);
  const gap = chunk(1, [source("d", 0, 3, 4)]);
  assert.throws(() => validateAnalysisSourceManifest(manifest([first, gap], 1)), AnalysisSourceValidationError);
  assert.throws(() => validateAnalysisSourceManifest(manifest([first], 1)), AnalysisSourceValidationError);
  const duplicate = { ...source("cd", 1), blockId: "b0" };
  duplicate.hash = analysisSpanHash(duplicate);
  assert.throws(() => validateAnalysisSourceManifest(manifest([chunk(0, [source("ab"), duplicate])], 2)),
    AnalysisSourceValidationError);
  const reversed = manifest([chunk(1, [source("ab")]), chunk(0, [source("cd", 1)])], 2);
  assert.throws(() => validateAnalysisSourceManifest(reversed), AnalysisSourceValidationError);
});

test("grapheme-invalid evidence and source splits are rejected rather than snapped", () => {
  const span = source("e\u0301😀");
  const position = { version: 1, sectionId: "s", blockId: "b0", offset: 0 };
  validateAnalysisEvidenceSpan({ start: position, end: { ...position, offset: 2 } }, span, "e\u0301");
  for (const offset of [1, 3]) {
    assert.throws(() => validateAnalysisEvidenceSpan({ start: position, end: { ...position, offset } }, span),
      AnalysisSourceValidationError);
  }
  assert.throws(() => validateAnalysisEvidenceSpan({ start: position, end: { ...position, offset: 2 } }, span, "é"),
    AnalysisSourceValidationError);
  const split = chunk(0, [source("e", 0, 0, 2)]);
  assert.throws(() => validateAnalysisChunkInput(split, manifest([split], 1).chunks[0]!, () => "e\u0301"),
    AnalysisSourceValidationError);
});

test("transport rejects modified text and malformed UTF-16 without trimming", () => {
  const original = chunk(0, [source(" hello\n")]);
  const expected = manifest([original], 1).chunks[0]!;
  validateAnalysisChunkInput(original, expected);
  const changed = { ...original, primary: [{ ...original.primary[0]!, text: " HELLO\n" }] };
  assert.throws(() => validateAnalysisChunkInput(changed, expected), AnalysisSourceValidationError);
  const invalid = chunk(0, [source("\ud800")]);
  assert.throws(() => validateAnalysisChunkInput(invalid, manifest([invalid], 1).chunks[0]!), AnalysisSourceValidationError);
});

test("descriptor count, serialized byte bounds and window unit bounds reject oversized input", () => {
  const input = chunk(0, [source("a")]);
  const page = { chunks: [manifest([input], 1).chunks[0]!] };
  validateAnalysisDescriptorPage(page);
  assert.throws(() => validateAnalysisDescriptorPage({ chunks: Array.from({ length: 101 }, () => page.chunks[0]) }),
    AnalysisSourceValidationError);
  assert.throws(() => validateAnalysisPageSize({ text: "😀".repeat(33_000) }), AnalysisSourceValidationError);
  assert.throws(() => validateAnalysisSourceManifest(manifest([chunk(0, [source("a".repeat(8_001))])], 1)),
    AnalysisSourceValidationError);
  const first = chunk(0, [source("a".repeat(1_001), 0)]);
  const second = chunk(1, [source("b", 1)], first.primary);
  assert.throws(() => validateAnalysisSourceManifest(manifest([first, second], 2)), AnalysisSourceValidationError);
});
