#!/usr/bin/env bash
# Harness latency / token-usage benchmark — v3
#
# Compares LLM coding-agent harnesses on identical trivial prompts and
# (when comparable) the same underlying model. Captures wall-clock time
# and token usage where the harness exposes it.
#
# Design notes / honest caveats baked in:
#
# - Codex routes only to OpenAI; pi + claude here both route to an
#   Anthropic Claude model. So we run TWO GROUPS:
#       claude-class : pi (via github-copilot/claude-sonnet-4.5) vs claude
#       gpt-class    : pi (via github-copilot/gpt-5)             vs codex
#   Within a group everyone hits the same upstream model. Across groups
#   you cannot compare numbers — only "pi vs the native harness".
#
# - "Cold cache" on the client side is mostly theater: Anthropic/OpenAI
#   prompt caches are server-side and TTL'd. We default to client-fresh
#   (--no-session) for every call. If you really want to defeat the
#   server cache, pass -n to inject a random nonce into the prompt.
#
# - We do NOT clobber $HOME / $CODEX_HOME any more — that broke auth.
#   Each harness uses its real config.
#
# Usage:
#   ./harness-bench.sh [-r RUNS] [-g claude|gpt|both] [-n] [-w]
#
#   -r RUNS         Repetitions per (harness x prompt). Default: 3.
#   -g GROUP        Which comparison group(s). Default: claude.
#   -n              Nonce mode: prepend a random tag to each prompt to
#                   defeat server-side prompt caching. Pessimistic but
#                   realistic for "first-ever turn" scenarios.
#   -w              Warm-up pass first (one discarded call per harness).

set -uo pipefail

RUNS=3
GROUP="claude"
NONCE=0
WARM=0

while getopts "r:g:nwh" opt; do
  case "$opt" in
    r) RUNS="$OPTARG" ;;
    g) GROUP="$OPTARG" ;;
    n) NONCE=1 ;;
    w) WARM=1 ;;
    h|*) sed -n '2,32p' "$0"; exit 0 ;;
  esac
done

case "$GROUP" in
  claude|gpt|both) ;;
  *) echo "Bad group: $GROUP (want claude|gpt|both)" >&2; exit 2 ;;
esac

# Model pinning. Edit these if IDs change.
PI_CLAUDE_MODEL="github-copilot/claude-sonnet-4.5"
CLAUDE_MODEL="sonnet"          # claude CLI alias
PI_GPT_MODEL="github-copilot/gpt-5"
CODEX_MODEL=""                  # empty => codex default

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="results-${STAMP}.tsv"
RAW_DIR="raw-${STAMP}"
mkdir -p "$RAW_DIR"

PROMPTS=(
  "Reply with exactly the word: pong"
  "List the files in the current directory, then summarize what this project is in one sentence."
)

echo -e "group\tharness\tmodel\tprompt_id\twall_sec\tinput_tokens\tcache_read\toutput_tokens\ttotal_tokens\tstop_reason" > "$OUT"

time_cmd() {
  local out="$1"; shift
  local err="$1"; shift
  local start end
  start=$(date +%s.%N)
  "$@" >"$out" 2>"$err"
  end=$(date +%s.%N)
  awk -v s="$start" -v e="$end" 'BEGIN{printf "%.3f", e-s}'
}

maybe_nonce() {
  if [[ $NONCE -eq 1 ]]; then
    printf '[bench-nonce %s] %s' "$(date +%s%N)-$RANDOM" "$1"
  else
    printf '%s' "$1"
  fi
}

# ---- runners ---------------------------------------------------------

# Pi emits one JSON event per line. The last `agent_end` event carries
# final usage on its last assistant message. Use jq to extract cleanly.
run_pi() {
  local prompt="$1" tag="$2" group="$3" model="$4"
  local out="$RAW_DIR/pi-${group}-${tag}.jsonl" err="$RAW_DIR/pi-${group}-${tag}.err"
  local wall
  wall=$(time_cmd "$out" "$err" \
    pi --mode json -p --no-session --thinking off \
       --model "$model" \
       "$(maybe_nonce "$prompt")")

  local usage stop in_t cr out_t tot
  # Grab the assistant message from the agent_end event (last line).
  usage=$(tail -1 "$out" \
    | jq -c 'try (.messages | map(select(.role=="assistant")) | last | .usage) // empty' 2>/dev/null)
  stop=$(tail -1 "$out" \
    | jq -r 'try (.messages | map(select(.role=="assistant")) | last | .stopReason) // "?"' 2>/dev/null)

  if [[ -n "$usage" && "$usage" != "null" ]]; then
    in_t=$(jq -r '.input // "NA"'       <<<"$usage")
    cr=$(jq -r   '.cacheRead // "NA"'   <<<"$usage")
    out_t=$(jq -r '.output // "NA"'     <<<"$usage")
    tot=$(jq -r  '.totalTokens // "NA"' <<<"$usage")
  else
    in_t=NA cr=NA out_t=NA tot=NA
  fi
  echo -e "$group\tpi\t$model\t$tag\t$wall\t$in_t\t$cr\t$out_t\t$tot\t$stop"
}

