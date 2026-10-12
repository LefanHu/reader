import { requireImageGenerationConfig } from "../illustration-configuration.js";
import {
  sniffImageMime, validateReferenceBounds,
  type GeneratedImage, type ImageGenerationProvider, type ReferenceImage,
} from "../image-generation.js";
import {
  createImageOperation, decodeImageBase64, referenceDataUri, type ImageHttpOptions,
} from "../image-provider-http.js";
import type { ImageGenerationConfig } from "../types.js";

/** Direct xAI transport switches to private inline multi-reference editing. */
export class XaiImageProvider implements ImageGenerationProvider {
  constructor(private readonly apiKey: string, private readonly httpOptions?: ImageHttpOptions) {}

  validateCredentials(): void {
    if (!this.apiKey || !/^\S+$/.test(this.apiKey)) throw new Error("The selected illustration source is unavailable.");
  }

  async generate(config: ImageGenerationConfig, prompt: string,
    referenceImages: readonly ReferenceImage[] = []): Promise<GeneratedImage> {
    const snapshot = requireImageGenerationConfig(config);
    if (snapshot.providerId !== "xai") throw new Error("Illustration operation configuration is invalid.");
    this.validateCredentials();
    const operation = createImageOperation(this.httpOptions);
    try {
      validateReferenceBounds(referenceImages);
      const references = referenceImages;
      const endpoint = references.length ? "edits" : "generations";
      const result = await operation.postJson(`https://api.x.ai/v1/images/${endpoint}`, {
        Authorization: `Bearer ${this.apiKey}`,
      }, {
        model: snapshot.model, prompt, n: 1, aspect_ratio: "3:2", resolution: "1.5k", response_format: "b64_json",
        ...(references.length ? { images: references.map(reference => ({ url: referenceDataUri(reference) })) } : {}),
      });
      if (result.error != null || result.refusal != null || !Array.isArray(result.data) || result.data.length !== 1) {
        throw new Error("The selected illustration source returned no usable image.");
      }
      const image = result.data[0] as Record<string, unknown> | null;
      if (!image || typeof image !== "object" || image.error != null || image.refusal != null) {
        throw new Error("The selected illustration source returned no usable image.");
      }
      const bytes = decodeImageBase64(image.b64_json);
      const mimeType = sniffImageMime(bytes);
      if (image.mime_type != null && image.mime_type !== mimeType) {
        throw new Error("The selected illustration source returned an invalid image type.");
      }
      return { bytes, mimeType };
    } finally {
      operation.close();
    }
  }
}
