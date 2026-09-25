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

NUM_PERSONAS="${MEZTLI_EVAL_NUM_PERSONAS:-4}"
CASES_PER_PERSONA="${MEZTLI_EVAL_CASES_PER_PERSONA:-3}"
INSTRUCTIONS="${MEZTLI_EVAL_GENERATION_INSTRUCTIONS:-Generate diverse, realistic user prompts for Meztli AI (Plaid, Google Sheets, Discord, Shopify, Square, Clover, WhatsApp, email, QuickBooks). Mix scenario types: (1) must-attempt connector workflows, (2) multi-step read→compute→write→notify, (3) reconciliation/math, (4) error recovery (invalid account, missing sheet tab), (5) impossible/must-refuse asks (e.g. future projections from Plaid). Each test must set vars.prompt only. Vary complexity.}"

echo "==> Generating fresh test cases (${NUM_PERSONAS} personas × ${CASES_PER_PERSONA} cases)..."
if ! run_dataset_generation tests/generated.yaml "$NUM_PERSONAS" "$CASES_PER_PERSONA" "$INSTRUCTIONS"; then
  generation_failure_hint
  exit 1
fi

GEN_COUNT=$(count_generated_tests tests/generated.yaml)
echo "Wrote $GEN_COUNT new tests to tests/generated.yaml"
