// Supabase Edge Function — grade-answer
//
// Grades typed BDC drill answers via Claude Haiku 4.5. Replaces the brittle
// keyword-substring grader on the client with a model that understands
// paraphrasing, synonyms, and natural variation.
//
// Request body:
//   {
//     question_prompt:  string,    // the question the rep was asked
//     canonical_answer: string,    // the "ideal" answer
//     key_concepts:     string[],  // load-bearing concepts the answer should hit
//     rep_answer:       string     // what the rep actually typed
//   }
//
// Response body:
//   {
//     pass:              boolean,   // true if score >= 60
//     score:             number,    // 0-100, how well the rep captured the concepts
//     feedback:          string,    // one short sentence addressed to the rep
//     missing_concepts:  string[]   // concepts from the input list the rep didn't cover
//   }
//
// Required Supabase secret: ANTHROPIC_API_KEY

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const MODEL = "claude-haiku-4-5";
const MAX_TOKENS = 512;
const MAX_REP_ANSWER_LEN = 5000;

const SYSTEM_PROMPT =
  `You grade sales reps' typed answers in a BDC (Business Development Center) sales-training drill. Decide whether the rep's answer demonstrates they understand the core concepts — NOT whether they used exact wording.

GRADING PRINCIPLES:
- Be generous but honest. Reps don't need perfect wording — they need to show they GET it.
- Paraphrasing, synonyms, and natural-sounding variations should pass.
- A passing answer captures the spirit and the load-bearing concepts.
- Don't reward gibberish, but don't penalize style or brevity.
- Score 0-100. Pass threshold is 60.

You will be given the question, a canonical answer, the key concepts to look for, and the rep's typed answer. Return JSON only — no preamble, no markdown fences.`;

interface GradeRequest {
  question_prompt: string;
  canonical_answer: string;
  key_concepts: string[];
  rep_answer: string;
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

  let body: GradeRequest;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const { question_prompt, canonical_answer, key_concepts, rep_answer } = body;
  if (
    !question_prompt || !canonical_answer || typeof rep_answer !== "string"
  ) {
    return json(
      { error: "Required: question_prompt, canonical_answer, rep_answer" },
      400,
    );
  }
  if (rep_answer.length > MAX_REP_ANSWER_LEN) {
    return json(
      { error: `rep_answer exceeds ${MAX_REP_ANSWER_LEN} chars` },
      400,
    );
  }

  const userMessage = `Question: ${question_prompt}

Canonical answer: ${canonical_answer}

Key concepts to look for: ${JSON.stringify(key_concepts ?? [])}

Rep's typed answer: ${rep_answer}

Grade this answer.`;

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
            pass: {
              type: "boolean",
              description: "true if score >= 60",
            },
            score: {
              type: "integer",
              description:
                "0-100 — how well the rep captured the key concepts and intent",
            },
            feedback: {
              type: "string",
              description:
                "One short sentence (under 25 words) addressed directly to the rep. Tell them what they got right or what they missed.",
            },
            missing_concepts: {
              type: "array",
              items: { type: "string" },
              description:
                "Key concepts from the input list the rep did not cover. Empty array if none missing.",
            },
          },
          required: ["pass", "score", "feedback", "missing_concepts"],
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
  // With output_config.format set, the first text block contains valid JSON.
  const textBlock = data.content?.find((b: { type: string }) =>
    b.type === "text"
  );
  if (!textBlock?.text) {
    return json({ error: "Claude response missing text block", raw: data }, 502);
  }

  try {
    const grade = JSON.parse(textBlock.text);
    return json(grade);
  } catch {
    return json(
      { error: "Failed to parse Claude JSON response", text: textBlock.text },
      502,
    );
  }
});
