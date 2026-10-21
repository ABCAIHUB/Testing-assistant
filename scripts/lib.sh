#!/usr/bin/env bash
# Shared helpers for meztli-evals scripts

# Prefer local promptfoo (devDependency) over any global install (e.g. 0.122.x).
_MEZTLI_EVAL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MEZTLI_EVAL_ROOT="$(cd "$_MEZTLI_EVAL_LIB_DIR/.." && pwd)"
if [[ -x "$_MEZTLI_EVAL_ROOT/node_modules/.bin/promptfoo" ]]; then
  PROMPTFOO_BIN="${PROMPTFOO_BIN:-$_MEZTLI_EVAL_ROOT/node_modules/.bin/promptfoo}"
  export PATH="$_MEZTLI_EVAL_ROOT/node_modules/.bin:$PATH"
else
  PROMPTFOO_BIN="${PROMPTFOO_BIN:-promptfoo}"
fi

# Prompt source mode: auto | manual | both
# - auto:   AI-generated tests only (tests/generated.yaml)
# - manual: user-supplied tests only (tests/manual.yaml or --prompt / --manual-file)
# - both:   manual + generated in one eval run
DEFAULT_PROMPT_MODE="${MEZTLI_EVAL_PROMPT_MODE:-auto}"
DEFAULT_MANUAL_FILE="${MEZTLI_EVAL_MANUAL_FILE:-tests/manual.yaml}"
RESOLVED_MANUAL_FILE="tests/.manual-resolved.yaml"

count_generated_tests() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo 0
    return 0
  fi
  local c
  # Matches both "- vars:" and "- description:" ... vars: styles
  c=$(grep -cE '^- (vars|description):' "$file" 2>/dev/null || true)
  echo "${c:-0}"
}

# True if file looks like promptfoo test YAML (not plain text).
is_promptfoo_test_yaml() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  grep -qE '^- (vars|description):' "$file" 2>/dev/null
}

flatten_generated_yaml() {
  local file="$1"
  if [[ ! -s "$file" ]]; then
    return 1
  fi
  if head -1 "$file" | grep -q '^tests:'; then
    tail -n +2 "$file" | sed 's/^  //' > "${file}.tmp"
    mv "${file}.tmp" "$file"
  fi
  if [[ "$(count_generated_tests "$file")" -eq 0 ]]; then
    return 1
  fi
  return 0
}

# Write promptfoo test YAML from newline-separated prompts (stdin or args via python).
# Usage: write_manual_yaml_from_prompts DEST_FILE prompt1 prompt2 ...
#    or: printf '%s\0' ... | write_manual_yaml_from_prompts DEST_FILE --stdin-null
write_manual_yaml_from_prompts() {
  local dest="$1"
  shift
  python3 - "$dest" "$@" <<'PY'
import sys
from pathlib import Path

dest = Path(sys.argv[1])
args = sys.argv[2:]

if args == ["--stdin-null"]:
    raw = sys.stdin.buffer.read().split(b"\0")
    prompts = [p.decode("utf-8").strip() for p in raw if p.strip()]
elif args and args[0] == "--stdin":
    text = sys.stdin.read()
    if "\n\n" in text.strip():
        prompts = [p.strip() for p in text.split("\n\n") if p.strip()]
    else:
        prompts = [
            ln.strip()
            for ln in text.splitlines()
            if ln.strip() and not ln.strip().startswith("#")
        ]
else:
    prompts = [p.strip() for p in args if p.strip()]

if not prompts:
    sys.exit(1)

def yaml_block(s: str) -> str:
    lines = s.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    return "\n".join("      " + (ln if ln else "") for ln in lines)

chunks = []
for i, prompt in enumerate(prompts, 1):
    label = prompt.split("\n", 1)[0][:72].replace('"', "'")
    chunks.append(
        '- description: "Manual %d: %s"\n' % (i, label)
        + "  vars:\n"
        + "    prompt: |-\n"
        + yaml_block(prompt)
        + "\n"
    )
dest.write_text("".join(chunks), encoding="utf-8")
print(len(prompts))
PY
}

