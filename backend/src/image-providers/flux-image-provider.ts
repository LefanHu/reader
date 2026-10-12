import { requireImageGenerationConfig } from "../illustration-configuration.js";
import {
  sniffImageMime, validateReferenceBounds,
  type GeneratedImage, type ImageGenerationProvider, type ReferenceImage,
} from "../image-generation.js";
import { createImageOperation, type ImageHttpOptions } from "../image-provider-http.js";
import type { ImageGenerationConfig } from "../types.js";

const taskIdPattern = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;

/** Direct BFL transport preserves the signed original, including Content Credentials. */
export class FluxImageProvider implements ImageGenerationProvider {
  constructor(private readonly apiKey: string, private readonly httpOptions?: ImageHttpOptions) {}

  validateCredentials(): void {
    if (!this.apiKey || !/^\S+$/.test(this.apiKey)) throw new Error("The selected illustration source is unavailable.");
  }

  async generate(config: ImageGenerationConfig, prompt: string,
    referenceImages: readonly ReferenceImage[] = []): Promise<GeneratedImage> {
    const snapshot = requireImageGenerationConfig(config);
    if (snapshot.providerId !== "flux") throw new Error("Illustration operation configuration is invalid.");
    this.validateCredentials();
    const operation = createImageOperation(this.httpOptions);
    try {
      validateReferenceBounds(referenceImages);
      const references = referenceImages;
      const submission = await operation.postJson("https://api.bfl.ai/v1/flux-3-image", {
        "x-key": this.apiKey,
      }, {
        prompt, aspect_ratio: "3:2", resolution: "1.5k", grounding: false, safety_tolerance: 2,
        ...(references.length ? { images: references.map(reference => reference.bytes.toString("base64")) } : {}),
      });
      if (submission.error != null || typeof submission.id !== "string" || !taskIdPattern.test(submission.id) ||
          typeof submission.polling_url !== "string") {
        throw new Error("The selected illustration source returned an invalid task.");
      }
      // The returned cluster-specific URL is authoritative; never reconstruct a global URL.
      while (true) {
        const result = await operation.pollJson(submission.polling_url, { "x-key": this.apiKey });
        if (result.error != null || (result.id != null && result.id !== submission.id)) {
          throw new Error("The selected illustration source could not complete this image.");
        }
        switch (result.status) {
          case "Ready": {
            const output = result.result as Record<string, unknown> | null;
            if (!output || typeof output !== "object" || typeof output.sample !== "string") {
              throw new Error("The selected illustration source returned no usable image.");
            }
            const bytes = await operation.downloadImage(output.sample, "flux");
            return { bytes, mimeType: sniffImageMime(bytes) };
          }
          case "Pending":
          case "Reasoning":
          case "Generating":
            await operation.sleep(2_000);
            break;
          case "Request Moderated":
          case "Content Moderated":
          case "Error":
          case "Failed":
          case "Task not found":
          default:
            throw new Error("The selected illustration source could not complete this image.");
        }
      }
    } finally {
      operation.close();
    }
  }
}
