import type {
  ChapterInput,
  EntityDelta,
  NarrativeAnalysis,
  PlannedScene,
  WorldRevision,
  WorldSnapshot,
} from "./types.js";

const apiKey = process.env.OPENAI_API_KEY ?? "";
const responsesUrl = "https://api.openai.com/v1/responses";
const moderationsUrl = "https://api.openai.com/v1/moderations";
const entityKinds = new Set(["character", "location", "group", "event", "lore"]);

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
        part && typeof part === "object" &&
        (part as { type?: unknown }).type === "output_text" &&
        typeof (part as { text?: unknown }).text === "string"
      ) {
        return (part as { text: string }).text;
      }
    }
  }
  throw new Error("OpenAI response did not contain structured text");
}

function strings(value: unknown, maxItems: number, maxLength: number): value is string[] {
  return Array.isArray(value) && value.length <= maxItems &&
    value.every((item) => typeof item === "string" && item.length <= maxLength);
}

/** Validates anchors and entity references even when Structured Outputs succeeds. */
export function validateNarrativeAnalysis(
  value: unknown,
  chapter: ChapterInput,
  knownWorld: WorldSnapshot[] = [],
): NarrativeAnalysis {
  const root = value && typeof value === "object"
    ? value as { scenes?: unknown; entityDeltas?: unknown }
    : {};
  const paragraphOrdinals = new Map(chapter.paragraphs.map((p) => [p.id, p.ordinal]));
  const knownIds = new Set(knownWorld.map((entity) => entity.entityId));
  const rawDeltas = Array.isArray(root.entityDeltas) ? root.entityDeltas : [];
  const entityDeltas: EntityDelta[] = [];
  const newRefs = new Set<string>();
  for (const raw of rawDeltas) {
    if (!raw || typeof raw !== "object") continue;
    const delta = raw as EntityDelta;
    const validReference = knownIds.has(delta.entityRef) ||
      /^new:[a-z0-9][a-z0-9_-]{0,63}$/.test(delta.entityRef);
    if (
      !validReference || !entityKinds.has(delta.kind) ||
      !paragraphOrdinals.has(delta.anchorParagraphId) ||
      typeof delta.name !== "string" || delta.name.length > 160 ||
      typeof delta.summary !== "string" || delta.summary.length > 500 ||
      typeof delta.visualDescription !== "string" || delta.visualDescription.length > 500 ||
      !strings(delta.aliases, 12, 160) || !strings(delta.stateFacts, 16, 300)
    ) continue;
    if (delta.entityRef.startsWith("new:")) newRefs.add(delta.entityRef);
    entityDeltas.push(delta);
  }

  const allowedRefs = new Set([...knownIds, ...newRefs]);
  const rawScenes = Array.isArray(root.scenes) ? root.scenes : [];
  const scenes: PlannedScene[] = [];
  for (const raw of rawScenes) {
    if (!raw || typeof raw !== "object") continue;
    const scene = raw as PlannedScene;
    const start = paragraphOrdinals.get(scene.startParagraphId);
    const end = paragraphOrdinals.get(scene.endParagraphId);
    if (
      start === undefined || end === undefined || start > end ||
      typeof scene.salience !== "number" || !Number.isFinite(scene.salience) ||
      scene.salience < 0 || scene.salience > 1 ||
      typeof scene.altText !== "string" || scene.altText.length === 0 || scene.altText.length > 500 ||
      typeof scene.caption !== "string" || scene.caption.length > 140 ||
      !strings(scene.facts, 12, 300) || !strings(scene.contentTags, 8, 100) ||
      !strings(scene.entityRefs, 20, 100) ||
      !scene.entityRefs.every((reference) => allowedRefs.has(reference)) ||
      scene.contentTags.includes("unsafe")
    ) continue;
    scenes.push(scene);
  }
  return {
    entityDeltas,
    scenes: scenes
      .sort((a, b) => b.salience - a.salience)
      .slice(0, Math.max(1, Math.min(5, chapter.density + 2))),
  };
}

/**
 * Extracts continuity and scene candidates together. Prose is processed once;
 * downstream image calls receive only the chosen paragraph range.
 */
