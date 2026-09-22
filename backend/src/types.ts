export type Paragraph = {
  id: string;
  text: string;
  cssSelector: string;
  ordinal: number;
  progression: number;
};

/** One scheduled prose resource. It is analyzed once, never sent to image generation whole. */
export type ChapterInput = {
  href: string;
  title?: string;
  language?: string;
  styleVersion: number;
  analysisVersion: number;
  density: number;
  paragraphs: Paragraph[];
};

export type WorldEntityKind = "character" | "location" | "group" | "event" | "lore";

/** Compact latest-known entity supplied to the analyzer for cross-chapter resolution. */
export type WorldSnapshot = {
  entityId: string;
  kind: WorldEntityKind;
  name: string;
  aliases: string[];
  summary: string;
  visualDescription: string;
  stateFacts: string[];
  referenceObject?: string;
};

/** Model-authored patch anchored to the first paragraph where it becomes true. */
export type EntityDelta = {
  entityRef: string;
  kind: WorldEntityKind;
  anchorParagraphId: string;
  name: string;
  aliases: string[];
  summary: string;
  visualDescription: string;
  stateFacts: string[];
};

export type PlannedScene = {
  startParagraphId: string;
  endParagraphId: string;
  salience: number;
  facts: string[];
  entityRefs: string[];
  altText: string;
  caption: string;
  contentTags: string[];
};

/** Strict structured result from the single prose-analysis pass. */
export type NarrativeAnalysis = {
  entityDeltas: EntityDelta[];
  scenes: PlannedScene[];
};

/** Immutable server-side history used to resolve the world at any scene anchor. */
export type WorldRevision = {
  uid: string;
  bookId: string;
  entityId: string;
  kind: WorldEntityKind;
  chapterOrdinal: number;
  paragraphOrdinal: number;
  paragraphId: string;
  name: string;
  aliases: string[];
  summary: string;
  visualDescription: string;
  stateFacts: string[];
  analysisVersion: number;
};

/** Generated artwork that may be reused only after its own story anchor. */
export type WorldReference = {
  entityIds: string[];
  chapterOrdinal: number;
  paragraphOrdinal: number;
  referenceObject: string;
};

/** Persisted recipe makes regeneration deterministic with respect to story time. */
export type SceneGenerationSpec = {
  style: string;
  facts: string[];
  world: WorldSnapshot[];
};
