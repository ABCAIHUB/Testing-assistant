#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi
normalize_anthropic_api_key

parse_eval_args "$@"
parse_status=$?
if [[ $parse_status -eq 2 ]]; then
  exit 0
fi
if [[ $parse_status -ne 0 ]]; then
  exit "$parse_status"
fi

MODE="$(resolve_prompt_mode "$PROMPT_MODE")" || exit 1

# generate-and-eval always needs generation unless mode is manual-only
if [[ "$MODE" == "manual" ]]; then
  echo "==> Mode=manual — skipping AI generation; running manual prompts only."
  prepare_manual_if_needed "$MODE" || exit 1
  build_eval_config promptfooconfig.eval.yaml "$MODE" tests/generated.yaml "$RESOLVED_MANUAL_FILE"
  echo "==> Running evaluation against http://localhost:4000/api/chat ..."
  promptfoo eval -c promptfooconfig.eval.yaml --output output.json
  echo "==> Done. View results: npm run view"
  exit 0
fi

NUM_PERSONAS="${MEZTLI_EVAL_NUM_PERSONAS:-4}"
CASES_PER_PERSONA="${MEZTLI_EVAL_CASES_PER_PERSONA:-3}"
INSTRUCTIONS="${MEZTLI_EVAL_GENERATION_INSTRUCTIONS:-Generate diverse, realistic user prompts for Meztli AI. Cover: Plaid transaction pulls and balance checks, Google Sheets read/write workflows, Discord alerts, expense categorization, reconciliation math, multi-connector sequences, and edge cases (missing sheets, invalid accounts, impossible requests like future projections from Plaid). Each test must set vars.prompt only. Vary complexity from simple lookups to 3-step workflows.}"

echo "==> Prompt mode: $MODE"
prepare_manual_if_needed "$MODE" || exit 1

echo "==> Generating fresh test cases (${NUM_PERSONAS} personas × ${CASES_PER_PERSONA} cases)..."
if ! run_dataset_generation tests/generated.yaml "$NUM_PERSONAS" "$CASES_PER_PERSONA" "$INSTRUCTIONS"; then
  generation_failure_hint
  exit 1
fi

GEN_COUNT=$(count_generated_tests tests/generated.yaml)
echo "Wrote $GEN_COUNT new tests to tests/generated.yaml"

build_eval_config promptfooconfig.eval.yaml "$MODE" tests/generated.yaml "$RESOLVED_MANUAL_FILE"

echo "==> Running evaluation against http://localhost:4000/api/chat ..."
promptfoo eval -c promptfooconfig.eval.yaml --output output.json

echo "==> Done. View results: npm run view"
