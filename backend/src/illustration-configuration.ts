import type { RequestHandler } from "express";
import { HttpError } from "./http.js";
import type { ImageGenerationConfig, ImageProviderId, IllustrationBookProfile } from "./types.js";

export interface IllustrationConfiguration {
  schemaVersion: 2;
  enabled: boolean;
  defaultProviderId: "openai";
  providers: Array<{
    id: ImageProviderId;
    label: string;
    model: string;
    costTier: "budget" | "balanced" | "premium" | "free";
    available: boolean;
    recommended: boolean;
    unavailableReason?: string;
  }>;
}
/** Nonsecret deployment catalogue. API availability never inspects worker keys. */
const providers = [
  { id: "openai", label: "OpenAI", model: "gpt-image-2.5-flare", costTier: "premium" },
  { id: "google", label: "Google", model: "gemini-nano-banana-2.1", costTier: "balanced" },
  { id: "seedream", label: "ByteDance Seedream", model: "seedream-4-0-250828", costTier: "budget" },
  { id: "qwen", label: "Alibaba Qwen", model: "qwen-image-3.0", costTier: "budget" },
  { id: "xai", label: "xAI", model: "grok-imagine-image-2.0", costTier: "balanced" },
  { id: "flux", label: "BFL FLUX", model: "flux-3-image", costTier: "premium" },
  { id: "diagnostic", label: "Pipeline test (prompt as text)", model: "text-image-diagnostic-v1", costTier: "free" },
] as const;

export function requireIllustrationSchema(value: unknown): void {
  if (value !== 2) throw new HttpError(400, "Illustration schema version 2 is required.");
}

export function requireImageProviderId(value: unknown): ImageProviderId {
  if (!providers.some(provider => provider.id === value)) throw new HttpError(400, "Illustration provider is invalid.");
  return value as ImageProviderId;
}

/** Missing IMAGE_PROVIDERS config enables no source; explicit deployment config is required. */
export function getIllustrationConfiguration(env: NodeJS.ProcessEnv = process.env): IllustrationConfiguration {
  const available = new Set((env.IMAGE_PROVIDERS ?? "").split(",").map(value => value.trim()));
  return {
    schemaVersion: 2 as const,
    enabled: env.ILLUSTRATIONS_ENABLED === "true",
    defaultProviderId: "openai" as const,
    providers: providers.map(provider => ({
      ...provider,
      model: provider.id === "openai" ? env.OPENAI_IMAGE_MODEL ?? provider.model : provider.model,
      available: available.has(provider.id),
      recommended: provider.id === "google" && available.has(provider.id),
      ...(!available.has(provider.id) ? { unavailableReason: "This source is not configured." } : {}),
    })),
  };
}

export function requireAvailableImageProvider(value: unknown, env: NodeJS.ProcessEnv = process.env): ImageProviderId {
  const id = requireImageProviderId(value);
  if (!getIllustrationConfiguration(env).providers.find(provider => provider.id === id)!.available) {
    throw new HttpError(503, "The selected illustration source is unavailable.");
  }
  return id;
}

/** Snapshot exact models at admission; queued operations never reinterpret environment overrides. */
export function snapshotImageGenerationConfig(providerId: ImageProviderId, env: NodeJS.ProcessEnv = process.env): ImageGenerationConfig {
  const provider = providers.find(provider => provider.id === providerId)!;
  return {
    schemaVersion: 2, providerId,
    model: providerId === "openai" ? env.OPENAI_IMAGE_MODEL ?? provider.model : provider.model,
    ...(providerId === "openai" ? { orchestratorModel: env.OPENAI_IMAGE_ORCHESTRATOR_MODEL ?? "gpt-5.5" } : {}),
    renderPreset: "reader-landscape-v1",
  };
}

/** Require explicit persisted schema and a complete authoritative profile, never infer legacy settings. */
export function requireIllustrationProfile(value: unknown): IllustrationBookProfile {
  const profile = value as Partial<IllustrationBookProfile> | undefined;
  if (!profile || profile.schemaVersion !== 2 || !providers.some(provider => provider.id === profile.providerId) ||
      typeof profile.style !== "string" || !profile.style.trim() || profile.style.length > 300 ||
      !Number.isInteger(profile.density) || profile.density! < 1 || profile.density! > 3 ||
      !Number.isSafeInteger(profile.revision) || profile.revision! < 1 ||
      !Number.isSafeInteger(profile.analysisVersion) || profile.analysisVersion! < 1) {
    throw new HttpError(409, "Book illustration settings must be confirmed.");
  }
  return profile as IllustrationBookProfile;
}

/** Validate persisted immutable recipes without comparing current availability or environment. */
export function requireImageGenerationConfig(value: unknown): ImageGenerationConfig {
  if (!value || typeof value !== "object" || !("schemaVersion" in value) || value.schemaVersion !== 2 ||
      !("providerId" in value) || !("model" in value) || typeof value.model !== "string" || !value.model.trim() ||
      !("renderPreset" in value) || value.renderPreset !== "reader-landscape-v1") {
    throw new HttpError(409, "Illustration operation configuration is invalid.");
  }
  const providerId = requireImageProviderId(value.providerId);
  const provider = providers.find(entry => entry.id === providerId)!;
  if (providerId === "openai") {
    if (!("orchestratorModel" in value) || typeof value.orchestratorModel !== "string" || !value.orchestratorModel.trim()) {
      throw new HttpError(409, "Illustration operation configuration is invalid.");
    }
    return { schemaVersion: 2, providerId, model: value.model, orchestratorModel: value.orchestratorModel, renderPreset: "reader-landscape-v1" };
  }
  if (value.model !== provider.model || "orchestratorModel" in value) {
    throw new HttpError(409, "Illustration operation configuration is invalid.");
  }
  return { schemaVersion: 2, providerId, model: value.model, renderPreset: "reader-landscape-v1" };
}

/** Mount after authentication/App Check, outside the rollout mutation gate. */
export const illustrationConfiguration: RequestHandler = (_req, res) => {
  res.set("Cache-Control", "no-store").json(getIllustrationConfiguration());
};
