import type { ImageGenerationConfig } from "../types.js";
import { requireImageGenerationConfig } from "../illustration-configuration.js";
import { sniffImageMime, validateReferenceBounds, type GeneratedImage, type ImageGenerationProvider, type ReferenceImage } from "../image-generation.js";
import { createImageOperation, decodeImageBase64, referenceDataUri, type ImageHttpOptions } from "../image-provider-http.js";
import { OPENAI_API_BASE_URL, openAIApiKey } from "../openai-client.js";

/** Low-level Responses transport; the registry validates decoded original pixels. */
export class OpenAIImageProvider implements ImageGenerationProvider {
  constructor(private readonly key = openAIApiKey(), private readonly http: ImageHttpOptions = {}) {}

  validateCredentials(): void {
    if (!this.key.trim()) throw new Error("OpenAI image credentials are unavailable");
  }

  async generate(snapshot: ImageGenerationConfig, prompt: string, references: readonly ReferenceImage[] = []): Promise<GeneratedImage> {
    const config = requireImageGenerationConfig(snapshot);
    if (config.providerId !== "openai") throw new Error("Image provider configuration mismatch");
    this.validateCredentials();
    validateReferenceBounds(references);
    const operation = createImageOperation(this.http);
    try {
      const response = await operation.postJson(`${OPENAI_API_BASE_URL}/responses`, { authorization: `Bearer ${this.key}` }, {
        model: config.orchestratorModel,
        store: false,
        input: [{ role: "user", content: [
          { type: "input_text", text: prompt },
          ...references.map(reference => ({ type: "input_image", image_url: referenceDataUri(reference) })),
        ] }],
        tools: [{
          type: "image_generation", model: config.model,
          action: references.length > 0 ? "auto" : "generate",
          size: "1536x1024", quality: "high", output_format: "webp",
          background: "opaque", moderation: "auto",
        }],
        tool_choice: { type: "image_generation" },
      });
      if (response.error || response.status === "failed" || response.status === "incomplete") {
        throw new Error("OpenAI image request failed");
      }
      const output = Array.isArray(response.output) ? response.output : [];
      const images: unknown[] = [];
      for (const raw of output) {
        if (!raw || typeof raw !== "object") continue;
        const item = raw as Record<string, unknown>;
        if (item.type === "image_generation_call") {
          if (item.error || (item.status !== undefined && item.status !== "completed")) throw new Error("OpenAI image request failed");
          images.push(item.result);
        }
        if (Array.isArray(item.content) && item.content.some(part => part && typeof part === "object" && part.type === "refusal")) {
          throw new Error("OpenAI image request was refused");
        }
      }
      if (images.length !== 1) throw new Error("OpenAI response did not contain exactly one image");
      const bytes = decodeImageBase64(images[0]);
      return { bytes, mimeType: sniffImageMime(bytes) };
    } finally { operation.close(); }
  }
}