export async function analyzeNarrative(
  chapter: ChapterInput,
  knownWorld: WorldSnapshot[],
): Promise<NarrativeAnalysis> {
  const paragraphText = chapter.paragraphs.map((p) => `[${p.id}] ${p.text}`).join("\n\n");
  const knownText = knownWorld.length === 0
    ? "none"
    : JSON.stringify(knownWorld.map(({ referenceObject: _referenceObject, ...entity }) => entity));
  const response = await createResponse({
    model: process.env.OPENAI_SCENE_MODEL ?? "gpt-5.6-luna",
    reasoning: { effort: "low" },
    instructions:
      "Analyze this prose once for durable visual continuity and illustration candidates. " +
      "Reuse an exact known entityId when the prose refers to that entity. Otherwise assign a stable " +
      "new:<short_slug> reference and reuse it throughout this response. Emit an entity delta only when " +
      "the passage establishes or changes a name, appearance, clothing, condition, affiliation, location, " +
      "artifact, group, event, or other visually relevant state. Anchor it to the first supplied paragraph " +
      "that establishes the information. Never infer future facts. Rank up to five visually strong scenes, " +
      "using only supplied paragraph IDs and entity references declared or supplied here. End a range only " +
      "after the visual event is disclosed. Use concise paraphrases, never quotations.",
    input:
      `Resource: ${chapter.title ?? chapter.href}\nLanguage: ${chapter.language ?? "unspecified"}` +
      `\nKnown world before this resource: ${knownText}\n\n${paragraphText}`,
    text: {
      format: {
        type: "json_schema",
        name: "narrative_analysis",
        strict: true,
        schema: {
          type: "object",
          additionalProperties: false,
          required: ["entityDeltas", "scenes"],
          properties: {
            entityDeltas: {
              type: "array", maxItems: 100,
              items: {
                type: "object", additionalProperties: false,
                required: ["entityRef", "kind", "anchorParagraphId", "name", "aliases", "summary", "visualDescription", "stateFacts"],
                properties: {
                  entityRef: { type: "string", maxLength: 100 },
                  kind: { type: "string", enum: ["character", "location", "group", "event", "lore"] },
                  anchorParagraphId: { type: "string" },
                  name: { type: "string", maxLength: 160 },
                  aliases: { type: "array", items: { type: "string", maxLength: 160 }, maxItems: 12 },
                  summary: { type: "string", maxLength: 500 },
                  visualDescription: { type: "string", maxLength: 500 },
                  stateFacts: { type: "array", items: { type: "string", maxLength: 300 }, maxItems: 16 },
                },
              },
            },
            scenes: {
              type: "array", maxItems: 5,
              items: {
                type: "object", additionalProperties: false,
                required: ["startParagraphId", "endParagraphId", "salience", "facts", "entityRefs", "altText", "caption", "contentTags"],
                properties: {
                  startParagraphId: { type: "string" },
                  endParagraphId: { type: "string" },
                  salience: { type: "number", minimum: 0, maximum: 1 },
                  facts: { type: "array", items: { type: "string", maxLength: 300 }, maxItems: 12 },
                  entityRefs: { type: "array", items: { type: "string", maxLength: 100 }, maxItems: 20 },
                  altText: { type: "string", maxLength: 500 },
                  caption: { type: "string", maxLength: 140 },
                  contentTags: { type: "array", items: { type: "string", maxLength: 100 }, maxItems: 8 },
                },
              },
            },
          },
        },
      },
    },
  });
  return validateNarrativeAnalysis(JSON.parse(outputText(response)), chapter, knownWorld);
}

/** Reduces append-only revisions into the latest state knowable at an anchor. */
export function resolveWorldSnapshot(
  revisions: WorldRevision[],
  chapterOrdinal: number,
  paragraphOrdinal: number,
): WorldSnapshot[] {
  const ordered = revisions
    .filter((revision) => revision.chapterOrdinal < chapterOrdinal ||
      (revision.chapterOrdinal === chapterOrdinal && revision.paragraphOrdinal <= paragraphOrdinal))
    .sort((left, right) => left.chapterOrdinal - right.chapterOrdinal ||
      left.paragraphOrdinal - right.paragraphOrdinal);
  const snapshots = new Map<string, WorldSnapshot>();
  for (const revision of ordered) {
    const previous = snapshots.get(revision.entityId);
    snapshots.set(revision.entityId, {
      entityId: revision.entityId,
      kind: revision.kind,
      name: revision.name || previous?.name || "",
      aliases: [...new Set([...(previous?.aliases ?? []), ...revision.aliases])],
      summary: revision.summary || previous?.summary || "",
      visualDescription: revision.visualDescription || previous?.visualDescription || "",
      stateFacts: revision.stateFacts.length > 0 ? revision.stateFacts : previous?.stateFacts ?? [],
      referenceObject: previous?.referenceObject,
    });
  }
  return [...snapshots.values()];
}

export function composeImagePrompt(args: {
  style: string;
  sceneText: string;
  facts: string[];
  world: WorldSnapshot[];
}): string {
  const world = args.world.map((entity) =>
    `${entity.kind} ${entity.name}` +
    `${entity.aliases.length > 0 ? ` (also known as ${entity.aliases.join(", ")})` : ""}: ` +
    `${entity.summary}; ${entity.visualDescription}; ${entity.stateFacts.join("; ")}`
  ).join("\n");
  return [
    "Draw a cinematic landscape illustration of this exact novel scene.",
    `Art direction: ${args.style}.`,
    `World state established before this moment:\n${world || "none"}.`,
    `Scene facts: ${args.facts.join("; ")}.`,
    `Source scene: ${args.sceneText}`,
    "The world state is historical: do not add later identities, injuries, relationships, clothing, or transformations.",
    "No text, lettering, captions, interface, border, signature, logo, or watermark.",
  ].join("\n");
}

export interface ImageGenerationProvider {
  generate(prompt: string, referenceImages?: Buffer[]): Promise<Buffer>;
}

/** OpenAI image adapter behind the provider boundary used by the worker. */
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
      if (item && typeof item === "object" &&
        (item as { type?: unknown }).type === "image_generation_call" &&
        typeof (item as { result?: unknown }).result === "string") {
        return Buffer.from((item as { result: string }).result, "base64");
      }
    }
    throw new Error("OpenAI response did not contain an image");
  }
}

export const imageGenerationProvider: ImageGenerationProvider = new OpenAIImageGenerationProvider();

async function moderationFlagged(input: unknown): Promise<boolean> {
  if (!apiKey) throw new Error("OPENAI_API_KEY is not configured");
  const response = await fetch(moderationsUrl, {
    method: "POST",
    headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
    body: JSON.stringify({ model: "omni-moderation-latest", input }),
  });
  if (!response.ok) throw new Error(`OpenAI moderation failed with status ${response.status}`);
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