# Parse a manual source file into RESOLVED_MANUAL_FILE.
# Supports:
#   - promptfoo YAML (lines with "- vars:")
#   - plain text: blank-line-separated prompts, or one prompt per line (# comments ok)
#   - "---" separators between prompts
materialize_manual_tests() {
  local source="${1:-$DEFAULT_MANUAL_FILE}"
  local dest="${2:-$RESOLVED_MANUAL_FILE}"

  if [[ ! -f "$source" ]]; then
    echo "ERROR: Manual prompts file not found: $source"
    echo "  Create $DEFAULT_MANUAL_FILE, or pass --manual-file / --prompt"
    return 1
  fi

  if is_promptfoo_test_yaml "$source"; then
    # Already promptfoo test YAML — normalize optional tests: wrapper
    cp "$source" "$dest"
    flatten_generated_yaml "$dest" || true
    if [[ "$(count_generated_tests "$dest")" -eq 0 ]]; then
      echo "ERROR: $source has no test entries (- vars: / - description:)."
      return 1
    fi
    return 0
  fi

  # Plain text / --- separated
  python3 - "$source" "$dest" <<'PY'
import sys
from pathlib import Path

src = Path(sys.argv[1]).read_text(encoding="utf-8")
dest = Path(sys.argv[2])

# Strip # comment-only lines for line mode; keep content lines
if "\n---\n" in src or src.strip().startswith("---"):
    parts = [p.strip() for p in src.split("\n---\n")]
    prompts = []
    for p in parts:
        p = p.strip().lstrip("-").strip()
        if p.startswith("---"):
            p = p[3:].strip()
        if p and not all(ln.strip().startswith("#") or not ln.strip() for ln in p.splitlines()):
            # drop leading comment-only lines
            lines = [ln for ln in p.splitlines() if not ln.strip().startswith("#")]
            text = "\n".join(lines).strip()
            if text:
                prompts.append(text)
elif "\n\n" in src.strip():
    prompts = []
    for block in src.split("\n\n"):
        lines = [ln for ln in block.splitlines() if not ln.strip().startswith("#")]
        text = "\n".join(lines).strip()
        if text:
            prompts.append(text)
else:
    prompts = [
        ln.strip()
        for ln in src.splitlines()
        if ln.strip() and not ln.strip().startswith("#")
    ]

if not prompts:
    sys.exit(1)

def yaml_block(s: str) -> str:
    lines = s.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    return "\n".join("      " + (ln if ln else "") for ln in lines)

chunks = []
for i, prompt in enumerate(prompts, 1):
    label = prompt.split("\n", 1)[0][:72].replace('"', "'")
    chunks.append(
        f'- description: "Manual {i}: {label}"\n'
        f"  vars:\n"
        f"    prompt: |-\n"
        f"{yaml_block(prompt)}\n"
    )
dest.write_text("".join(chunks), encoding="utf-8")
print(len(prompts), flush=True)
PY
  local n=$?
  if [[ $n -ne 0 ]] || [[ "$(count_generated_tests "$dest")" -eq 0 ]]; then
    echo "ERROR: Could not parse manual prompts from $source"
    return 1
  fi
  return 0
}

resolve_prompt_mode() {
  local mode="${1:-$DEFAULT_PROMPT_MODE}"
  case "$mode" in
    auto|manual|both) echo "$mode" ;;
    *)
      echo "ERROR: Unknown prompt mode '$mode' (use auto | manual | both)" >&2
      return 1
      ;;
  esac
}

# Build promptfooconfig.eval.yaml for the given mode.
# Optional: MANUAL_RESOLVED path already prepared; GENERATED path default tests/generated.yaml
build_eval_config() {
  local out="$1"
  local mode
  mode="$(resolve_prompt_mode "${2:-$DEFAULT_PROMPT_MODE}")" || return 1
  local generated="${3:-tests/generated.yaml}"
  local manual="${4:-$RESOLVED_MANUAL_FILE}"

  local use_manual=0
  local use_auto=0
  case "$mode" in
    auto) use_auto=1 ;;
    manual) use_manual=1 ;;
    both) use_manual=1; use_auto=1 ;;
  esac

  local entries=()

  if [[ "$use_manual" -eq 1 ]]; then
    if [[ ! -f "$manual" ]] || [[ "$(count_generated_tests "$manual")" -eq 0 ]]; then
      # Fall back to default manual file if resolved missing
      if [[ "$manual" != "$DEFAULT_MANUAL_FILE" ]] && [[ -f "$DEFAULT_MANUAL_FILE" ]]; then
        materialize_manual_tests "$DEFAULT_MANUAL_FILE" "$RESOLVED_MANUAL_FILE" || return 1
        manual="$RESOLVED_MANUAL_FILE"
      else
        echo "ERROR: No manual prompts ready for mode=$mode."
        echo "  Edit $DEFAULT_MANUAL_FILE, or pass --manual-file / --prompt"
        echo "  Example: npm run eval:manual"
        return 1
      fi
    fi
    entries+=("  - file://${manual}")
  fi

  if [[ "$use_auto" -eq 1 ]]; then
    if [[ ! -f "$generated" ]] || [[ "$(count_generated_tests "$generated")" -eq 0 ]]; then
      echo "ERROR: $generated is missing or empty (needed for mode=$mode)."
      echo "  Run: npm run generate:only"
      return 1
    fi
    entries+=("  - file://${generated}")
  fi

  {
    cat promptfooconfig.yaml | sed '/^tests:/,$d'
    echo "tests:"
    printf '%s\n' "${entries[@]}"
  } > "$out"

  apply_chat_url_override "$out"

  local m_count=0 a_count=0
  [[ "$use_manual" -eq 1 ]] && m_count=$(count_generated_tests "$manual")
  [[ "$use_auto" -eq 1 ]] && a_count=$(count_generated_tests "$generated")
  echo "Wrote $out (mode=$mode; manual=$m_count, auto=$a_count; chat=$(resolve_chat_url); auth=$(resolve_chat_auth_mode))"
}

