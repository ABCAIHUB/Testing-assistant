# Meztli Promptfoo Evals

Automated **and** manual prompt evaluation for the Meztli in-app Assistant (`POST /api/chat`).

## Prerequisites

1. **Backend running** on `http://localhost:4000` with eval bypass enabled (local dev):
   - `EVAL_API_KEY` and `EVAL_CLERK_USER_ID` in `miraai-backend/.env`
   - `NODE_ENV` must not be `production`
2. **`.env`** in this folder with `ANTHROPIC_API_KEY` (for test generation + llm-rubric grading)

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
- Synthesis provider uses **temperature 0.5** (`providers/dataset-synthesis.yaml`, 8192 max_tokens)
- `--no-cache` on every promptfoo generate call; retries a few times on failure

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
| `promptfooconfig.yaml` | Base eval config (provider, rubric, prompts) |
| `promptfooconfig.generation.yaml` | Default test generation (seeded examples) |
| `promptfooconfig.generation-fresh.yaml` | Optional generation with no seed examples |
| `providers/dataset-synthesis.yaml` | Claude provider for synthesis (8192 tokens) |
| `tests/generated.yaml` | Replaced each auto generate run |
| `tests/manual.yaml` | **Your** prompts for `manual` / `both` modes |
| `tests/seed.yaml` | Seed scenarios for dataset synthesis (not used by eval) |

## Auth

No Bearer token needed locally — requests use `X-Eval-Key: promptfoo_eval_key_2026` (must match backend `EVAL_API_KEY`).

## Tips

- `npm run eval:manual` fails clearly if `tests/manual.yaml` is empty/missing — add prompts first.
- `npm run eval` / `eval:both` need a non-empty `tests/generated.yaml` — run `npm run generate:only` first if needed.
- Use `npm run generate` (not bare `promptfoo generate dataset`) so the correct provider and fresh config apply.
- All modes use the same `defaultTest` llm-rubric assertions (tool use, math, no hallucination).
