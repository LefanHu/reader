import assert from "node:assert/strict";
import test from "node:test";
import { createDecision, selectScenes, type DecisionRequest } from "./scene-selection.js";
import type { ChapterInput } from "./types.js";

const story = (count: number, length = 60) => Array.from({ length: count }, (_, ordinal) => ({
  id: `id${ordinal}`, text: `${"x".repeat(length - 2)}${String(ordinal).padStart(2, "0")}`,
  ordinal, progression: ordinal / count,
}));
const chapterOf = (paragraphs: ChapterInput["paragraphs"], density = 1): ChapterInput => ({
  href: "one.xhtml", profileRevision: 1, density, paragraphs,
});
const recorder = (answer: (body: Record<string, any>, index: number) => unknown) => {
  const bodies: Array<Record<string, any>> = [];
  const request: DecisionRequest = async (body) => answer(body as Record<string, any>, bodies.push(body as Record<string, any>) - 1);
  return { bodies, request };
};

test("copyright-only chapters resolve to none after one request", async () => {
  const { bodies, request } = recorder(() => ({ answers: [{ name: "scene", type: "choice", choice: "none" }] }));
  const chapter = chapterOf([{ id: "c", ordinal: 0, progression: 0,
    text: "Copyright © 2024 Example Press. All rights reserved. No part of this book may be reproduced." }]);
  assert.deepEqual(await selectScenes(chapter, 1, request), []);
  assert.equal(bodies.length, 1);
});

test("scene grows contiguously and stops at the first failing neighbor", async () => {
  const paragraphs = story(8);
  paragraphs[0]!.text = "short";
  const probabilities = [.2, .6, .9, .8, .4, .9];
  const { bodies, request } = recorder((_, index) => index === 0
    ? { answers: [{ name: "scene", type: "choice", choice: "p4" }] }
    : { answers: ["p1", "p2", "p3", "p5", "p6", "p7"].map((name, i) => ({ name, type: "predicate", probability: probabilities[i] })) });
  const result = await selectScenes(chapterOf(paragraphs), 1, request);
  assert.deepEqual(result, [{ startParagraphId: "id2", endParagraphId: "id5" }]);
  assert.deepEqual(bodies[0]!.questions[0].choices.map((c: any) => c.value),
    ["p1", "p2", "p3", "p4", "p5", "p6", "p7", "none"]);
  assert.deepEqual(bodies[1]!.questions.map((q: any) => q.name), ["p1", "p2", "p3", "p5", "p6", "p7"]);
  assert.match(bodies[0]!.input, /^Book section: one\.xhtml\n\n\[p0\] short\n\n\[p1\]/);
});

test("density splits the chapter into equal windows", async () => {
  const { bodies, request } = recorder(() => ({ answers: [{ name: "scene", type: "choice", choice: "none" }] }));
  await selectScenes(chapterOf(story(3), 3), 3, request);
  assert.equal(bodies.length, 3);
});

test("a refusal skips its window", async () => {
  const { request } = recorder(() => ({ answers: [{ name: "scene", type: "refusal" }] }));
  assert.deepEqual(await selectScenes(chapterOf(story(3)), 1, request), []);
});

test("an unsupplied choice is rejected", async () => {
  const { request } = recorder(() => ({ answers: [{ name: "scene", type: "choice", choice: "p99" }] }));
  await assert.rejects(selectScenes(chapterOf(story(3)), 1, request), /Scene selection returned an invalid answer/);
});

test("missing predicate answers are rejected and refusals count as zero", async () => {
  const peak = { name: "scene", type: "choice", choice: "p1" };
  const missing = recorder((_, i) => i === 0 ? { answers: [peak] } : { answers: [] });
  await assert.rejects(selectScenes(chapterOf(story(3)), 1, missing.request), /invalid answer/);
  const refused = recorder((_, i) => i === 0 ? { answers: [peak] }
    : { answers: [{ name: "p0", type: "refusal" }, { name: "p2", type: "predicate", probability: 1 }] });
  assert.deepEqual(await selectScenes(chapterOf(story(3)), 1, refused.request),
    [{ startParagraphId: "id1", endParagraphId: "id2" }]);
});

test("windows without long paragraphs make no request", async () => {
  const { bodies, request } = recorder(() => ({ answers: [] }));
  assert.deepEqual(await selectScenes(chapterOf(story(4, 10)), 1, request), []);
  assert.equal(bodies.length, 0);
});

test("a window offers at most 255 choices", async () => {
  const { bodies, request } = recorder(() => ({ answers: [{ name: "scene", type: "choice", choice: "none" }] }));
  await selectScenes(chapterOf(story(300)), 1, request);
  assert.equal(bodies[0]!.questions[0].choices.length, 255);
});

test("createDecision posts to the Decisions endpoint with a deadline and fails on errors", async (t) => {
  const original = globalThis.fetch;
  const previousKey = process.env.OPENAI_API_KEY;
  t.after(() => { globalThis.fetch = original; process.env.OPENAI_API_KEY = previousKey; });
  process.env.OPENAI_API_KEY = "key";
  let call: { url: string; init: RequestInit } | undefined;
  let status = 200;
  globalThis.fetch = (async (url: string, init: RequestInit) => {
    call = { url, init };
    return new Response(JSON.stringify({ answers: [], usage: { input_tokens: 3 } }), { status });
  }) as typeof fetch;
  assert.deepEqual(await createDecision({ model: "m" }), { answers: [], usage: { input_tokens: 3 } });
  assert.equal(call!.url, "https://api.openai.com/v1/decisions");
  assert.deepEqual(call!.init.headers, { authorization: "Bearer key", "content-type": "application/json" });
  assert(call!.init.signal instanceof AbortSignal);
  status = 400;
  await assert.rejects(createDecision({ model: "m" }), /status 400/);
});