# Promptfoo synthesis defaults to max_tokens=1024, which truncates JSON for 10+ tests.
DEFAULT_SYNTHESIS_PROVIDER="${MEZTLI_EVAL_GENERATION_PROVIDER:-file://providers/dataset-synthesis.yaml}"
# Passed only to the test-case step (not personas). Keep vars-shaped; do not mention personas.
GENERATION_VARS_HINT='For each test case return JSON only as {"vars":[{"prompt":"..."},...]}. Keep each prompt under 120 words. Do not invent other keys. Respond with that JSON object only — no markdown fences or prose.'

# Trim whitespace from ANTHROPIC_API_KEY after sourcing .env (never print the value).
normalize_anthropic_api_key() {
  if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    return 0
  fi
  # shellcheck disable=SC2001
  ANTHROPIC_API_KEY="$(printf '%s' "$ANTHROPIC_API_KEY" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  export ANTHROPIC_API_KEY
}

# Chat targets (default = live Render). Local is opt-in only.
# - Clerk JWT (live): https://miraai-backend1.onrender.com/api/chat
# - X-Eval-Key (local backend only): http://localhost:4000/api/chat
DEFAULT_LIVE_CHAT_URL="https://miraai-backend1.onrender.com/api/chat"
DEFAULT_LOCAL_CHAT_URL="http://localhost:4000/api/chat"

normalize_eval_api_key() {
  if [[ -z "${MEZTLI_EVAL_API_KEY:-}" ]]; then
    return 0
  fi
  MEZTLI_EVAL_API_KEY="${MEZTLI_EVAL_API_KEY#Bearer }"
  MEZTLI_EVAL_API_KEY="${MEZTLI_EVAL_API_KEY#bearer }"
  # shellcheck disable=SC2001
  MEZTLI_EVAL_API_KEY="$(printf '%s' "$MEZTLI_EVAL_API_KEY" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  export MEZTLI_EVAL_API_KEY
}

normalize_clerk_jwt() {
  if [[ -z "${MEZTLI_EVAL_CLERK_JWT:-}" ]]; then
    return 0
  fi
  # Strip accidental "Bearer " prefix if the user pasted the full header value
  MEZTLI_EVAL_CLERK_JWT="${MEZTLI_EVAL_CLERK_JWT#Bearer }"
  MEZTLI_EVAL_CLERK_JWT="${MEZTLI_EVAL_CLERK_JWT#bearer }"
  # shellcheck disable=SC2001
  MEZTLI_EVAL_CLERK_JWT="$(printf '%s' "$MEZTLI_EVAL_CLERK_JWT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  export MEZTLI_EVAL_CLERK_JWT
}

# True when the user explicitly opted into a local backend (not live Render).
wants_local_chat() {
  local url="${MEZTLI_EVAL_CHAT_URL:-}"
  if [[ "${MEZTLI_EVAL_USE_LOCAL:-}" == "1" ]] || [[ "${MEZTLI_EVAL_USE_LOCAL:-}" == "true" ]]; then
    return 0
  fi
  if [[ -n "$url" ]] && [[ "$url" == *"localhost"* || "$url" == *"127.0.0.1"* ]]; then
    return 0
  fi
  return 1
}

# Prefer Clerk JWT (live). Eval API key is local-dev-only and never used against live.
# Must call after sourcing .env.
resolve_chat_auth_mode() {
  normalize_eval_api_key
  normalize_clerk_jwt
  if wants_local_chat && [[ -n "${MEZTLI_EVAL_API_KEY:-}" ]]; then
    echo "eval_key"
  elif [[ -n "${MEZTLI_EVAL_CLERK_JWT:-}" ]]; then
    echo "clerk_jwt"
  else
    echo "none"
  fi
}

# Default chat URL is always live Render unless the user opts into local.
resolve_chat_url() {
  if [[ -n "${MEZTLI_EVAL_CHAT_URL:-}" ]]; then
    printf '%s' "$MEZTLI_EVAL_CHAT_URL"
    return 0
  fi
  if wants_local_chat; then
    printf '%s' "$DEFAULT_LOCAL_CHAT_URL"
    return 0
  fi
  printf '%s' "$DEFAULT_LIVE_CHAT_URL"
}

# Kept for callers that reference DEFAULT_CHAT_URL before resolve_chat_url.
DEFAULT_CHAT_URL="$DEFAULT_LIVE_CHAT_URL"

