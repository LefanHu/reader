import type { ImageMimeType } from "./image-generation.js";
import type { IllustrationContext } from "./types.js";

const moderationsUrl = "https://api.openai.com/v1/moderations";

/** Supported facts are separate evidence; the depicted scene remains the only action source. */
export function composeImagePrompt(args: { style: string; sceneText: string; context?: IllustrationContext }): string {
  const facts = args.context?.facts ?? [];
  const subjects = (args.context?.subjects ?? []).filter(subject => subject.names.length > 0);
  return [
    "Draw a cinematic landscape illustration of this exact novel scene.",
    `Art direction: ${args.style}.`,
    ...(facts.length || subjects.length ? [
      "Established story context that already applies at this moment (visual evidence only; never depict later events or reveal anything not stated here):",
      ...subjects.map(subject => `- ${subject.kind} known as ${subject.names.join(" / ")}`),
      ...facts.map(fact => `- ${fact.subject} ${fact.property}: ${fact.value}${fact.object ? ` (${fact.object})` : ""}`),
    ] : []),
    `Source scene: ${args.sceneText}`,
    "No text, lettering, captions, interface, border, signature, logo, or watermark.",
  ].join("\n");
}

async function moderationFlagged(input: unknown): Promise<boolean> {
  const apiKey = process.env.OPENAI_API_KEY ?? "";
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

export function moderateImage(image: Buffer, mimeType: ImageMimeType): Promise<boolean> {
  return moderationFlagged([{
    type: "image_url",
    image_url: { url: `data:${mimeType};base64,${image.toString("base64")}` },
  }]);
}
