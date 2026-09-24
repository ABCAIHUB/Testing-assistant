#!/usr/bin/env bash
# Shared helpers for meztli-evals scripts

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

  local m_count=0 a_count=0
  [[ "$use_manual" -eq 1 ]] && m_count=$(count_generated_tests "$manual")
  [[ "$use_auto" -eq 1 ]] && a_count=$(count_generated_tests "$generated")
  echo "Wrote $out (mode=$mode; manual=$m_count, auto=$a_count)"
}

# Promptfoo synthesis defaults to max_tokens=1024, which truncates JSON for 10+ tests.
DEFAULT_SYNTHESIS_PROVIDER="${MEZTLI_EVAL_GENERATION_PROVIDER:-file://providers/dataset-synthesis.yaml}"
# Passed only to the test-case step (not personas). Keep vars-shaped; do not mention personas.
GENERATION_VARS_HINT='For each test case return JSON only as {"vars":[{"prompt":"..."},...]}. Keep each prompt under 120 words. Do not invent other keys.'

# Trim whitespace from ANTHROPIC_API_KEY after sourcing .env (never print the value).
normalize_anthropic_api_key() {
  if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    return 0
  fi
  # shellcheck disable=SC2001
  ANTHROPIC_API_KEY="$(printf '%s' "$ANTHROPIC_API_KEY" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  export ANTHROPIC_API_KEY
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
  local max_attempts="${MEZTLI_EVAL_GENERATE_RETRIES:-3}"
  local attempt=1
  local err_log
  err_log="$(mktemp -t meztli-generate.XXXXXX)"

  while [[ "$attempt" -le "$max_attempts" ]]; do
    set +e
    promptfoo generate dataset \
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