# Hint for expired JWTs (never print the token).
suggest_jwt_refresh() {
  cat <<'EOF' >&2
  Tokens expire — fix with one of:
    npm run refresh-jwt
      (needs MEZTLI_EVAL_CLERK_SECRET + MEZTLI_EVAL_CLERK_USER_ID or SESSION_ID;
       sign in at https://www.meztli.ai/assistant so an active session exists)
    Or paste a fresh Bearer token from DevTools → Network → /api/proxy into
      MEZTLI_EVAL_CLERK_JWT=… in .env
EOF
}

# Optionally run refresh-jwt when interactive and Clerk secret is configured.
maybe_refresh_jwt_on_401() {
  if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
    return 1
  fi
  if [[ -z "${MEZTLI_EVAL_CLERK_SECRET:-}" ]]; then
    return 1
  fi
  if [[ "${MEZTLI_EVAL_AUTO_REFRESH_JWT:-}" == "0" ]]; then
    return 1
  fi
  local reply=""
  printf 'Chat returned 401. Refresh JWT now via npm run refresh-jwt? [y/N] ' >&2
  read -r reply || true
  case "$reply" in
    y|Y|yes|YES)
      if bash "$_MEZTLI_EVAL_ROOT/scripts/refresh-clerk-jwt.sh"; then
        if [[ -f "$_MEZTLI_EVAL_ROOT/.env" ]]; then
          set -a
          # shellcheck disable=SC1091
          source "$_MEZTLI_EVAL_ROOT/.env"
          set +a
        fi
        normalize_clerk_jwt
        return 0
      fi
      ;;
  esac
  return 1
}

# Fail fast unless Clerk JWT (live) or local eval key is configured.
require_live_chat_auth() {
  local mode
  mode="$(resolve_chat_auth_mode)"
  if [[ "$mode" == "clerk_jwt" ]]; then
    echo "==> Auth: Clerk session JWT → $(resolve_chat_url)"
    return 0
  fi
  if [[ "$mode" == "eval_key" ]]; then
    echo "==> Auth: local eval API key (X-Eval-Key) → $(resolve_chat_url)"
    echo "    Local only: backend NODE_ENV must not be production. Live Render rejects this key."
    return 0
  fi
  # Warn if someone set the eval key expecting it to work on live
  if [[ -n "${MEZTLI_EVAL_API_KEY:-}" ]] && ! wants_local_chat; then
    cat <<'EOF' >&2
ERROR: MEZTLI_EVAL_API_KEY is set, but live Render rejects the eval bypass.

  Production auth requires a Clerk session JWT — the eval key only works on a
  local backend (NODE_ENV≠production).

  For live (default):
    1. Set MEZTLI_EVAL_CLERK_JWT (paste from browser, or npm run refresh-jwt)
    2. Leave MEZTLI_EVAL_CHAT_URL unset (defaults to Render) or set the live URL
    3. Unset MEZTLI_EVAL_API_KEY (or set MEZTLI_EVAL_USE_LOCAL=1 for localhost)

  For local only:
    MEZTLI_EVAL_USE_LOCAL=1
    MEZTLI_EVAL_API_KEY=…          # matches backend EVAL_API_KEY
    MEZTLI_EVAL_CHAT_URL=http://localhost:4000/api/chat
EOF
    return 1
  fi
  cat <<'EOF' >&2
ERROR: No chat auth configured for live Assistant.

Live workflow (default → https://miraai-backend1.onrender.com/api/chat):
  1. Sign in at https://www.meztli.ai/assistant
  2. Set MEZTLI_EVAL_CLERK_JWT in .env (paste from DevTools, or):
       npm run refresh-jwt
     (needs MEZTLI_EVAL_CLERK_SECRET + user/session id)
  3. npm run preflight && npm run eval:manual

Local-only opt-in (eval key; never works against production):
  MEZTLI_EVAL_USE_LOCAL=1
  MEZTLI_EVAL_API_KEY=…   # matches backend EVAL_API_KEY when NODE_ENV≠production
  MEZTLI_EVAL_CHAT_URL=http://localhost:4000/api/chat
EOF
  return 1
}

# Timeouts (seconds unless noted). Live assistant turns run tools + LLM calls and
# Render free-tier instances cold-start, so defaults are generous.
MEZTLI_EVAL_WARMUP_MAX_SECS="${MEZTLI_EVAL_WARMUP_MAX_SECS:-180}"
MEZTLI_EVAL_PROBE_TIMEOUT="${MEZTLI_EVAL_PROBE_TIMEOUT:-180}"
# Extra probe attempts on timeout / 5xx only. Each attempt may consume one
# assistant query from the plan quota, so keep this small.
MEZTLI_EVAL_PROBE_RETRIES="${MEZTLI_EVAL_PROBE_RETRIES:-1}"
# promptfoo 0.123's http provider ignores config.timeoutMs and reads this env var.
export REQUEST_TIMEOUT_MS="${REQUEST_TIMEOUT_MS:-300000}"

# Origin for the chat URL (strip trailing /api/chat).
resolve_chat_base_url() {
  local url
  url="$(resolve_chat_url)"
  printf '%s' "${url%/api/chat}"
}

# Hit ${base}/health until it answers (Render cold start), with backoff.
warm_up_backend() {
  local base
  base="$(resolve_chat_base_url)"
  local deadline=$((SECONDS + MEZTLI_EVAL_WARMUP_MAX_SECS))
  local delay=3
  local attempt=1
  local code
  echo "==> Warm-up: ${base}/health (up to ${MEZTLI_EVAL_WARMUP_MAX_SECS}s for cold start)"
  while :; do
    code="$(curl -sS -m 30 -o /dev/null -w '%{http_code}' "${base}/health" 2>/dev/null)" || true
    code="${code:-000}"
    case "$code" in
      000|502|503|504) ;;
      *)
        echo "    backend up (HTTP ${code}) after ${attempt} attempt(s)"
        return 0
        ;;
    esac
    if [[ "$SECONDS" -ge "$deadline" ]]; then
      echo "ERROR: ${base}/health not reachable after ${MEZTLI_EVAL_WARMUP_MAX_SECS}s (last HTTP ${code})." >&2
      echo "  The Render service may be down or still deploying. Check the Render dashboard." >&2
      return 1
    fi
    echo "    not ready (HTTP ${code}); retrying in ${delay}s…"
    sleep "$delay"
    delay=$((delay * 2))
    [[ "$delay" -gt 20 ]] && delay=20
    attempt=$((attempt + 1))
  done
}

