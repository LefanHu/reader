import assert from "node:assert/strict";
import test from "node:test";
import { composeImagePrompt } from "./openai.js";

test("image prompt contains only the art direction and the selected scene", () => {
  const prompt = composeImagePrompt({
    style: "Painterly fantasy",
    sceneText: "The traveler enters the gate.",
  });
  assert.deepEqual(prompt.split("\n"), [
    "Draw a cinematic landscape illustration of this exact novel scene.",
    "Art direction: Painterly fantasy.",
    "Source scene: The traveler enters the gate.",
    "No text, lettering, captions, interface, border, signature, logo, or watermark.",
  ]);
});
