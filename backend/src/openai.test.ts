import assert from "node:assert/strict";
import test from "node:test";
import {
  composeImagePrompt,
  resolveWorldSnapshot,
  validateNarrativeAnalysis,
} from "./openai.js";
import type { ChapterInput, WorldRevision } from "./types.js";

const chapter: ChapterInput = {
  href: "one.xhtml",
  styleVersion: 1,
  analysisVersion: 2,
  density: 3,
  paragraphs: [
    { id: "a", text: "A", cssSelector: "p:nth-of-type(1)", ordinal: 0, progression: 0 },
    { id: "b", text: "B", cssSelector: "p:nth-of-type(2)", ordinal: 1, progression: 1 },
  ],
};

test("narrative validation rejects invented entities and reversed scene ranges", () => {
  const delta = {
    entityRef: "new:hero",
    kind: "character",
    anchorParagraphId: "a",
    name: "Hero",
    aliases: [],
    summary: "A traveler",
    visualDescription: "Dark hair",
    stateFacts: ["Wears a grey cloak"],
  };
  const scene = {
    startParagraphId: "a",
    endParagraphId: "b",
    salience: 0.8,
    facts: ["The traveler arrives"],
    entityRefs: ["new:hero"],
    altText: "A traveler arrives",
    caption: "Arrival",
    contentTags: [],
  };
  const result = validateNarrativeAnalysis({
    entityDeltas: [delta],
    scenes: [
      scene,
      { ...scene, startParagraphId: "b", endParagraphId: "a" },
      { ...scene, entityRefs: ["invented-id"] },
    ],
  }, chapter);
  assert.equal(result.entityDeltas.length, 1);
  assert.equal(result.scenes.length, 1);
});

test("world snapshots exclude revisions established after the scene anchor", () => {
  const revisions: WorldRevision[] = [
    {
      uid: "u", bookId: "book", entityId: "hero", kind: "character",
      chapterOrdinal: 0, paragraphOrdinal: 0, paragraphId: "a",
      name: "The traveler", aliases: [], summary: "An unknown traveler",
      visualDescription: "Dark hair", stateFacts: ["Wears a grey cloak"], analysisVersion: 2,
    },
    {
      uid: "u", bookId: "book", entityId: "hero", kind: "character",
      chapterOrdinal: 2, paragraphOrdinal: 4, paragraphId: "later",
      name: "Emperor Jian", aliases: ["The traveler"], summary: "The hidden emperor",
      visualDescription: "A fresh facial scar", stateFacts: ["Wears imperial robes"], analysisVersion: 2,
    },
  ];
  const early = resolveWorldSnapshot(revisions, 1, 3);
  assert.equal(early[0]?.name, "The traveler");
  assert.equal(early[0]?.visualDescription, "Dark hair");
  const later = resolveWorldSnapshot(revisions, 2, 4);
  assert.equal(later[0]?.name, "Emperor Jian");
  assert.deepEqual(later[0]?.aliases, ["The traveler"]);
});

test("image prompt contains a bounded scene and resolved historical world", () => {
  const prompt = composeImagePrompt({
    style: "Painterly fantasy",
    sceneText: "The traveler enters the gate.",
    facts: ["It is night"],
    world: [{
      entityId: "hero", kind: "character", name: "The traveler", aliases: [],
      summary: "Unknown traveler", visualDescription: "Dark hair",
      stateFacts: ["Wears a grey cloak"],
    }],
  });
  assert.match(prompt, /The traveler/);
  assert.match(prompt, /grey cloak/);
  assert.doesNotMatch(prompt, /Emperor Jian/);
});