# Cheap authenticated GET (no LLM, no quota) to tell auth problems from agent hangs.
check_chat_auth_fast() {
  local mode="$1"
  local base
  base="$(resolve_chat_base_url)"
  local auth_header
  if [[ "$mode" == "eval_key" ]]; then
    auth_header="X-Eval-Key: ${MEZTLI_EVAL_API_KEY}"
  else
    auth_header="Authorization: Bearer ${MEZTLI_EVAL_CLERK_JWT}"
  fi
  local code
  code="$(curl -sS -m 30 -o /dev/null -w '%{http_code}' \
    -H "$auth_header" "${base}/api/chat/sessions?limit=1" 2>/dev/null)" || true
  printf '%s' "${code:-000}"
}

# Probe chat once: catch PLAN_LIMIT / auth failures before promptfoo obscures them.
# On JWT 401, optionally offer refresh-jwt when interactive + Clerk secret is set.
probe_live_chat_or_die() {
  if [[ "${MEZTLI_EVAL_SKIP_PROBE:-}" == "1" ]]; then
    echo "==> Chat probe skipped (MEZTLI_EVAL_SKIP_PROBE=1)"
    return 0
  fi
  warm_up_backend || return 1

  local chat_url
  chat_url="$(resolve_chat_url)"
  local mode
  mode="$(resolve_chat_auth_mode)"
  local attempt=1
  local max_attempts=2
  local transient_left="$MEZTLI_EVAL_PROBE_RETRIES"

  while [[ "$attempt" -le "$max_attempts" ]]; do
    local body_file
    body_file="$(mktemp -t meztli-eval-probe.XXXXXX)"
    local auth_header
    if [[ "$mode" == "eval_key" ]]; then
      # Local/non-prod only: X-Eval-Key. Never send this against live Render.
      auth_header="X-Eval-Key: ${MEZTLI_EVAL_API_KEY}"
    else
      auth_header="Authorization: Bearer ${MEZTLI_EVAL_CLERK_JWT}"
    fi
    echo "==> Chat probe: POST ${chat_url} (timeout ${MEZTLI_EVAL_PROBE_TIMEOUT}s)"
    local code curl_rc=0
    # curl already prints 000 for http_code on transport failure; don't append another.
    code="$(curl -sS -m "$MEZTLI_EVAL_PROBE_TIMEOUT" -o "$body_file" -w '%{http_code}' \
      -X POST "$chat_url" \
      -H 'Content-Type: application/json' \
      -H "$auth_header" \
      -d '{"message":"ping","clientSessionId":"promptfoo-probe","timezone":"America/Chicago"}')" || curl_rc=$?
    code="${code:-000}"

    local body
    body="$(cat "$body_file" 2>/dev/null || true)"
    rm -f "$body_file"

    if [[ "$code" == "000" || "$code" == "502" || "$code" == "503" || "$code" == "504" ]]; then
      if [[ "$transient_left" -gt 0 ]]; then
        transient_left=$((transient_left - 1))
        echo "    probe got HTTP ${code} (curl exit ${curl_rc}); retrying in 10s…" >&2
        sleep 10
        continue
      fi
      if [[ "$curl_rc" -eq 28 ]]; then
        local auth_code
        auth_code="$(check_chat_auth_fast "$mode")"
        cat <<EOF >&2
ERROR: Chat probe timed out after ${MEZTLI_EVAL_PROBE_TIMEOUT}s with no response (url=${chat_url}).

  /health: up    authenticated GET /api/chat/sessions: HTTP ${auth_code}
EOF
        if [[ "$auth_code" == "200" ]]; then
          cat <<'EOF' >&2
  The server is up and your JWT is accepted, but POST /api/chat never answers.
  That is a hang inside the backend agent turn (LLM provider / connector context),
  not an eval-harness or auth problem. Check the Render logs for miraai-backend.

  Options:
    - Allow more time: MEZTLI_EVAL_PROBE_TIMEOUT=300 npm run eval
    - Skip the probe (promptfoo will still wait REQUEST_TIMEOUT_MS per test):
        MEZTLI_EVAL_SKIP_PROBE=1 npm run eval
EOF
        elif [[ "$auth_code" == "401" ]]; then
          suggest_jwt_refresh
        fi
        return 1
      fi
    fi

    local code_field used max plan_id err_msg
    code_field="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('code') or '')" "$body" 2>/dev/null || true)"
    used="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('used') if d.get('used') is not None else '')" "$body" 2>/dev/null || true)"
    max="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('max') if d.get('max') is not None else '')" "$body" 2>/dev/null || true)"
    plan_id="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('planId') or '')" "$body" 2>/dev/null || true)"
    err_msg="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print((d.get('error') or d.get('message') or '')[:120])" "$body" 2>/dev/null || true)"

    if [[ "$code" == "200" ]]; then
      echo "==> Chat probe OK (HTTP 200) auth=${mode} url=${chat_url}"
      return 0
    fi

    if [[ "$code" == "402" ]] || [[ "$code_field" == "PLAN_LIMIT" ]]; then
      cat <<EOF >&2
