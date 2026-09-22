import type { ChapterInput, PlannedScene, VisualBibleEntry } from "./types.js";

const apiKey = process.env.OPENAI_API_KEY ?? "";
const responsesUrl = "https://api.openai.com/v1/responses";
const moderationsUrl = "https://api.openai.com/v1/moderations";

async function createResponse(body: Record<string, unknown>): Promise<Record<string, unknown>> {
  if (!apiKey) throw new Error("OPENAI_API_KEY is not configured");
  const startedAt = Date.now();
  const response = await fetch(responsesUrl, {
    method: "POST",
    headers: {
      authorization: `Bearer ${apiKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({ ...body, store: false }),
  });
  if (!response.ok) {
    // Never include the response body: provider errors can echo prompt text.
    console.error(JSON.stringify({
      category: "openai",
      status: response.status,
      latencyMs: Date.now() - startedAt,
    }));
    throw new Error(`OpenAI request failed with status ${response.status}`);
  }
  const result = (await response.json()) as Record<string, unknown>;
  const usage = result.usage && typeof result.usage === "object"
    ? result.usage as Record<string, unknown>
    : {};
  console.info(JSON.stringify({
    category: "openai",
    status: "success",
    latencyMs: Date.now() - startedAt,
    inputTokens: usage.input_tokens,
    outputTokens: usage.output_tokens,
  }));
  return result;
}

function outputText(response: Record<string, unknown>): string {
  const output = Array.isArray(response.output) ? response.output : [];
  for (const item of output) {
    if (!item || typeof item !== "object") continue;
    const content = Array.isArray((item as { content?: unknown }).content)
      ? (item as { content: unknown[] }).content
      : [];
    for (const part of content) {
      if (
        part &&
        typeof part === "object" &&
        (part as { type?: unknown }).type === "output_text" &&
        typeof (part as { text?: unknown }).text === "string"
      ) {
        return (part as { text: string }).text;
      }
    }
  }
  throw new Error("OpenAI response did not contain structured text");
}

export function validatePlannedScenes(
  value: unknown,
  chapter: ChapterInput,
): PlannedScene[] {
  const root = value && typeof value === "object" ? value as { scenes?: unknown } : {};
  const scenes = Array.isArray(root.scenes) ? root.scenes : [];
  const ordinals = new Map(chapter.paragraphs.map((p) => [p.id, p.ordinal]));
  const valid: PlannedScene[] = [];
  for (const raw of scenes) {
    if (!raw || typeof raw !== "object") continue;
    const scene = raw as PlannedScene;
    if (
      typeof scene.startParagraphId !== "string" ||
      typeof scene.endParagraphId !== "string" ||
      typeof scene.salience !== "number" ||
      !Number.isFinite(scene.salience) ||
      scene.salience < 0 ||
      scene.salience > 1 ||
      typeof scene.altText !== "string" ||
      scene.altText.length === 0 ||
      scene.altText.length > 500 ||
      typeof scene.caption !== "string" ||
      scene.caption.length > 140
    ) continue;
    const start = ordinals.get(scene.startParagraphId);
    const end = ordinals.get(scene.endParagraphId);
    if (start === undefined || end === undefined || start > end) continue;
    if (!Array.isArray(scene.facts) || !Array.isArray(scene.contentTags)) continue;
    if (!Array.isArray(scene.continuityDeltas)) continue;
    if (![...scene.facts, ...scene.contentTags, ...scene.continuityDeltas]
      .every((item) => typeof item === "string")) continue;
    if (scene.contentTags.includes("unsafe")) continue;
    valid.push(scene);
  }
  return valid
    .sort((a, b) => b.salience - a.salience)
    // Keep two ranked fallbacks internal to the worker. Only up to the
    // confirmed density are ever committed as client-visible scene records.
    .slice(0, Math.max(1, Math.min(5, chapter.density + 2)));
}

export async function planScenes(chapter: ChapterInput): Promise<PlannedScene[]> {
  const paragraphText = chapter.paragraphs
    .map((p) => `[${p.id}] ${p.text}`)
    .join("\n\n");
  const response = await createResponse({
    model: process.env.OPENAI_SCENE_MODEL ?? "gpt-5.6-luna",
    reasoning: { effort: "low" },
    instructions:
      "Rank up to five visually strong, narratively meaningful candidate scenes from the supplied chapter; " +
      "only the top safe candidates will be committed, with an absolute maximum of three. " +
      "Use only supplied paragraph IDs. End each range after the visual event is fully disclosed. " +
      "Avoid abstract dialogue-only moments, duplicated beats, explicit sexual imagery, graphic gore, " +
      "and any facts not present in the selected range. Mark an unrenderable candidate with contentTags=['unsafe']. " +
      "Facts and continuity deltas must be concise paraphrases, never quotations.",
    input: `Chapter: ${chapter.title ?? chapter.href}\nLanguage: ${chapter.language ?? "unspecified"}\n\n${paragraphText}`,
    text: {
      format: {
        type: "json_schema",
        name: "chapter_scenes",
        strict: true,
        schema: {
          type: "object",
          additionalProperties: false,
          required: ["scenes"],
          properties: {
            scenes: {
              type: "array",
              maxItems: 5,
              items: {
                type: "object",
                additionalProperties: false,
                required: [
                  "startParagraphId", "endParagraphId", "salience", "facts",
                  "altText", "caption", "contentTags", "continuityDeltas",
                ],
                properties: {
                  startParagraphId: { type: "string" },
                  endParagraphId: { type: "string" },
                  salience: { type: "number", minimum: 0, maximum: 1 },
                  facts: { type: "array", items: { type: "string" }, maxItems: 12 },
                  altText: { type: "string", maxLength: 500 },
                  caption: { type: "string", maxLength: 140 },
                  contentTags: { type: "array", items: { type: "string" }, maxItems: 8 },
                  continuityDeltas: { type: "array", items: { type: "string" }, maxItems: 10 },
                },
              },
            },
          },
        },
      },
    },
  });
  return validatePlannedScenes(JSON.parse(outputText(response)), chapter);
}

export function composeImagePrompt(args: {
  style: string;
  sceneText: string;
  facts: string[];
  visualBible: VisualBibleEntry[];
}): string {
  const established = args.visualBible.map((entry) => entry.fact).join("; ");
  return [
    "Draw a cinematic landscape illustration of this exact novel scene.",
    `Art direction: ${args.style}.`,
    `Established visual continuity: ${established || "none yet"}.`,
    `Scene facts: ${args.facts.join("; ")}.`,
    `Source scene: ${args.sceneText}`,
    "Show no event, transformation, object, injury, relationship, or costume not disclosed in the source scene.",
    "No text, lettering, captions, interface, border, signature, logo, or watermark.",
  ].join("\n");
}

export interface ImageGenerationProvider {
  generate(prompt: string, referenceImages?: Buffer[]): Promise<Buffer>;
}

/// OpenAI image adapter; another provider can be injected without changing
/// job, credit, spoiler, or persistence behavior.
export class OpenAIImageGenerationProvider implements ImageGenerationProvider {
  async generate(prompt: string, referenceImages: Buffer[] = []): Promise<Buffer> {
    const content: Array<Record<string, unknown>> = [
      { type: "input_text", text: prompt },
      ...referenceImages.map((image) => ({
        type: "input_image",
        image_url: `data:image/webp;base64,${image.toString("base64")}`,
      })),
    ];
    const response = await createResponse({
      // Image tools require a supported mainline orchestrator model; scene
      // planning remains independently pinned to the cost-sensitive model.
      model: process.env.OPENAI_IMAGE_ORCHESTRATOR_MODEL ?? "gpt-5.5",
      input: [{ role: "user", content }],
      tools: [{
        type: "image_generation",
        model: process.env.OPENAI_IMAGE_MODEL ?? "gpt-image-2.5-flare",
        action: referenceImages.length > 0 ? "auto" : "generate",
        size: "1536x1024",
        quality: "high",
        output_format: "webp",
        background: "opaque",
        moderation: "auto",
      }],
      tool_choice: { type: "image_generation" },
    });
    const output = Array.isArray(response.output) ? response.output : [];
    for (const item of output) {
      if (
        item && typeof item === "object" &&
        (item as { type?: unknown }).type === "image_generation_call" &&
        typeof (item as { result?: unknown }).result === "string"
      ) {
        return Buffer.from((item as { result: string }).result, "base64");
      }
    }
    throw new Error("OpenAI response did not contain an image");
  }
}

export const imageGenerationProvider: ImageGenerationProvider =
  new OpenAIImageGenerationProvider();

async function moderationFlagged(input: unknown): Promise<boolean> {
  if (!apiKey) throw new Error("OPENAI_API_KEY is not configured");
  const response = await fetch(moderationsUrl, {
    method: "POST",
    headers: {
      authorization: `Bearer ${apiKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({ model: "omni-moderation-latest", input }),
  });
  if (!response.ok) {
    throw new Error(`OpenAI moderation failed with status ${response.status}`);
  }
  const body = await response.json() as { results?: Array<{ flagged?: boolean }> };
  return body.results?.some((result) => result.flagged === true) ?? true;
}

export function moderateText(text: string): Promise<boolean> {
  return moderationFlagged([{ type: "text", text }]);
}

export function moderateImage(image: Buffer): Promise<boolean> {
  return moderationFlagged([{
    type: "image_url",
    image_url: { url: `data:image/webp;base64,${image.toString("base64")}` },
  }]);
}
