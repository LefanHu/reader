import assert from "node:assert/strict";
import test from "node:test";
import sharp from "sharp";
import { validateGeneratedImage } from "./image-generation.js";
import { createImageTestProviderApp, layoutPrompt, renderPromptImage } from "./image-test-provider.js";

test("render is a valid deterministic 3:2 PNG the pipeline validator accepts", async () => {
  const first = await renderPromptImage("Draw a scene\nArt direction: Ink", 1);
  const metadata = await sharp(first).metadata();
  assert.deepEqual([metadata.format, metadata.width, metadata.height], ["png", 1536, 1024]);
  assert.equal((await validateGeneratedImage(first, "image/png")).mimeType, "image/png");
  assert.deepEqual(await renderPromptImage("Draw a scene\nArt direction: Ink", 1), first);
});

test("long prompts truncate with an exact unrendered-character count and still render", async () => {
  const prompt = "x".repeat(20_000);
  const lines = layoutPrompt(prompt);
  assert.equal(lines.length, 36);
  const shown = 35 * 108;
  assert.equal(lines.at(-1), `… [truncated ${20_000 - shown} more characters]`);
  assert.equal((await sharp(await renderPromptImage(prompt, 0)).metadata()).height, 1024);
});

test("newlines are kept, long lines wrap at 108 columns and markup is inert", async () => {
  assert.deepEqual(layoutPrompt("a\n\nb"), ["a", "", "b"]);
  assert.deepEqual(layoutPrompt("y".repeat(109)).map(line => line.length), [108, 1]);
  assert.equal((await sharp(await renderPromptImage("<script>&\"'\u0000\ud800</script>", 2)).metadata()).width, 1536);
});

test("HTTP contract returns base64 PNG and rejects malformed requests without rendering", async t => {
  const server = createImageTestProviderApp().listen(0, "127.0.0.1");
  await new Promise<void>(resolve => server.on("listening", resolve));
  t.after(() => new Promise<void>(resolve => server.close(() => resolve())));
  const address = server.address();
  assert(address && typeof address === "object");
  const post = (body: string) => fetch(`http://127.0.0.1:${address.port}/render`, {
    method: "POST", headers: { "content-type": "application/json" }, body,
  });
  const ok = await post(JSON.stringify({ prompt: "hello", referenceCount: 0 }));
  assert.equal(ok.status, 200);
  const payload = await ok.json() as { mimeType: string; data: string };
  assert.equal(payload.mimeType, "image/png");
  assert.equal((await sharp(Buffer.from(payload.data, "base64")).metadata()).width, 1536);
  for (const bad of [
    JSON.stringify({ referenceCount: 0 }),
    JSON.stringify({ prompt: "x".repeat(50_001), referenceCount: 0 }),
    JSON.stringify({ prompt: "x", referenceCount: 3 }),
    "not json",
  ]) assert.equal((await post(bad)).status, 400, bad.slice(0, 30));
  assert.equal((await fetch(`http://127.0.0.1:${address.port}/health`)).status, 200);
});
