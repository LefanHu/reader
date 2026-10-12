import { requireImageGenerationConfig } from "../illustration-configuration.js";
import {
  sniffImageMime, validateReferenceBounds,
  type GeneratedImage, type ImageGenerationProvider, type ReferenceImage,
} from "../image-generation.js";
import {
  createImageOperation, decodeImageBase64, referenceDataUri, type ImageHttpOptions,
} from "../image-provider-http.js";
import type { ImageGenerationConfig } from "../types.js";

/** Direct BytePlus transport; references stay private inline inputs. */
export class SeedreamImageProvider implements ImageGenerationProvider {
  constructor(private readonly apiKey: string, private readonly httpOptions?: ImageHttpOptions) {}

  validateCredentials(): void {
    if (!this.apiKey || !/^\S+$/.test(this.apiKey)) throw new Error("The selected illustration source is unavailable.");
  }

  async generate(config: ImageGenerationConfig, prompt: string,
    referenceImages: readonly ReferenceImage[] = []): Promise<GeneratedImage> {
    const snapshot = requireImageGenerationConfig(config);
    if (snapshot.providerId !== "seedream") throw new Error("Illustration operation configuration is invalid.");
    this.validateCredentials();
    const operation = createImageOperation(this.httpOptions);
    try {
      validateReferenceBounds(referenceImages);
      const references = referenceImages;
      const result = await operation.postJson("https://ark.ap-southeast.bytepluses.com/api/v3/images/generations", {
        Authorization: `Bearer ${this.apiKey}`,
      }, {
        model: snapshot.model, prompt, size: "1536x1024", response_format: "b64_json",
        stream: false, watermark: false, sequential_image_generation: "disabled",
        ...(references.length ? { image: references.map(referenceDataUri) } : {}),
      });
      if (result.error != null || !Array.isArray(result.data) || result.data.length !== 1) {
        throw new Error("The selected illustration source returned no usable image.");
      }
      const image = result.data[0] as Record<string, unknown> | null;
      if (!image || typeof image !== "object" || image.error != null) {
        throw new Error("The selected illustration source returned no usable image.");
      }
      const bytes = decodeImageBase64(image.b64_json);
      return { bytes, mimeType: sniffImageMime(bytes) };
    } finally {
      operation.close();
    }
  }
}
