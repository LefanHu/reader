export type Paragraph = {
  id: string;
  text: string;
  cssSelector: string;
  ordinal: number;
  progression: number;
};

export type ChapterInput = {
  href: string;
  title?: string;
  language?: string;
  styleVersion: number;
  density: number;
  paragraphs: Paragraph[];
};

export type PlannedScene = {
  startParagraphId: string;
  endParagraphId: string;
  salience: number;
  facts: string[];
  altText: string;
  caption: string;
  contentTags: string[];
  continuityDeltas: string[];
};

export type VisualBibleEntry = {
  chapterOrdinal: number;
  paragraphOrdinal: number;
  fact: string;
  referenceObject?: string;
};
