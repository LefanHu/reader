import type { AnalysisEvidence, AnalysisPosition } from "./book-analysis-types.js";

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
  /** Exact normalization version of the paragraphs (TextDocument.version); anchors source positions. */
  documentVersion: number;
  paragraphs: Paragraph[];
};

/** One supported, scene-applicable fact with provenance; never a whole-book log. */
export type IllustrationContextFact = {
  assertionId: string; subject: string; property: string; value: string; object?: string;
  category: string | null; evidence: AnalysisEvidence; revealAt: AnalysisPosition;
};

/**
 * Temporally filtered evidence admitted when a scene plan was built. Persisted in the recipe so
 * retries, regeneration and expiry refresh reuse the same truth. Bounded to 8,000 UTF-16 units.
 */
export type IllustrationContext = {
  schemaVersion: 1; analysisRevision: string; generationId: string;
  sceneStart: AnalysisPosition; sceneEnd: AnalysisPosition;
  /** Labels revealed no later than the scene end (aliases never appear early). */
  subjects: { id: string; kind: string; names: string[] }[];
  facts: IllustrationContextFact[];
};

/** Persisted recipe so regeneration reuses the exact admitted config and selected passage. */
export type SceneGenerationSpec = {
  /** Exact provider/model/preset admitted for this operation, never live settings. */
  imageConfig: ImageGenerationConfig;
  style: string;
  /** Selected paragraphs (≤6,000 chars), kept with the scene for regeneration. */
  sceneText: string;
  /** Absent on recipes created before preprocessing; those keep scene-only prompts. */
  context?: IllustrationContext;
  /** Complete source range of the scene, kept for audit and consistent refresh. */
  sceneStart?: AnalysisPosition;
  sceneEnd?: AnalysisPosition;
};