ERROR: Assistant plan limit blocked this eval (HTTP ${code}).

  code=${code_field:-PLAN_LIMIT}  used=${used:-?}  max=${max:-?}  planId=${plan_id:-?}

The free plan allows only 15 assistant queries / month. Prior eval runs already
consumed that quota for this workspace, so Promptfoo gets 402 and then fails
parsing json.result.output ("Transform failed: Cannot read properties…").

Fix options:
  1. Upgrade the org plan on https://www.meztli.ai (Pro/Elite = unlimited queries)
  2. Sign in as a user on an org that still has assistant query quota
  3. Wait until the monthly usage window resets
  4. Opt into local backend (MEZTLI_EVAL_USE_LOCAL=1 + MEZTLI_EVAL_API_KEY) if you have quota there
EOF
      return 1
    fi

    if [[ "$code" == "401" ]]; then
      if [[ "$mode" == "eval_key" ]]; then
        cat <<EOF >&2
ERROR: Chat returned 401 with local eval API key (url=${chat_url}).

  The eval-key bypass only works when the backend has NODE_ENV≠production.
  Live Render always rejects it — use MEZTLI_EVAL_CLERK_JWT for live instead.
EOF
        if [[ -n "$err_msg" ]]; then
          echo "  api: ${err_msg}" >&2
        fi
        return 1
      fi

      echo "ERROR: Chat returned 401 Unauthorized (expired or invalid Clerk JWT)." >&2
      if [[ -n "$err_msg" ]]; then
        echo "  api: ${err_msg}" >&2
      fi
      if [[ "$attempt" -lt "$max_attempts" ]] && maybe_refresh_jwt_on_401; then
        mode="$(resolve_chat_auth_mode)"
        attempt=$((attempt + 1))
        echo "==> Retrying chat probe with refreshed JWT…"
        continue
      fi
      suggest_jwt_refresh
      return 1
    fi

    echo "ERROR: Chat probe failed HTTP ${code} (curl exit ${curl_rc}): ${body:0:300}" >&2
    return 1
  done
  return 1
}

# After build_eval_config, rewrite chat URL + auth headers for the active mode.
apply_chat_url_override() {
  local config_file="$1"
  local url
  url="$(resolve_chat_url)"
  if [[ ! -f "$config_file" ]]; then
    return 0
  fi
  if grep -qE '^[[:space:]]*url:[[:space:]]' "$config_file"; then
    local escaped
    escaped="$(printf '%s' "$url" | sed 's/[&|]/\\&/g')"
    sed -i.bak -E "s|^([[:space:]]*url:[[:space:]]*).*$|\1${escaped}|" "$config_file"
    rm -f "${config_file}.bak"
  fi
  apply_chat_auth_headers "$config_file"
}

# Rewrite provider headers: Clerk JWT Bearer (live) or X-Eval-Key (local only).
apply_chat_auth_headers() {
  local config_file="$1"
  local mode
  mode="$(resolve_chat_auth_mode)"
  python3 - "$config_file" "$mode" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
mode = sys.argv[2]
text = path.read_text(encoding="utf-8")
lines = text.splitlines(keepends=True)
out = []
i = 0
while i < len(lines):
    line = lines[i]
    if line.strip() == "headers:":
        indent = line[: len(line) - len(line.lstrip(" "))]
        child = indent + "  "
        out.append(line)
        i += 1
        # Skip existing header entries under this block
        while i < len(lines):
            nxt = lines[i]
            if nxt.startswith(child) or (nxt.strip() == "" and i + 1 < len(lines) and lines[i + 1].startswith(child)):
                i += 1
                continue
            break
        out.append(f"{child}Content-Type: application/json\n")
        if mode == "eval_key":
            out.append(f'{child}X-Eval-Key: "{{{{env.MEZTLI_EVAL_API_KEY}}}}"\n')
        else:
            out.append(f'{child}Authorization: "Bearer {{{{env.MEZTLI_EVAL_CLERK_JWT}}}}"\n')
        continue
    out.append(line)
    i += 1
path.write_text("".join(out), encoding="utf-8")
PY
}

