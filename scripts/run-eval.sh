#!/usr/bin/env bash
# Run eval with prompt mode: auto | manual | both
# Does not regenerate tests — use generate-and-eval.sh for that.
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

echo "==> Prompt mode: $MODE"
prepare_manual_if_needed "$MODE" || exit 1

build_eval_config promptfooconfig.eval.yaml "$MODE" tests/generated.yaml "$RESOLVED_MANUAL_FILE"

echo "==> Running evaluation against http://localhost:4000/api/chat ..."
promptfoo eval -c promptfooconfig.eval.yaml --output output.json

echo "==> Done. View results: npm run view"
