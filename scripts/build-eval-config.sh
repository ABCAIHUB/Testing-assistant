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

parse_eval_args "$@"
parse_status=$?
if [[ $parse_status -eq 2 ]]; then
  exit 0
fi
if [[ $parse_status -ne 0 ]]; then
  exit "$parse_status"
fi

MODE="$(resolve_prompt_mode "$PROMPT_MODE")" || exit 1
echo "==> Building eval config (mode=$MODE)"
prepare_manual_if_needed "$MODE" || exit 1
build_eval_config promptfooconfig.eval.yaml "$MODE" tests/generated.yaml "$RESOLVED_MANUAL_FILE"
