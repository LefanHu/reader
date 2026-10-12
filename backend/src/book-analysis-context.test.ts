import assert from "node:assert/strict";
import test from "node:test";
import { resolveIllustrationContext, ILLUSTRATION_CONTEXT_MAX_UNITS } from "./book-analysis-context.js";
import { BOOK_ANALYSIS_FIXTURE_SECTIONS, startBookAnalysisFixtureHarness } from "./test-support/book-analysis-fixture.js";
import { composeImagePrompt } from "./openai.js";
import type { IllustrationContext } from "./types.js";
async function finalized() {
  const harness = await startBookAnalysisFixtureHarness();
  const { bookId, generationId } = await harness.admit();
  await harness.extract(generationId, 0);
  await harness.extract(generationId, 1);
  assert.equal((await harness.finalize(generationId)).status, "complete");
  const scene = async (section: number, first: number, last = first) => {
    const text = BOOK_ANALYSIS_FIXTURE_SECTIONS[section]![last]!;
    const sceneStart = harness.fixture.position(section, first), sceneEnd = harness.fixture.position(section, last, text.length);
    return resolveIllustrationContext(harness.memory.firestore, { uid: "owner", bookId, anchor: sceneEnd, sceneStart, sceneEnd });
  };
  return { harness, bookId, generationId, scene };
}
const facts = (context: IllustrationContext | null) =>
  (context?.facts ?? []).map(fact => `${fact.property}=${fact.value}`);
test("earlier scenes use vetted dark-sky baseline but no later character, artifact, alias or daylight facts", async () => {
  const { harness, scene } = await finalized();
  try {
    const early = await scene(0, 0, 1);
    assert(early);
    const seen = facts(early);
    assert(seen.includes("hair=long braid") && seen.includes("uniform=blue uniforms"));
    assert(seen.includes("sky=permanent dark sky"), "retroactive world baseline applies before it was revealed");
    for (const hidden of ["hair=short hair", "uniform=red uniforms", "sky=daylight", "appearance=silver with etched wings", "appearance=golden", "appearance=black"]) {
      assert(!seen.includes(hidden), hidden);
    }
    assert(!early.subjects.some(s => s.names.includes("Raven")), "a later alias is not an earlier label");
    assert(JSON.stringify(early).length <= ILLUSTRATION_CONTEXT_MAX_UNITS);
    // The prompt keeps the scene as the action source and presents facts as separate evidence.
    const prompt = composeImagePrompt({ style: "Ink", sceneText: "Scene.", context: early });
    assert(prompt.includes("sky: permanent dark sky") && prompt.includes("Source scene: Scene."));
  } finally { await harness.close(); }
});

test("a haircut supersedes the braid only from its own time and does not backdate", async () => {
  const { harness, scene } = await finalized();
  try {
    const haircut = await scene(1, 1);
    const seen = facts(haircut);
    assert(seen.includes("hair=short hair"));
    assert(!seen.includes("hair=long braid"), "explicitly superseded fact ends at the change");
    assert(!haircut?.subjects.some(s => s.names.includes("Raven")));
    const early = facts(await scene(0, 0));
    assert(!early.includes("hair=short hair"));
  } finally { await harness.close(); }
});

test("returned daylight ends the dark-sky interval and uncertain chronology never becomes a default", async () => {
  const { harness, scene } = await finalized();
  try {
    const daybreak = facts(await scene(1, 3));
    assert(daybreak.includes("sky=daylight") && !daybreak.includes("sky=permanent dark sky"));
    // The flashback is incomparable with the haircut, so nothing applies to a scene with only that time.
    const flashback = await scene(1, 4);
    assert.deepEqual(flashback?.facts ?? [], []);
    // Artifact truth is limited to scenes at or after its reveal; the uncertain rumor never applies.
    const reveal = facts(await scene(1, 5));
    assert(reveal.includes("appearance=silver with etched wings") && !reveal.includes("appearance=black"));
  } finally { await harness.close(); }
});

test("missing or non-finalized analysis yields no context", async () => {
  const harness = await startBookAnalysisFixtureHarness();
  try {
    const { bookId } = await harness.admit();
    const sceneStart = harness.fixture.position(0, 0);
    assert.equal(await resolveIllustrationContext(harness.memory.firestore, { uid: "owner", bookId, anchor: sceneStart, sceneStart, sceneEnd: sceneStart }), null);
  } finally { await harness.close(); }
});
