import { GoogleAuth } from "google-auth-library";
import { requireImageGenerationConfig } from "../illustration-configuration.js";
import {
  sniffImageMime, validateReferenceBounds,
  type GeneratedImage, type ImageGenerationProvider, type ReferenceImage,
} from "../image-generation.js";
import { createImageOperation, decodeImageBase64, type ImageHttpOptions } from "../image-provider-http.js";
import type { ImageGenerationConfig } from "../types.js";

export interface DiagnosticImageOptions extends ImageHttpOptions {
  /** Test seam; production mints a Google-signed ID token for the service audience. */
  idToken?: (audience: string) => Promise<string>;
}

const UNAVAILABLE = "The selected illustration source is unavailable.";

/**
 * Calls the separately deployed pipeline-test service, which answers with a PNG
 * listing the exact prompt. It travels the same registry, validation, moderation
 * and publication path as every real source. The service URL is deployment
 * configuration, never client input, and must be a bare `*.run.app` HTTPS origin.
 */
export class DiagnosticImageProvider implements ImageGenerationProvider {
  private readonly auth = new GoogleAuth();
  constructor(private readonly url: string, private readonly options: DiagnosticImageOptions = {}) {}

  private origin(): string {
    try {
      const parsed = new URL(this.url);
      if (parsed.protocol !== "https:" || parsed.username || parsed.password || parsed.port || parsed.hash ||
          !parsed.hostname.endsWith(".run.app")) throw new Error();
      return parsed.origin;
    } catch { throw new Error(UNAVAILABLE); }
  }

  private async token(audience: string): Promise<string> {
    try {
      const value = await (this.options.idToken
        ? this.options.idToken(audience)
        : this.auth.getIdTokenClient(audience).then(client => client.idTokenProvider.fetchIdToken(audience)));
      if (!value || !value.trim()) throw new Error();
      return value;
    } catch { throw new Error(UNAVAILABLE); }
  }

  async validateCredentials(): Promise<void> {
    const origin = this.origin();
    const operation = createImageOperation(this.options);
    try { await operation.bounded(this.token(origin)); } finally { operation.close(); }
  }

  async generate(config: ImageGenerationConfig, prompt: string,
    referenceImages: readonly ReferenceImage[] = []): Promise<GeneratedImage> {
    const snapshot = requireImageGenerationConfig(config);
    if (snapshot.providerId !== "diagnostic") throw new Error("Illustration operation configuration is invalid.");
    const origin = this.origin();
    validateReferenceBounds(referenceImages);
    const operation = createImageOperation(this.options);
    try {
      const token = await operation.bounded(this.token(origin));
      const result = await operation.postJson(`${origin}/v1/render`, { authorization: `Bearer ${token}` }, {
        prompt, referenceCount: referenceImages.length,
      });
      if (typeof result.data !== "string" || typeof result.mimeType !== "string") {
        throw new Error("The selected illustration source returned no usable image.");
      }
      const bytes = decodeImageBase64(result.data);
      const mimeType = sniffImageMime(bytes);
      if (result.mimeType !== mimeType) throw new Error("The selected illustration source returned an invalid image type.");
      return { bytes, mimeType };
    } finally {
      operation.close();
    }
  }
}
