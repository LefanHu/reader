import { GoogleAuth } from "google-auth-library";
import type { ImageGenerationConfig } from "../types.js";
import { requireImageGenerationConfig } from "../illustration-configuration.js";
import { validateReferenceBounds, type GeneratedImage, type ImageGenerationProvider, type ImageMimeType, type ReferenceImage } from "../image-generation.js";
import { createImageOperation, decodeImageBase64, type ImageHttpOptions } from "../image-provider-http.js";

/** ADC-only Cloud access; never Gemini Developer API or service-account key input. */
export interface GoogleImageOptions extends ImageHttpOptions {
  project?: string;
  accessToken?: () => Promise<string | null>;
}

/** Fixed global Cloud generateContent endpoint, no grounding or safety override. */
export class GoogleImageProvider implements ImageGenerationProvider {
  private readonly auth = new GoogleAuth({ scopes: ["https://www.googleapis.com/auth/cloud-platform"] });
  private readonly project: string;
  constructor(private readonly options: GoogleImageOptions = {}) {
    this.project = options.project ?? process.env.GOOGLE_CLOUD_PROJECT ?? "";
  }

  private async token(): Promise<string> {
    try {
      const value = await (this.options.accessToken ? this.options.accessToken() : this.auth.getAccessToken());
      if (!value || !value.trim()) throw new Error();
      return value;
    } catch { throw new Error("Google image credentials are unavailable"); }
  }

  async validateCredentials(): Promise<void> {
    if (!/^[a-z][a-z0-9-]{4,61}[a-z0-9]$/.test(this.project)) throw new Error("Google image project is unavailable");
    const operation = createImageOperation(this.options);
    try { await operation.bounded(this.token()); } finally { operation.close(); }
  }

  async generate(snapshot: ImageGenerationConfig, prompt: string, references: readonly ReferenceImage[] = []): Promise<GeneratedImage> {
    const config = requireImageGenerationConfig(snapshot);
    if (config.providerId !== "google") throw new Error("Image provider configuration mismatch");
    if (!/^[a-z][a-z0-9-]{4,61}[a-z0-9]$/.test(this.project)) throw new Error("Google image project is unavailable");
    validateReferenceBounds(references);
    const operation = createImageOperation(this.options);
    try {
      const token = await operation.bounded(this.token());
      const url = `https://aiplatform.googleapis.com/v1/projects/${this.project}/locations/global/publishers/google/models/${config.model}:generateContent`;
      const response = await operation.postJson(url, { authorization: `Bearer ${token}` }, {
        contents: [{ role: "user", parts: [
          { text: prompt },
          ...references.map(reference => ({ inlineData: { mimeType: reference.mimeType, data: reference.bytes.toString("base64") } })),
        ] }],
        generationConfig: {
          candidateCount: 1, responseModalities: ["TEXT", "IMAGE"],
          imageConfig: { aspectRatio: "3:2", imageSize: "2K" },
        },
      });
      if (response.error || (response.promptFeedback && typeof response.promptFeedback === "object" &&
          "blockReason" in response.promptFeedback && response.promptFeedback.blockReason)) {
        throw new Error("Google image request was blocked");
      }
      const candidates = Array.isArray(response.candidates) ? response.candidates : [];
      const images: Array<{ data: unknown; mimeType: ImageMimeType }> = [];
      for (const raw of candidates) {
        if (!raw || typeof raw !== "object") continue;
        const candidate = raw as Record<string, unknown>;
        if (candidate.finishReason !== undefined && candidate.finishReason !== "STOP") throw new Error("Google image request did not finish safely");
        if (Array.isArray(candidate.safetyRatings) && candidate.safetyRatings.some(rating => rating && typeof rating === "object" && rating.blocked === true)) {
          throw new Error("Google image request was blocked");
        }
        const content = candidate.content;
        if (!content || typeof content !== "object" || !("parts" in content) || !Array.isArray(content.parts)) continue;
        for (const rawPart of content.parts) {
          if (!rawPart || typeof rawPart !== "object" || rawPart.thought === true || !rawPart.inlineData) continue;
          const inline = rawPart.inlineData as { data?: unknown; mimeType?: unknown };
          if (!["image/png", "image/jpeg", "image/webp"].includes(inline.mimeType as string)) throw new Error("Google returned an unsupported image");
          images.push({ data: inline.data, mimeType: inline.mimeType as ImageMimeType });
        }
      }
      if (images.length !== 1) throw new Error("Google response did not contain exactly one image");
      return { bytes: decodeImageBase64(images[0]!.data), mimeType: images[0]!.mimeType };
    } finally { operation.close(); }
  }
}