generation_failure_hint() {
  cat <<'EOF'
ERROR: Dataset generation failed or produced no usable tests.
  Possible causes:
    - Model returned unexpected JSON (personas/vars shape) — most common with a bare "{{prompt}}" template
    - Missing/invalid ANTHROPIC_API_KEY or network/proxy issues
    - Truncated / empty output file after flatten
  Debug: LOG_LEVEL=debug npm run generate:only
EOF
}

build_fresh_instructions() {
  local base="$1"
  local run_id
  run_id="$(date +%s)-$RANDOM"
  echo "${base} Run ID ${run_id}: generate completely NEW prompts not reused from prior runs. Vary connectors, sheet names, time windows, and workflow shapes."
}

# Default: seeded config (examples stabilize synthesis). Override with MEZTLI_EVAL_GENERATION_CONFIG=fresh
generation_config_path() {
  case "${MEZTLI_EVAL_GENERATION_CONFIG:-seeded}" in
    fresh) echo "promptfooconfig.generation-fresh.yaml" ;;
    seeded|*) echo "promptfooconfig.generation.yaml" ;;
  esac
}

merge_generated_batch() {
  local dest="$1"
  local batch="$2"
  flatten_generated_yaml "$batch" || return 1
  if [[ ! -f "$dest" ]] || [[ ! -s "$dest" ]]; then
    cp "$batch" "$dest"
  else
    cat "$batch" >> "$dest"
  fi
}

# Run promptfoo generate dataset with a few retries; surface clearer failure text.
promptfoo_generate_dataset() {
  local out="$1"
  local config="$2"
  local provider="$3"
  local num_personas="$4"
  local cases_per_persona="$5"
  local instructions="$6"
  local max_attempts="${MEZTLI_EVAL_GENERATE_RETRIES:-5}"
  local attempt=1
  local err_log
  err_log="$(mktemp -t meztli-generate.XXXXXX)"

  while [[ "$attempt" -le "$max_attempts" ]]; do
    set +e
    "$PROMPTFOO_BIN" generate dataset \
      -c "$config" \
      -o "$out" \
      --provider "$provider" \
      --numPersonas "$num_personas" \
      --numTestCasesPerPersona "$cases_per_persona" \
      -i "$instructions" \
      --no-cache 2> >(tee "$err_log" >&2)
    local rc=$?
    set -e
    if [[ "$rc" -eq 0 ]]; then
      rm -f "$err_log"
      return 0
    fi

    echo "  generation attempt ${attempt}/${max_attempts} failed" >&2
    if grep -qE 'personas|TypeError|Invariant failed|resp\.output' "$err_log" 2>/dev/null; then
      echo "  hint: personas/vars JSON shape problem (or empty model response). Retrying…" >&2
    elif grep -qiE 'api.?key|401|403|authentication|unauthorized' "$err_log" 2>/dev/null; then
      echo "  hint: Anthropic auth failed — check ANTHROPIC_API_KEY" >&2
    elif grep -qiE 'connection|ECONNREFUSED|ETIMEDOUT|network|proxy' "$err_log" 2>/dev/null; then
      echo "  hint: network/proxy error reaching Anthropic" >&2
    fi
    if [[ "${LOG_LEVEL:-}" == "debug" ]]; then
      tail -n 40 "$err_log" >&2 || true
    fi
    attempt=$((attempt + 1))
    sleep 1
  done

  echo "  last promptfoo error (tail):" >&2
  tail -n 20 "$err_log" >&2 || true
  rm -f "$err_log"
  return 1
}

run_dataset_generation() {
  local out_file="$1"
  local num_personas="$2"
  local cases_per_persona="$3"
  local instructions="$4"
  local total=$((num_personas * cases_per_persona))
  local provider="$DEFAULT_SYNTHESIS_PROVIDER"
  local batch_max="${MEZTLI_EVAL_BATCH_MAX:-8}"
  local config
  config="$(generation_config_path)"
  local fresh_instructions
  fresh_instructions="$(build_fresh_instructions "$instructions")"

  echo "  using generation config: $config"

  rm -f "$out_file" tests/generated.yaml.bak tests/.generated-batch-*.yaml

  if [[ "$total" -le "$batch_max" ]]; then
    promptfoo_generate_dataset \
      "$out_file" \
      "$config" \
      "$provider" \
      "$num_personas" \
      "$cases_per_persona" \
      "${fresh_instructions} ${GENERATION_VARS_HINT}" \
      || return 1
    flatten_generated_yaml "$out_file" || return 1
    return 0
  fi

  local remaining="$total"
  local batch_idx=0
  while [[ "$remaining" -gt 0 ]]; do
    batch_idx=$((batch_idx + 1))
    local batch_total="$remaining"
    if [[ "$batch_total" -gt "$batch_max" ]]; then
      batch_total="$batch_max"
    fi
    local batch_personas=2
    local batch_cases=$(( (batch_total + batch_personas - 1) / batch_personas ))
    if [[ "$batch_cases" -lt 1 ]]; then batch_cases=1; fi
    if [[ "$((batch_personas * batch_cases))" -gt "$batch_total" ]]; then
      batch_cases=$(( (batch_total + batch_personas - 1) / batch_personas ))
    fi

    local batch_file="tests/.generated-batch-${batch_idx}.yaml"
    echo "  batch ${batch_idx}: ${batch_personas} personas × ${batch_cases} cases"

    promptfoo_generate_dataset \
      "$batch_file" \
      "$config" \
      "$provider" \
      "$batch_personas" \
      "$batch_cases" \
      "${fresh_instructions} ${GENERATION_VARS_HINT} Batch ${batch_idx}: avoid repeating prompts from earlier batches in this run." \
      || return 1

    merge_generated_batch "$out_file" "$batch_file" || return 1
    rm -f "$batch_file"
    remaining=$((remaining - batch_personas * batch_cases))
  done

  return 0
}

