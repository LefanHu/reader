import { createHash } from "node:crypto";
import { HttpError, requireString } from "./http.js";

/** Bytes per paragraph fingerprint; an all-zero value marks a skipped paragraph. */
export const FINGERPRINT_BYTES = 8;

/** Most paragraphs one copy may send; bounds the fingerprints body and stored reference. */
export const MAX_PARAGRAPHS = 200_000;

/** Normalized paragraphs shorter than this repeat too often to identify a text. */
const MIN_FINGERPRINT_CHARACTERS = 20;

/**
 * Text that survives formatting differences between files of the same work:
 * lowercase letters and digits only, so quotes, dashes, spacing and line breaks
 * never matter. Final sigma folds to sigma because Dart and JS lowercase it
 * differently. Must stay identical to `lib/catalog_works/work_text.dart`; the
 * shared golden `backend/test-fixtures/fingerprints.json` pins both.
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

/** Search tokens: lowercase letter/digit runs of two or more characters, deduplicated. */
export function searchTokens(text: string): string[] {
  const tokens = text.toLowerCase().replaceAll("ς", "σ").match(/[\p{L}\p{N}]{2,}/gu) ?? [];
  return [...new Set(tokens)];
}

/**
 * Title and author are required, bounded display strings; author may be empty.
 * Composed (NFC) because Open Library sends decomposed accents ("Ju\u0308nger")
 * while files and keyboards produce composed ones.
 */
export function requireWorkMetadata(value: unknown): { title: string; author: string } {
  const metadata = value as { title?: unknown; author?: unknown } | null;
  const display = (text: unknown) => typeof text === "string" ? text.normalize("NFC").trim() : undefined;
  const title = requireString(display(metadata?.title), "title", 500);
  const author = display(metadata?.author)?.slice(0, 500) ?? "";
  return { title, author };
}

/** Lowercase words without accents, so spelling variants of one name agree. */
function identityWords(text: string): string[] {
  return text.normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? [];
}

/**
 * Global work identity: the title without a leading article plus the author.
 * Open Library's duplicate rows ("Storm of Steel", "The storm of steel") and
 * a file's own metadata for the same book all land on one work.
 */
export function workIdFor(title: string, author: string): string {
  const words = identityWords(title);
  if (words.length > 1 && ["the", "a", "an"].includes(words[0]!)) words.shift();
  const key = `${words.join(" ")}\n${identityWords(author).join(" ")}`;
  return createHash("sha256").update(key, "utf8").digest("hex").slice(0, 20);
}
