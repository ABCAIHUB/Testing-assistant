#!/usr/bin/env bash
# Verify chat API health + auth (Clerk JWT live, or local eval key) before a full promptfoo run.
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

require_live_chat_auth || exit 1
CHAT_URL="$(resolve_chat_url)"
AUTH_MODE="$(resolve_chat_auth_mode)"
BASE="${CHAT_URL%/api/chat}"

echo "==> UI reference: https://www.meztli.ai/assistant"
echo "==> Auth mode: ${AUTH_MODE}"
warm_up_backend || exit 1

echo "==> Chat auth smoke: ${CHAT_URL}"
probe_live_chat_or_die || exit 1
# Re-resolve after possible interactive JWT refresh inside the probe
AUTH_MODE="$(resolve_chat_auth_mode)"

AUTH_HEADERS=(-H 'Content-Type: application/json')
if [[ "$AUTH_MODE" == "eval_key" ]]; then
  AUTH_HEADERS+=(-H "X-Eval-Key: ${MEZTLI_EVAL_API_KEY}")
else
  AUTH_HEADERS+=(-H "Authorization: Bearer ${MEZTLI_EVAL_CLERK_JWT}")
fi

CHAT_CODE="$(curl -sS -m "$MEZTLI_EVAL_PROBE_TIMEOUT" -o /tmp/meztli-eval-chat.json -w '%{http_code}' \
  -X POST "$CHAT_URL" \
  "${AUTH_HEADERS[@]}" \
  -d '{"message":"Reply in one short sentence: what can you help with?","clientSessionId":"promptfoo-preflight","timezone":"America/Chicago"}' || true)"
echo "    HTTP ${CHAT_CODE}"
if [[ "$CHAT_CODE" != "200" ]]; then
  echo "ERROR: follow-up chat call failed after probe"
  head -c 400 /tmp/meztli-eval-chat.json 2>/dev/null || true
  echo
  exit 1
fi

python3 - <<'PY'
import json
from pathlib import Path
raw = Path("/tmp/meztli-eval-chat.json").read_text(encoding="utf-8")
data = json.loads(raw)
out = ((data.get("result") or {}).get("output") or "").strip()
print("    output_chars:", len(out))
print("    preview:", (out[:160] + "…") if len(out) > 160 else out)
if len(out) < 8:
    raise SystemExit("empty assistant output")
PY

echo "==> Preflight OK — run: npm run eval:manual"