# claude --output-format json emits one JSON object with usage + is_error.
run_claude() {
  local prompt="$1" tag="$2" group="$3"
  local out="$RAW_DIR/claude-${group}-${tag}.json" err="$RAW_DIR/claude-${group}-${tag}.err"
  local wall
  wall=$(time_cmd "$out" "$err" \
    claude -p --output-format json \
           --model "$CLAUDE_MODEL" \
           --no-session-persistence \
           "$(maybe_nonce "$prompt")")

  local in_t cr out_t stop is_err result
  in_t=$(jq -r  '.usage.input_tokens // "NA"'            "$out" 2>/dev/null)
  cr=$(jq -r    '.usage.cache_read_input_tokens // "NA"' "$out" 2>/dev/null)
  out_t=$(jq -r '.usage.output_tokens // "NA"'           "$out" 2>/dev/null)
  is_err=$(jq -r '.is_error // false'                    "$out" 2>/dev/null)
  result=$(jq -r '.result // ""'                         "$out" 2>/dev/null)
  if [[ "$is_err" == "true" ]]; then
    stop="ERROR:${result:0:60}"
  else
    stop=$(jq -r '.stop_reason // "?"' "$out" 2>/dev/null)
  fi
  echo -e "$group\tclaude\t$CLAUDE_MODEL\t$tag\t$wall\t$in_t\t$cr\t$out_t\tNA\t$stop"
}

# Codex emits human-readable output. We grep for a token-usage footer if present.
run_codex() {
  local prompt="$1" tag="$2" group="$3"
  local out="$RAW_DIR/codex-${group}-${tag}.txt" err="$RAW_DIR/codex-${group}-${tag}.err"
  local wall
  local -a cmd=(codex exec --skip-git-repo-check)
  [[ -n "$CODEX_MODEL" ]] && cmd+=(--model "$CODEX_MODEL")
  cmd+=("$(maybe_nonce "$prompt")")
  wall=$(time_cmd "$out" "$err" "${cmd[@]}")

  local tot stop="ok"
  tot=$(grep -oiE 'tokens used:?[[:space:]]*[0-9]+' "$out" | tail -1 | grep -oE '[0-9]+')
  grep -qiE 'error|unauthorized|failed' "$err" && stop="ERROR"
  echo -e "$group\tcodex\t${CODEX_MODEL:-default}\t$tag\t$wall\tNA\tNA\tNA\t${tot:-NA}\t$stop"
}

# ---- driver ----------------------------------------------------------

run_group_claude() {
  local i="$1" p_idx="$2" prompt="$3" tag="$4"
  for h in pi claude; do
    command -v "$h" >/dev/null 2>&1 || { echo "  skip $h"; continue; }
    if [[ "$h" == pi ]]; then
      line=$(run_pi     "$prompt" "$tag" claude "$PI_CLAUDE_MODEL")
    else
      line=$(run_claude "$prompt" "$tag" claude)
    fi
    echo "  $line"
    echo -e "$line" >> "$OUT"
  done
}

run_group_gpt() {
  local i="$1" p_idx="$2" prompt="$3" tag="$4"
  for h in pi codex; do
    command -v "$h" >/dev/null 2>&1 || { echo "  skip $h"; continue; }
    if [[ "$h" == pi ]]; then
      line=$(run_pi    "$prompt" "$tag" gpt "$PI_GPT_MODEL")
    else
      line=$(run_codex "$prompt" "$tag" gpt)
    fi
    echo "  $line"
    echo -e "$line" >> "$OUT"
  done
}

if [[ $WARM -eq 1 ]]; then
  echo "=== warm-up pass (discarded) ==="
  [[ "$GROUP" == claude || "$GROUP" == both ]] && run_group_claude 0 0 "warmup" "warmup" >/dev/null
  [[ "$GROUP" == gpt    || "$GROUP" == both ]] && run_group_gpt    0 0 "warmup" "warmup" >/dev/null
fi

for i in $(seq 1 "$RUNS"); do
  for p_idx in "${!PROMPTS[@]}"; do
    prompt="${PROMPTS[$p_idx]}"
    tag="p${p_idx}-r${i}"
    echo "=== run $i / prompt $p_idx ==="
    [[ "$GROUP" == claude || "$GROUP" == both ]] && run_group_claude "$i" "$p_idx" "$prompt" "$tag"
    [[ "$GROUP" == gpt    || "$GROUP" == both ]] && run_group_gpt    "$i" "$p_idx" "$prompt" "$tag"
  done
done

echo
echo "Raw results: $OUT"
echo "Per-call output: $RAW_DIR/"
echo
echo "=== Summary (mean wall-clock & input tokens, by group/harness/prompt) ==="
awk -F'\t' 'NR>1 {
  # Strip "-rN" suffix from prompt_id so we average across runs.
  pid=$4; sub(/-r[0-9]+$/, "", pid)
  key=$1"\t"$2"\t"pid
  wall[key]+=$5; n[key]++
  if ($6 != "NA") { in_t[key]+=$6; in_n[key]++ }
  if ($7 != "NA") { cr[key]+=$7;   cr_n[key]++ }
  if ($10 ~ /ERROR/) errs[key]++
}
END {
  printf "%-8s %-8s %-6s %4s %10s %12s %12s %6s\n", "group", "harness", "prompt", "n", "mean_sec", "mean_input", "mean_cache", "errs"
  for (k in wall) {
    split(k, a, "\t")
    mt  = (in_n[k]>0) ? sprintf("%.0f", in_t[k]/in_n[k]) : "NA"
    mc  = (cr_n[k]>0) ? sprintf("%.0f", cr[k]/cr_n[k])  : "NA"
    e   = (k in errs) ? errs[k] : 0
    printf "%-8s %-8s %-6s %4d %10.2f %12s %12s %6d\n", a[1], a[2], a[3], n[k], wall[k]/n[k], mt, mc, e
  }
}' "$OUT" | awk 'NR==1; NR>1' | { IFS= read -r hdr; echo "$hdr"; sort; }
