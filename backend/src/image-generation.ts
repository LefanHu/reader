import sharp from "sharp";
import type { ImageGenerationConfig } from "./types.js";

/** Verified decoder MIME, not a filename or an upstream declaration. */
export type ImageMimeType = "image/png" | "image/jpeg" | "image/webp";
/** Private bounded continuity input, encoded inline without public uploads. */
export type ReferenceImage = { bytes: Buffer; mimeType: ImageMimeType };
/** Provider original bytes; publication must not resize or remove metadata. */
export type GeneratedImage = { bytes: Buffer; mimeType: ImageMimeType };
/** One chosen operation, with no implicit retries or cross-provider fallback. */
export interface ImageGenerationProvider {
  generate(config: ImageGenerationConfig, prompt: string,
    referenceImages?: readonly ReferenceImage[]): Promise<GeneratedImage>;
}

export const MAX_IMAGE_BYTES = 16 * 1024 * 1024;
export const MAX_REFERENCE_BYTES = 7 * 1024 * 1024;
const MAX_IMAGE_PIXELS = 16_777_216;


/** Cheap transport guard before base64 allocation; registry also fully decodes. */
export function validateReferenceBounds(references: readonly ReferenceImage[] = []): void {
  if (!Array.isArray(references) || references.length > 2 ||
      references.some(reference => !reference || !Buffer.isBuffer(reference.bytes) ||
        reference.bytes.length === 0 || reference.bytes.length > MAX_REFERENCE_BYTES)) {
    throw new Error("Reference images exceed permitted limits");
  }
}

/** Signature-only transport MIME; central decoder verifies the full original. */
export function sniffImageMime(bytes: Buffer): ImageMimeType {
  if (bytes.length >= 8 && bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) return "image/png";
  if (bytes.length >= 3 && bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255) return "image/jpeg";
  if (bytes.length >= 12 && bytes.toString("ascii", 0, 4) === "RIFF" && bytes.toString("ascii", 8, 12) === "WEBP") return "image/webp";
  throw new Error("Provider returned an unsupported image");
}
/** Decode exactly one bounded frame, without rewriting the published original. */
async function validateImage(bytes: Buffer, maxBytes: number, landscape: boolean,
  declaredMime?: unknown): Promise<GeneratedImage> {
  if (!Buffer.isBuffer(bytes) || bytes.length === 0 || bytes.length > maxBytes) {
    throw new Error("Image exceeds the permitted byte limit");
  }
  try {
    const decoder = sharp(bytes, { limitInputPixels: MAX_IMAGE_PIXELS, failOn: "warning", animated: true });
    const metadata = await decoder.metadata();
    const mimeType = ({ png: "image/png", jpeg: "image/jpeg", webp: "image/webp" } as const)[
      metadata.format as "png" | "jpeg" | "webp"
    ];
    if (!mimeType || (metadata.pages ?? 1) !== 1 || !metadata.width || !metadata.height ||
        metadata.width * metadata.height > MAX_IMAGE_PIXELS ||
        (declaredMime !== undefined && declaredMime !== mimeType)) {
      throw new Error("Unsupported image format or dimensions");
    }
    if (mimeType === "image/png") {
      // Some libvips PNG loaders decode only APNG's default image and report no
      // page count. Refuse its animation control chunk rather than accept a
      // silently ignored second frame.
      for (let offset = 8; offset + 12 <= bytes.length;) {
        const size = bytes.readUInt32BE(offset);
        if (offset + size + 12 > bytes.length) throw new Error("Invalid PNG chunk");
        if (bytes.toString("ascii", offset + 4, offset + 8) === "acTL") throw new Error("Animated PNG is not permitted");
        offset += size + 12;
      }
    }
    if (mimeType === "image/jpeg") {
      // MPF/MPO containers may likewise expose only their first JPEG to sharp.
      // Walk length-delimited header markers, never search provenance payloads.
      for (let offset = 2; offset + 4 <= bytes.length;) {
        if (bytes[offset++] !== 0xff) throw new Error("Invalid JPEG marker");
        while (bytes[offset] === 0xff) offset++;
        const marker = bytes[offset++];
        if (marker === 0xda || marker === 0xd9) break;
        if (marker === 0x01 || (marker !== undefined && marker >= 0xd0 && marker <= 0xd7)) continue;
        if (offset + 2 > bytes.length) throw new Error("Invalid JPEG marker");
        const size = bytes.readUInt16BE(offset);
        if (size < 2 || offset + size > bytes.length) throw new Error("Invalid JPEG marker");
        if (marker === 0xe2 && size >= 6 && bytes.toString("ascii", offset + 2, offset + 5) === "MPF" && bytes[offset + 5] === 0) {
          throw new Error("Multi-picture JPEG is not permitted");
        }
        offset += size;
      }
    }
    const rotated = metadata.orientation !== undefined && metadata.orientation >= 5;
    const width = rotated ? metadata.height : metadata.width;
    const height = rotated ? metadata.width : metadata.height;
    if (landscape && Math.abs(width / height / 1.5 - 1) > 0.02) {
      throw new Error("Image does not match the landscape preset");
    }
    // Metadata does not prove compressed pixels are intact. Native statistics
    // forces a full decode without copying an unnecessary raw raster into JS.
    await decoder.stats();
    return { bytes, mimeType };
  } catch {
    // Decoder errors can contain upstream metadata; never propagate it.
    throw new Error("Image validation failed");
  }
}

/** Provider declarations must agree with native MIME; originals are byte-identical. */
export function validateGeneratedImage(bytes: Buffer, declaredMime?: unknown): Promise<GeneratedImage> {
  return validateImage(bytes, MAX_IMAGE_BYTES, true, declaredMime);
}

/** Missing/corrupt references can be omitted by the caller, never transcoded. */
export function validateReferenceImage(bytes: Buffer): Promise<ReferenceImage> {
  return validateImage(bytes, MAX_REFERENCE_BYTES, false);
}

/** Admission to a provider is limited to two decoded private continuity inputs. */
export async function validateReferenceImages(references: readonly ReferenceImage[] = []): Promise<ReferenceImage[]> {
  validateReferenceBounds(references);
  const result: ReferenceImage[] = [];
  for (const reference of references) result.push(await validateReferenceImage(reference.bytes));
  return result;
}
