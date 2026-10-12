import type { ChapterInput, Paragraph } from "./types.js";

const decisionsUrl = "https://api.openai.com/v1/decisions";
/** Shorter paragraphs (headings, one-liners) are context only, never a scene peak. */
const MIN_CANDIDATE_CHARACTERS = 40;
/** The Decisions API allows 255 choices; one slot is reserved for `none`. */
const MAX_CHOICES = 254;
const NEIGHBOR_RADIUS = 3;
const SAME_SCENE_THRESHOLD = 0.5;

/** Inclusive paragraph range of one illustrated scene; the anchor is the end paragraph. */
export type SelectedScene = { startParagraphId: string; endParagraphId: string };

/** Injectable transport so tests can fake answers without network access. */
export type DecisionRequest = (body: Record<string, unknown>) => Promise<unknown>;

export const createDecision: DecisionRequest = async (body) => {
  const apiKey = process.env.OPENAI_API_KEY ?? "";
  if (!apiKey) throw new Error("OPENAI_API_KEY is not configured");
  const startedAt = Date.now();
  const response = await fetch(decisionsUrl, {
    method: "POST",
    headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    // Never include the response body: provider errors can echo prompt text.
    console.error(JSON.stringify({
      category: "openai_decisions", status: response.status, latencyMs: Date.now() - startedAt,
    }));
    throw new Error(`OpenAI decisions request failed with status ${response.status}`);
  }
  const result = (await response.json()) as Record<string, unknown>;
  const usage = result.usage && typeof result.usage === "object"
    ? result.usage as Record<string, unknown> : {};
  console.info(JSON.stringify({
    category: "openai_decisions", status: "success", latencyMs: Date.now() - startedAt,
    inputTokens: usage.input_tokens,
  }));
  return result;
};

type Answer = { name?: unknown; type?: unknown; choice?: unknown; probability?: unknown };

function answersOf(response: unknown): Answer[] {
  const answers = (response as { answers?: unknown } | null)?.answers;
  return Array.isArray(answers) ? answers.filter((a): a is Answer => !!a && typeof a === "object") : [];
}

function invalidAnswer(): Error {
  return new Error("Scene selection returned an invalid answer");
}

/**
 * Picks at most one scene per equal-text window: one choice request finds the
 * visual peak (or none), one predicate request grows it over adjacent paragraphs.
 */
export async function selectScenes(
  chapter: ChapterInput,
  windows: number,
  request: DecisionRequest = createDecision,
): Promise<SelectedScene[]> {
  const total = chapter.paragraphs.reduce((sum, p) => sum + p.text.length, 0);
  if (total === 0 || windows < 1) return [];
  const buckets: Paragraph[][] = Array.from({ length: windows }, () => []);
  let offset = 0;
  for (const paragraph of chapter.paragraphs) {
    buckets[Math.min(windows - 1, Math.floor(offset * windows / total))]!.push(paragraph);
    offset += paragraph.text.length;
  }
  const model = process.env.OPENAI_SCENE_MODEL ?? "gpt-6-luna";
  let requests = 0;
  const send: DecisionRequest = (body) => { requests++; return request(body); };

  const results = await Promise.all(buckets.map(async (bucket): Promise<SelectedScene | null> => {
    if (bucket.length === 0) return null;
    let candidates = bucket.filter((p) => p.text.trim().length >= MIN_CANDIDATE_CHARACTERS);
    if (candidates.length === 0) return null;
    if (candidates.length > MAX_CHOICES) {
      candidates = [...candidates].sort((a, b) => b.text.length - a.text.length)
        .slice(0, MAX_CHOICES).sort((a, b) => a.ordinal - b.ordinal);
    }
    const input = [`Book section: ${chapter.title ?? chapter.href}`,
      ...bucket.map((p) => `[p${p.ordinal}] ${p.text}`)].join("\n\n");
    const values = candidates.map((p) => `p${p.ordinal}`);
    const peak = answersOf(await send({
      model, input,
      questions: [{
        type: "choice", name: "scene",
        instructions: "Which labeled paragraph is the visual peak of the most visually striking story scene in this text: a moment an illustrator could draw, such as characters acting in a described place or a vivid physical event? Answer none if the text is book apparatus (copyright or license notice, publishing information, title page, table of contents, dedication, acknowledgements, notes, index) or has no drawable story moment.",
        choices: [...values.map((value) => ({ value })),
          { value: "none", description: "No drawable story scene in this text." }],
      }],
    }))[0];
    if (peak?.type === "refusal") return null;
    if (peak?.type !== "choice" || typeof peak.choice !== "string" ||
        (peak.choice !== "none" && !values.includes(peak.choice))) throw invalidAnswer();
    if (peak.choice === "none") return null;
    const center = candidates[values.indexOf(peak.choice)]!;
    const c = center.ordinal;

    const neighbors = bucket.filter((p) =>
      p.ordinal !== c && p.ordinal >= c - NEIGHBOR_RADIUS && p.ordinal <= c + NEIGHBOR_RADIUS);
    const probability = new Map<number, number>();
    if (neighbors.length > 0) {
      const answers = answersOf(await send({
        model, input,
        questions: neighbors.map((p) => ({
          type: "predicate", name: `p${p.ordinal}`,
          instructions: `Is paragraph [p${p.ordinal}] part of the same scene as paragraph [p${c}]: the same moment, place and characters?`,
        })),
      }));
      for (const p of neighbors) {
        const answer = answers.find((a) => a.name === `p${p.ordinal}`);
        if (!answer) throw invalidAnswer();
        if (answer.type === "refusal") { probability.set(p.ordinal, 0); continue; }
        const value = answer.probability;
        if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > 1) throw invalidAnswer();
        probability.set(p.ordinal, value);
      }
    }
    // Growth stops at the first failing neighbor, keeping the scene contiguous.
    const same = (ordinal: number) => (probability.get(ordinal) ?? 0) >= SAME_SCENE_THRESHOLD;
    const byOrdinal = new Map(bucket.map((p) => [p.ordinal, p]));
    let start = c, end = c;
    while (byOrdinal.has(start - 1) && same(start - 1)) start--;
    while (byOrdinal.has(end + 1) && same(end + 1)) end++;
    return { startParagraphId: byOrdinal.get(start)!.id, endParagraphId: byOrdinal.get(end)!.id };
  }));

  const selected = results.filter((scene): scene is SelectedScene => scene !== null);
  console.info(JSON.stringify({ category: "scene_selection", windows, selected: selected.length, requests }));
  return selected;
}