# Parse shared CLI flags into globals: PROMPT_MODE, MANUAL_FILE, MANUAL_PROMPTS[]
# Remaining args left in PARSE_REMAINING_ARGS
parse_eval_args() {
  PROMPT_MODE="${MEZTLI_EVAL_PROMPT_MODE:-auto}"
  MANUAL_FILE="${MEZTLI_EVAL_MANUAL_FILE:-tests/manual.yaml}"
  MANUAL_FILE_EXPLICIT=0
  MANUAL_PROMPTS=()
  PARSE_REMAINING_ARGS=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        PROMPT_MODE="$2"
        shift 2
        ;;
      --mode=*)
        PROMPT_MODE="${1#*=}"
        shift
        ;;
      --manual-file)
        MANUAL_FILE="$2"
        MANUAL_FILE_EXPLICIT=1
        shift 2
        ;;
      --manual-file=*)
        MANUAL_FILE="${1#*=}"
        MANUAL_FILE_EXPLICIT=1
        shift
        ;;
      --prompt)
        MANUAL_PROMPTS+=("$2")
        shift 2
        ;;
      --prompt=*)
        MANUAL_PROMPTS+=("${1#*=}")
        shift
        ;;
      --help|-h)
        cat <<'EOF'
Prompt modes (auto | manual | both):

  --mode auto|manual|both   Which prompts to run (default: auto, or MEZTLI_EVAL_PROMPT_MODE)
  --manual-file PATH        Manual prompts file (YAML or plain text; default: tests/manual.yaml)
  --prompt "text"           Add one manual prompt (repeatable); implies manual inclusion

Examples:
  npm run eval:manual
  npm run eval:both
  npm run generate:both
  bash scripts/run-eval.sh --mode manual --prompt "Pull my Plaid balance"
  MEZTLI_EVAL_PROMPT_MODE=both npm run generate
EOF
        return 2
        ;;
      *)
        PARSE_REMAINING_ARGS+=("$1")
        shift
        ;;
    esac
  done

  # Inline --prompt means we need manual in the mix
  if [[ ${#MANUAL_PROMPTS[@]} -gt 0 ]]; then
    if [[ "$PROMPT_MODE" == "auto" ]]; then
      PROMPT_MODE="manual"
    fi
  fi
}

# Prepare RESOLVED_MANUAL_FILE from --prompt list and/or MANUAL_FILE when mode needs manual.
prepare_manual_if_needed() {
  local mode="$1"
  case "$mode" in
    manual|both) ;;
    *) return 0 ;;
  esac

  if [[ ${#MANUAL_PROMPTS[@]} -gt 0 ]]; then
    if ! write_manual_yaml_from_prompts "$RESOLVED_MANUAL_FILE" "${MANUAL_PROMPTS[@]}" >/dev/null; then
      echo "ERROR: Failed to write inline --prompt values"
      return 1
    fi
    # Only merge a file when the user explicitly passed --manual-file
    if [[ "${MANUAL_FILE_EXPLICIT:-0}" -eq 1 ]] && [[ -f "$MANUAL_FILE" ]]; then
      local tmp="tests/.manual-from-file.yaml"
      if materialize_manual_tests "$MANUAL_FILE" "$tmp" 2>/dev/null; then
        cat "$tmp" >> "$RESOLVED_MANUAL_FILE"
        rm -f "$tmp"
      fi
    fi
    echo "Prepared $(count_generated_tests "$RESOLVED_MANUAL_FILE") manual prompt(s) → $RESOLVED_MANUAL_FILE"
    return 0
  fi

  materialize_manual_tests "$MANUAL_FILE" "$RESOLVED_MANUAL_FILE" || return 1
  echo "Prepared $(count_generated_tests "$RESOLVED_MANUAL_FILE") manual prompt(s) from $MANUAL_FILE"
}
