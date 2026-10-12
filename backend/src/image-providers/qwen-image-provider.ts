import { requireImageGenerationConfig } from "../illustration-configuration.js";
import {
  sniffImageMime, validateReferenceBounds,
  type GeneratedImage, type ImageGenerationProvider, type ReferenceImage,
} from "../image-generation.js";
import { createImageOperation, referenceDataUri, type ImageHttpOptions } from "../image-provider-http.js";
import type { ImageGenerationConfig } from "../types.js";

/** Singapore Model Studio returns private expiring PNG assets, not base64 images. */
export class QwenImageProvider implements ImageGenerationProvider {
  constructor(private readonly apiKey: string, private readonly httpOptions?: ImageHttpOptions) {}

  validateCredentials(): void {
    if (!this.apiKey || !/^\S+$/.test(this.apiKey)) throw new Error("The selected illustration source is unavailable.");
  }

  async generate(config: ImageGenerationConfig, prompt: string,
    referenceImages: readonly ReferenceImage[] = []): Promise<GeneratedImage> {
    const snapshot = requireImageGenerationConfig(config);
    if (snapshot.providerId !== "qwen") throw new Error("Illustration operation configuration is invalid.");
    this.validateCredentials();
    const operation = createImageOperation(this.httpOptions);
    try {
      validateReferenceBounds(referenceImages);
      const references = referenceImages;
      const result = await operation.postJson("https://dashscope-intl.aliyuncs.com/compatible-mode/v1/images/generations", {
        Authorization: `Bearer ${this.apiKey}`,
      }, {
        model: snapshot.model, prompt, size: "1536x1024", n: 1, watermark: false, prompt_extend: false,
        ...(references.length ? { image: references.map(referenceDataUri) } : {}),
      });
      if (result.error != null || !Array.isArray(result.data) || result.data.length !== 1) {
        throw new Error("The selected illustration source returned no usable image.");
      }
      const image = result.data[0] as Record<string, unknown> | null;
      if (!image || typeof image !== "object" || image.error != null || typeof image.url !== "string") {
        throw new Error("The selected illustration source returned no usable image.");
      }
      const bytes = await operation.downloadImage(image.url, "qwen");
      const mimeType = sniffImageMime(bytes);
      if (mimeType !== "image/png") throw new Error("The selected illustration source returned an invalid image type.");
      return { bytes, mimeType };
    } finally {
      operation.close();
    }
  }
}
