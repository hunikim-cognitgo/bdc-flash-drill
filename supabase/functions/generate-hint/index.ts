// Supabase Edge Function — generate-hint
//
// Returns a hint for a drill question that nudges the rep toward the answer
// without revealing it. Tailored per question type (MC vs typed).
//
// Request body:
//   {
//     question_prompt:  string,    // the question
//     canonical_answer: string,    // the correct answer (so we know what NOT to reveal)
//     category?:        string,    // e.g. "Script — Opening"
//     type?:            string     // e.g. "type-from-memory" | "situation-recognition"
//   }
//
// Response body: { hint: string }
//
// Required Supabase secret: ANTHROPIC_API_KEY

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const MODEL = "claude-haiku-4-5";
const MAX_TOKENS = 256;

const SYSTEM_PROMPT =
  `You generate hints for sales reps stuck on training-drill questions in a BDC (Business Development Center). The drill covers: script recall (typed from memory), situation recognition (multiple choice), framework selection (multiple choice), and "catch the violation" exercises.

A GOOD HINT:
- Nudges thinking toward the answer (structure, framework name, principle)
- Names the relevant concept category if useful ("this is a JOLT/AER/FFF situation", "think about the three steps of...")
- Stays under 2 sentences
- Does NOT restate the canonical answer in different words
- For multiple choice: does NOT identify the correct option, even by elimination

A BAD HINT:
- Lightly paraphrases the canonical answer
- Lists the load-bearing concepts verbatim
- For MC: says "it's not option 1 or 3"

You'll be given the question, the canonical answer (so you know what to NOT reveal), the category, and the question type. Generate a hint that helps the rep think — not one that solves the question.

Return JSON only, no preamble or markdown fences.`;

interface HintRequest {
  question_prompt: string;
  canonical_answer: string;
  category?: string;
  type?: string;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) {
    return json({ error: "ANTHROPIC_API_KEY secret is not set" }, 500);
  }

  let body: HintRequest;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const { question_prompt, canonical_answer, category, type } = body;
  if (!question_prompt || !canonical_answer) {
    return json(
      { error: "Required: question_prompt, canonical_answer" },
      400,
    );
  }

  const userMessage = `Question: ${question_prompt}

Canonical answer (do NOT reveal this verbatim or in light paraphrase): ${canonical_answer}

Category: ${category || "general"}
Question type: ${type || "unknown"}

Generate a hint that helps the rep think toward the answer without solving it for them.`;

  const claudeRequest = {
    model: MODEL,
    max_tokens: MAX_TOKENS,
    system: SYSTEM_PROMPT,
    messages: [{ role: "user", content: userMessage }],
    output_config: {
      format: {
        type: "json_schema",
        schema: {
          type: "object",
          properties: {
            hint: {
              type: "string",
              description:
                "1-2 sentence hint, under 200 chars, that does not reveal the canonical answer.",
            },
          },
          required: ["hint"],
          additionalProperties: false,
        },
      },
    },
  };

  let claudeResp: Response;
  try {
    claudeResp = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify(claudeRequest),
    });
  } catch (e) {
    return json(
      { error: "Network error calling Claude", details: String(e) },
      502,
    );
  }

  if (!claudeResp.ok) {
    const errBody = await claudeResp.text();
    return json(
      { error: "Claude API error", status: claudeResp.status, details: errBody },
      502,
    );
  }

  const data = await claudeResp.json();
  const textBlock = data.content?.find((b: { type: string }) =>
    b.type === "text"
  );
  if (!textBlock?.text) {
    return json({ error: "Claude response missing text block", raw: data }, 502);
  }

  try {
    const result = JSON.parse(textBlock.text);
    return json(result);
  } catch {
    return json(
      { error: "Failed to parse Claude JSON response", text: textBlock.text },
      502,
    );
  }
});
