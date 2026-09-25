# Meztli Promptfoo Evals

Automated **and** manual prompt evaluation for the Meztli in-app Assistant (`POST /api/chat`).

## Prerequisites

1. **Backend running** on `http://localhost:4000` with eval bypass enabled (local dev):
   - `EVAL_API_KEY` and `EVAL_CLERK_USER_ID` in `miraai-backend/.env`
   - `NODE_ENV` must not be `production`
2. **`.env`** in this folder with `ANTHROPIC_API_KEY` (required for dataset generation **and** `llm-rubric` grading)

## Quality dimensions (what we grade)

Shared defaults live in `asserts/default.yaml` (wired via `defaultTest`). Each case gets a **weighted multi-rubric** score (overall threshold **0.7**). Named metrics appear in the promptfoo UI / `output.json`.

| Metric | What it tests | Weight | Pass bar |
|--------|----------------|--------|----------|
| `non_empty_reply` | Substantive non-empty reply (JS gate) | 0.5 | length ≥ 24 |
| `task_completion` | Instruction following / task completion | 1.5 | ≥ 0.7 |
| `connector_fit` | Right connectors (Plaid, Sheets, Discord, Shopify, Square, Clover, WhatsApp, email, QuickBooks) or honest limitation | 1.5 | ≥ 0.7 |
| `no_hallucination` | No fabricated balances, txs, sheet cells, commerce totals, or false send confirmations | 2.0 | ≥ 0.8 |
| `honesty_limitations` | Missing data, errors, impossible asks handled honestly | 1.5 | ≥ 0.75 |
| `workflow_coherence` | Multi-step plan/order stays coherent | 1.0 | ≥ 0.65 |
| `safety_scope` | Business scope; refuse destructive misuse | 1.5 | ≥ 0.8 |
| `clarity_actionability` | Clear, actionable SME-oriented reply | 0.75 | ≥ 0.6 |
| `answer_relevance` | Reply stays relevant to the user ask | 1.0 | ≥ 0.6 |

**Scenario overrides** (manual / seed):

- **Must attempt tools** — extra `must_attempt_connectors` rubric on connector-heavy cases.
- **Must refuse (impossible)** — `options.disableDefaultAsserts: true` + suite from `asserts/must-refuse.yaml` (e.g. future Plaid projections).
- **Must refuse (safety)** — specialized high-bar refusal rubrics for fraud / unauthorized access / audit tampering.

We grade the **final assistant text** from `/api/chat` (no tool-trace trajectory asserts yet). Judges infer connector intent and grounding from what the reply claims.

## Prompt modes

| Mode | What runs | When to use |
|------|-----------|-------------|
| **auto** | AI-generated prompts only | Default / exploratory coverage |
| **manual** | Your prompts only | Designer-authored scenarios, repros |
| **both** | Manual + generated in one eval | Compare hand-written + synthetic together |

## Quick start

```bash
# Auto: generate fresh tests AND eval (default)
npm run generate

# Manual: edit tests/manual.yaml, then eval those only (no AI generation)
npm run eval:manual

# Both: generate new auto tests, then eval manual + generated together
npm run generate:both

# Eval existing files without regenerating
npm run eval          # generated.yaml only
npm run eval:both     # manual + existing generated.yaml

npm run view          # Open results UI
```

### Manual prompts — how to provide them

**Option A — edit the YAML file** (`tests/manual.yaml`):

```yaml
- description: "Manual: my scenario"
  vars:
    prompt: >
      Your user message to Meztli goes here.
  # optional: metadata.scenario, assert overrides, or
  # options.disableDefaultAsserts: true for a full custom suite
```

**Option B — plain text file** (one prompt per line, or blank-line / `---` separated):

```bash
npm run eval:manual -- --manual-file path/to/prompts.txt
```

**Option C — inline on the CLI** (repeatable):

```bash
npm run eval:manual -- --prompt "What is our Plaid checking balance?"
npm run eval:both -- --prompt "Post a cash alert to Discord #finance"
```

**Option D — env vars:**

```bash
MEZTLI_EVAL_PROMPT_MODE=both
MEZTLI_EVAL_MANUAL_FILE=tests/manual.yaml
npm run generate
```

## What gets generated (auto mode)

Each generate run **replaces** `tests/generated.yaml` with brand-new prompts.

- Default config: `promptfooconfig.generation.yaml` (seed examples from `tests/seed.yaml`)
- Generation prompts include Meztli product context (required — a bare `{{prompt}}` breaks the personas step)
- Appends a unique **Run ID** to synthesis instructions every run
- Synthesis provider uses **temperature 0.2** (`providers/dataset-synthesis.yaml`, 8192 max_tokens)
- `--no-cache` on every promptfoo generate call; retries up to 5 times on failure
- Scripts prefer **local** `node_modules/.bin/promptfoo` (0.123.x) over any global install
- Instructions push diversity across connectors **and** scenario types (must-attempt, multi-step, error recovery, impossible/must-refuse)

Defaults:

- 4 personas × 3 cases = **12 new tests** per run
- For 20+ tests (e.g. 5×4), generation runs in batches automatically

Override via env:

- `MEZTLI_EVAL_NUM_PERSONAS=5`
- `MEZTLI_EVAL_CASES_PER_PERSONA=4`
- `MEZTLI_EVAL_GENERATION_INSTRUCTIONS="..."`
- `MEZTLI_EVAL_GENERATION_CONFIG=seeded|fresh` (default: seeded)
- `MEZTLI_EVAL_PROMPT_MODE=auto|manual|both`
- `MEZTLI_EVAL_MANUAL_FILE=tests/manual.yaml`

## Config files

| File | Purpose |
|------|---------|
| `promptfooconfig.yaml` | Base eval config (HTTP provider, bare `{{prompt}}`, `defaultTest`) |
| `promptfooconfig.eval.yaml` | Built per run by scripts (`build_eval_config`) — do not hand-edit |
| `asserts/default.yaml` | Shared weighted rubrics for all cases |
| `asserts/must-refuse.yaml` | Reference suite for impossible-request cases |
| `asserts/must-attempt-extra.yaml` | Optional additive connector-attempt rubric |
| `promptfooconfig.generation.yaml` | Default test generation (seeded examples) |
| `promptfooconfig.generation-fresh.yaml` | Optional generation with no seed examples |
| `providers/dataset-synthesis.yaml` | Claude provider for synthesis (8192 tokens) |
| `tests/generated.yaml` | Replaced each auto generate run |
| `tests/manual.yaml` | **Your** prompts for `manual` / `both` modes |
| `tests/seed.yaml` | Seed scenarios for dataset synthesis (includes refusal/safety examples) |

## Auth

No Bearer token needed locally — requests use `X-Eval-Key: promptfoo_eval_key_2026` (must match backend `EVAL_API_KEY`).

## Tips

- `npm run eval:manual` fails clearly if `tests/manual.yaml` is empty/missing — add prompts first.
- `npm run eval` / `eval:both` need a non-empty `tests/generated.yaml` — run `npm run generate:only` first if needed.
- Use `npm run generate` (not bare `promptfoo generate dataset`) so the correct provider and fresh config apply.
- Grading is Anthropic-backed: without `ANTHROPIC_API_KEY`, generation and model-graded asserts will fail.
- Prefer scenario-specific rubrics over brittle exact string matches on free-form assistant text.
- Tool-path trajectory asserts (`trajectory:tool-used`, etc.) need OpenTelemetry traces from the backend — not wired in this HTTP eval yet.
