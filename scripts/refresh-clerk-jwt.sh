#!/usr/bin/env bash
# Mint / refresh MEZTLI_EVAL_CLERK_JWT from an existing live Clerk session.
# Production Clerk does not allow creating sessions via Backend API — reuse an
# active browser session, then request a long-lived session token.
#
# Required in .env (never commit secrets):
#   MEZTLI_EVAL_CLERK_SECRET=sk_live_...   # live Clerk secret (not sk_test)
#   MEZTLI_EVAL_CLERK_USER_ID=user_...   # optional if MEZTLI_EVAL_CLERK_SESSION_ID set
#   MEZTLI_EVAL_CLERK_SESSION_ID=sess_... # optional; auto-picked from active sessions
#
# Usage:
#   npm run refresh-jwt
#   # then: npm run preflight && npm run eval:manual
#
# Manual alternative: paste a fresh Bearer token from DevTools into MEZTLI_EVAL_CLERK_JWT.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

SECRET="${MEZTLI_EVAL_CLERK_SECRET:-}"
USER_ID="${MEZTLI_EVAL_CLERK_USER_ID:-}"
SID="${MEZTLI_EVAL_CLERK_SESSION_ID:-}"
TTL="${MEZTLI_EVAL_CLERK_JWT_TTL:-3600}"

if [[ -z "$SECRET" ]]; then
  cat <<'EOF' >&2
ERROR: Set MEZTLI_EVAL_CLERK_SECRET (live sk_live_…) in .env

  Without the secret, paste a fresh JWT from the browser instead:
    1. Sign in at https://www.meztli.ai/assistant
    2. DevTools → Network → /api/proxy → copy Authorization Bearer token
    3. Set MEZTLI_EVAL_CLERK_JWT=… in .env
EOF
  exit 1
fi

if [[ "$SECRET" == sk_test_* ]]; then
  echo "ERROR: MEZTLI_EVAL_CLERK_SECRET looks like sk_test_ — live Render needs sk_live_." >&2
  exit 1
fi

if [[ -z "$SID" ]]; then
  if [[ -z "$USER_ID" ]]; then
    echo "ERROR: Set MEZTLI_EVAL_CLERK_SESSION_ID or MEZTLI_EVAL_CLERK_USER_ID" >&2
    exit 1
  fi
  RESP="$(curl -sS -m 30 -H "Authorization: Bearer ${SECRET}" \
    "https://api.clerk.com/v1/sessions?user_id=${USER_ID}&status=active&limit=1")"
  SID="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); rows=d if isinstance(d,list) else d.get('data') or []; print(rows[0]['id'] if rows else '')" "$RESP")"
  if [[ -z "$SID" ]]; then
    echo "ERROR: No active Clerk session for $USER_ID — sign in at https://www.meztli.ai/assistant first." >&2
    exit 1
  fi
  echo "Using active session ${SID:0:16}…"
fi

TOK="$(curl -sS -m 30 -X POST "https://api.clerk.com/v1/sessions/${SID}/tokens" \
  -H "Authorization: Bearer ${SECRET}" \
  -H 'Content-Type: application/json' \
  -d "{\"expires_in_seconds\":${TTL}}")"

python3 - "$TOK" <<'PY'
import json, sys, time, base64
from pathlib import Path
tok = json.loads(sys.argv[1])
jwt = tok.get("jwt") or tok.get("token") or ""
if not jwt.startswith("eyJ"):
    print("ERROR: token response:", tok, file=sys.stderr)
    sys.exit(1)
pad = "=" * (-len(jwt.split(".")[1]) % 4)
payload = json.loads(base64.urlsafe_b64decode(jwt.split(".")[1] + pad))
ttl = int(payload.get("exp", 0) - time.time())
env = Path(".env")
lines = env.read_text(encoding="utf-8").splitlines() if env.exists() else []
out, found = [], False
for line in lines:
    if line.startswith("MEZTLI_EVAL_CLERK_JWT="):
        out.append(f"MEZTLI_EVAL_CLERK_JWT={jwt}")
        found = True
    else:
        out.append(line)
if not found:
    out.append(f"MEZTLI_EVAL_CLERK_JWT={jwt}")
env.write_text("\n".join(out) + "\n", encoding="utf-8")
print(f"Wrote MEZTLI_EVAL_CLERK_JWT (ttl≈{ttl}s)")
PY
