/** Stable server-owned choices; clients select IDs, never models or endpoints. */
export type ImageProviderId = "openai" | "google" | "seedream" | "qwen" | "xai" | "flux" | "diagnostic";

/** Immutable operation identity. Changing render options requires a new preset. */
export type ImageGenerationConfig = {
  schemaVersion: 2;
  providerId: ImageProviderId;
  model: string;
  orchestratorModel?: string;
  renderPreset: "reader-landscape-v1";
};

/** Authoritative book settings; revision advances only for effective changes. */
export type IllustrationBookProfile = {
  schemaVersion: 2;
  providerId: ImageProviderId;
  style: string;
  density: number;
  revision: number;
  analysisVersion: number;
};

export type Paragraph = {
  id: string;
  text: string;
  cssSelector: string;
  ordinal: number;
  progression: number;
};

/** One scheduled prose resource. Scene selection reads it per window; only the selected paragraphs reach image generation. */
export type ChapterInput = {
  href: string;
  title?: string;
  language?: string;
  /** Admission's immutable profile revision; density is snapshotted server-side. */
  profileRevision: number;
  analysisVersion: number;
  density: number;
  paragraphs: Paragraph[];
};

/** Persisted recipe so regeneration reuses the exact admitted config and selected passage. */
export type SceneGenerationSpec = {
  /** Exact provider/model/preset admitted for this operation, never live settings. */
  imageConfig: ImageGenerationConfig;
  style: string;
  /** Selected paragraphs (≤6,000 chars), kept with the scene for regeneration. */
  sceneText: string;
};
