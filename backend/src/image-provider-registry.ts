import type { ImageGenerationConfig, ImageProviderId } from "./types.js";
import { requireImageGenerationConfig } from "./illustration-configuration.js";
import { validateGeneratedImage, validateReferenceImages, type GeneratedImage, type ImageGenerationProvider, type ReferenceImage } from "./image-generation.js";
import { OpenAIImageProvider } from "./image-providers/openai-image-provider.js";
import { GoogleImageProvider } from "./image-providers/google-image-provider.js";
import { SeedreamImageProvider } from "./image-providers/seedream-image-provider.js";
import { QwenImageProvider } from "./image-providers/qwen-image-provider.js";
import { XaiImageProvider } from "./image-providers/xai-image-provider.js";
import { FluxImageProvider } from "./image-providers/flux-image-provider.js";
import { DiagnosticImageProvider } from "./image-providers/diagnostic-image-provider.js";

/** Worker credential check is performed before reserving an illustration credit. */
export interface CredentialedImageProvider extends ImageGenerationProvider {
  validateCredentials(): void | Promise<void>;
}

/** Exact snapshot dispatch and one decoder boundary; never cross-provider fallback. */
export class ImageProviderRegistry implements ImageGenerationProvider {
  private readonly providers: Record<ImageProviderId, CredentialedImageProvider>;
  constructor(overrides: Partial<Record<ImageProviderId, CredentialedImageProvider>> = {}) {
    this.providers = {
      openai: overrides.openai ?? new OpenAIImageProvider(),
      google: overrides.google ?? new GoogleImageProvider(),
      seedream: overrides.seedream ?? new SeedreamImageProvider(process.env.BYTEPLUS_API_KEY ?? ""),
      qwen: overrides.qwen ?? new QwenImageProvider(process.env.QWEN_API_KEY ?? ""),
      xai: overrides.xai ?? new XaiImageProvider(process.env.XAI_API_KEY ?? ""),
      flux: overrides.flux ?? new FluxImageProvider(process.env.BFL_API_KEY ?? ""),
      diagnostic: overrides.diagnostic ?? new DiagnosticImageProvider(process.env.IMAGE_TEST_PROVIDER_URL ?? ""),
    };
  }

  async validateCredentials(snapshot: ImageGenerationConfig): Promise<void> {
    const config = requireImageGenerationConfig(snapshot);
    await this.providers[config.providerId].validateCredentials();
  }

  async generate(snapshot: ImageGenerationConfig, prompt: string, references: readonly ReferenceImage[] = []): Promise<GeneratedImage> {
    const config = requireImageGenerationConfig(snapshot);
    let timer: NodeJS.Timeout | undefined;
    // Bound the full operation, including native reference/output validation.
    // A late transport result can never escape this promise for publication.
    try {
      return await Promise.race([
        (async () => {
          const provider = this.providers[config.providerId];
          const validatedReferences = await validateReferenceImages(references);
          const image = await provider.generate(config, prompt, validatedReferences);
          return validateGeneratedImage(image.bytes, image.mimeType);
        })(),
        new Promise<never>((_resolve, reject) => {
          timer = setTimeout(() => reject(new Error("Image operation timed out")), 120_000);
          timer.unref();
        }),
      ]);
    } finally { clearTimeout(timer); }
  }
}

/** Construct once per worker process; each generate call has its own deadline. */
export function createImageProviderRegistry(): ImageProviderRegistry {
  return new ImageProviderRegistry();
}
