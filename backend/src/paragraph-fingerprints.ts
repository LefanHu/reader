import { createHash } from "node:crypto";
import { HttpError } from "./http.js";

/** Bytes per paragraph fingerprint; an all-zero value marks a skipped paragraph. */
export const FINGERPRINT_BYTES = 8;

/** Most paragraphs one copy may send; bounds the fingerprints body and stored reference. */
export const MAX_PARAGRAPHS = 200_000;

/** Normalized paragraphs shorter than this repeat too often to identify a text. */
const MIN_FINGERPRINT_CHARACTERS = 20;

/**
 * Text that survives formatting differences between files of the same text:
 * lowercase letters and digits only, so quotes, dashes, spacing and line breaks
 * never matter. Final sigma folds to sigma because Dart and JS lowercase it
 * differently. Must stay identical to `normalizeParagraph` in
 * `lib/text_identity/paragraph_fingerprints.dart`; the shared golden
 * `backend/test-fixtures/fingerprints.json` pins both.
 */
export function normalizeParagraph(text: string): string {
  return (text.toLowerCase().match(/[\p{L}\p{N}]/gu) ?? []).join("").replaceAll("ς", "σ");
}

/** First 8 bytes of SHA-256 over the normalized text, or zeros when it is too short to identify. */
export function paragraphFingerprint(text: string): Buffer {
  const normalized = normalizeParagraph(text);
  if ([...normalized].length < MIN_FINGERPRINT_CHARACTERS) return Buffer.alloc(FINGERPRINT_BYTES);
  return createHash("sha256").update(normalized, "utf8").digest().subarray(0, FINGERPRINT_BYTES);
}

/** Splits concatenated fingerprints into hex values; "" marks a skipped paragraph. */
export function fingerprintList(bytes: Buffer): string[] {
  if (bytes.length === 0 || bytes.length % FINGERPRINT_BYTES !== 0 || bytes.length / FINGERPRINT_BYTES > MAX_PARAGRAPHS) {
    throw new HttpError(400, "Paragraph fingerprints are invalid.");
  }
  const values: string[] = [];
  for (let offset = 0; offset < bytes.length; offset += FINGERPRINT_BYTES) {
    const value = bytes.subarray(offset, offset + FINGERPRINT_BYTES);
    values.push(value.every(byte => byte === 0) ? "" : value.toString("hex"));
  }
  return values;
}

/** Fingerprints in a text's sketch; Firestore's `array-contains-any` accepts at most 30 values. */
export const SKETCH_SIZE = 30;

/**
 * Bottom-k sketch: the numerically smallest distinct identifiable fingerprints.
 * Fingerprints are uniform hashes, so this is a deterministic random sample of
 * paragraphs: copies of the same text share most of their sketch, and an
 * abridged copy shares a proportional part, while unrelated texts share none.
 */
export function sketchOf(values: string[]): string[] {
  // Fixed-width lowercase hex sorts lexicographically in numeric order.
  return [...new Set(values.filter(value => value !== ""))].sort().slice(0, SKETCH_SIZE);
}
