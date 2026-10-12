import assert from "node:assert/strict";
import test from "node:test";
import { ImageProviderRegistry } from "../image-provider-registry.js";
import { snapshotImageGenerationConfig } from "../illustration-configuration.js";
import { renderPromptImage } from "../image-test-provider.js";
import { imageProviderFixture, tinyLandscapeImages } from "../test-support/image-provider-fixture.js";
import { DiagnosticImageProvider } from "./diagnostic-image-provider.js";

const prompt = "Draw a cinematic landscape illustration.\nArt direction: Ink.";
const service = "https://reader-dev-image-test-abc123-ue.a.run.app";
const idToken = async (audience: string) => `token-for-${audience}`;

test("diagnostic source sends the exact prompt with an audience-bound ID token and returns the rendered PNG", async t => {
  const png = await renderPromptImage(prompt, 1);
  const fixture = await imageProviderFixture(() => ({ body: { mimeType: "image/png", data: png.toString("base64") } }));
  t.after(fixture.close);
  const images = await tinyLandscapeImages();
  const registry = new ImageProviderRegistry({
    diagnostic: new DiagnosticImageProvider(service, { ...fixture.httpOptions, idToken }),
  });
  const result = await registry.generate(snapshotImageGenerationConfig("diagnostic"), prompt, [{ bytes: images.png, mimeType: "image/png" }]);
  assert.deepEqual(result.bytes, png);
  assert.equal(result.mimeType, "image/png");
  assert.equal(fixture.requests.length, 1);
  const request = fixture.requests[0]!;
  assert.equal(request.url, `${service}/render`);
  assert.equal(request.headers.get("authorization"), `Bearer token-for-${service}`);
  assert.deepEqual(request.body, { prompt, referenceCount: 1 });
});

test("diagnostic source rejects unsafe service URLs before any request", async t => {
  const fixture = await imageProviderFixture(() => ({ body: {} }));
  t.after(fixture.close);
  for (const url of ["", "http://x.run.app", "https://example.com", "https://user:pw@x.run.app", "https://x.run.app:8443", "https://x.run.app/#f"]) {
    const provider = new DiagnosticImageProvider(url, { ...fixture.httpOptions, idToken });
    await assert.rejects(provider.validateCredentials(), /unavailable/);
    await assert.rejects(provider.generate(snapshotImageGenerationConfig("diagnostic"), prompt));
  }
  assert.equal(fixture.requests.length, 0);
});

test("diagnostic source fails closed on a missing token, bad payloads, wrong MIME and server errors without retrying", async t => {
  const png = await renderPromptImage(prompt, 0);
  const cases = [
    { body: { mimeType: "image/png" } },
    { body: { mimeType: "image/jpeg", data: png.toString("base64") } },
    { status: 500, body: { error: "boom" } },
  ];
  for (const reply of cases) {
    const fixture = await imageProviderFixture(() => reply);
    t.after(fixture.close);
    const provider = new DiagnosticImageProvider(service, { ...fixture.httpOptions, idToken });
    await assert.rejects(provider.generate(snapshotImageGenerationConfig("diagnostic"), prompt));
    assert.equal(fixture.requests.length, 1);
  }
  const noToken = new DiagnosticImageProvider(service, { idToken: async () => "" });
  await assert.rejects(noToken.validateCredentials());
});
