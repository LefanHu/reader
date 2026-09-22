import assert from "node:assert/strict";
import test from "node:test";
import { validatePlannedScenes } from "./openai.js";

test("scene validation rejects invented and reversed paragraph ranges", () => {
  const chapter = {
    href: "one.xhtml",
    styleVersion: 1,
    density: 3,
    paragraphs: [
      { id: "a", text: "A", cssSelector: "p:nth-of-type(1)", ordinal: 0, progression: 0 },
      { id: "b", text: "B", cssSelector: "p:nth-of-type(2)", ordinal: 1, progression: 1 },
    ],
  };
  const base = {
    salience: 0.8,
    facts: ["A fact"],
    altText: "Alt",
    caption: "Caption",
    contentTags: [],
    continuityDeltas: [],
  };
  const result = validatePlannedScenes({ scenes: [
    { ...base, startParagraphId: "a", endParagraphId: "b" },
    { ...base, startParagraphId: "b", endParagraphId: "a" },
    { ...base, startParagraphId: "a", endParagraphId: "missing" },
  ] }, chapter);
  assert.equal(result.length, 1);
  assert.equal(result[0]?.endParagraphId, "b");
});
