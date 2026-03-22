#!/usr/bin/env bash
# harness/eval.sh — LLM behavior eval for keel skill
#
# Runs claude -p with haiku model, captures transcript, grades with grader agent.
# Compatible with skill-creator's grading.json / benchmark.json schemas.
#
# Usage:
#   bash harness/eval.sh                    # Run all evals
#   bash harness/eval.sh --eval-id 1        # Run single eval
#   bash harness/eval.sh --dry-run          # Show what would run without executing
#
# Prerequisites: claude CLI, jq

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EVALS_FILE="$SCRIPT_DIR/evals/llm-evals.json"
SKILL_CREATOR_PATH="/home/ryo-morimoto/.claude/plugins/cache/claude-plugins-official/skill-creator/7994c270e575/skills/skill-creator"
GRADER_MD="$SKILL_CREATOR_PATH/agents/grader.md"

MODEL="haiku"
TIMEOUT=120  # seconds per eval
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="$SCRIPT_DIR/results/eval-$TIMESTAMP"
mkdir -p "$RESULTS_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Parse args
FILTER_ID=""
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --eval-id) FILTER_ID="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

TOTAL_EVALS=0
TOTAL_PASS=0
TOTAL_FAIL=0

# ─── Run a single eval ───────────────────────────────────────────────

run_eval() {
  local eval_id="$1"
  local prompt="$2"
  local expected="$3"
  local expectations_json="$4"
  local eval_name="$5"

  local eval_dir="$RESULTS_DIR/eval-${eval_id}"
  mkdir -p "$eval_dir/outputs"

  echo -e "\n${CYAN}[Eval $eval_id]${NC} $eval_name"
  echo -e "  Prompt: ${prompt:0:80}..."

  if $DRY_RUN; then
    echo -e "  ${YELLOW}(dry-run — skipped)${NC}"
    return
  fi

  # ── Step 1: Run claude -p with skill injected and capture transcript ──

  echo -e "  Running claude -p --model $MODEL (skill injected) ..."
  local transcript_file="$eval_dir/transcript.jsonl"
  local result_file="$eval_dir/result.json"
  local start_time=$(date +%s)

  # Inject skill content directly into the prompt so the model follows keel
  # regardless of whether auto-triggering fires.
  local skill_md="$PROJECT_ROOT/skills/keel/SKILL.md"
  local skill_content
  skill_content=$(cat "$skill_md")

  local injected_prompt
  injected_prompt="$(cat <<INJECT_EOF
<skill name="keel">
$skill_content
</skill>

The above skill is active for this session. Follow its instructions exactly.

User task: $prompt
INJECT_EOF
)"

  # Remove CLAUDECODE env var to allow nesting
  local env_filter="CLAUDECODE"
  (
    unset $env_filter 2>/dev/null
    timeout "$TIMEOUT" claude -p "$injected_prompt" \
      --model "$MODEL" \
      --output-format stream-json \
      --verbose \
      2>/dev/null
  ) > "$transcript_file" 2>/dev/null || true

  local end_time=$(date +%s)
  local duration=$((end_time - start_time))

  # ── Step 2: Extract key events from transcript ──

  # Extract the final result
  local result_line
  result_line=$(command grep '"type":"result"' "$transcript_file" | tail -1)
  if [[ -n "$result_line" ]]; then
    echo "$result_line" | jq '.' > "$result_file" 2>/dev/null
  fi

  # Extract all tool_use calls (Bash calls to keel.sh, Agent calls, etc.)
  local tool_calls_file="$eval_dir/tool_calls.jsonl"
  command grep '"tool_use"' "$transcript_file" | jq -c '
    select(.type == "assistant")
    | .message.content[]?
    | select(.type == "tool_use")
    | {name: .name, input: .input}
  ' > "$tool_calls_file" 2>/dev/null || true

  # Extract readable transcript for grader
  local readable_file="$eval_dir/transcript_readable.md"
  {
    echo "# Eval $eval_id: $eval_name"
    echo ""
    echo "## Prompt"
    echo "$prompt"
    echo ""
    echo "## Tool Calls"
    if [[ -s "$tool_calls_file" ]]; then
      while IFS= read -r line; do
        local tool_name input_summary
        tool_name=$(echo "$line" | jq -r '.name')
        case "$tool_name" in
          Bash)
            input_summary=$(echo "$line" | jq -r '.input.command // ""' | head -3)
            echo "- **Bash**: \`$input_summary\`"
            ;;
          Agent)
            input_summary=$(echo "$line" | jq -r '.input.description // .input.prompt[:100] // ""')
            echo "- **Agent** ($( echo "$line" | jq -r '.input.subagent_type // "general"')): $input_summary"
            ;;
          Skill)
            echo "- **Skill**: $(echo "$line" | jq -r '.input.skill // ""')"
            ;;
          Read|Edit|Write|Glob|Grep)
            echo "- **$tool_name**: $(echo "$line" | jq -r '.input.file_path // .input.pattern // ""' | head -1)"
            ;;
          *)
            echo "- **$tool_name**"
            ;;
        esac
      done < "$tool_calls_file"
    else
      echo "(no tool calls captured)"
    fi
    echo ""
    echo "## Final Output"
    if [[ -f "$result_file" ]]; then
      jq -r '.result // "(no result)"' "$result_file" 2>/dev/null | head -50
    else
      echo "(no result captured)"
    fi
  } > "$readable_file"

  # Save timing
  local total_tokens duration_ms
  total_tokens=$(jq -r '.usage.input_tokens + .usage.output_tokens // 0' "$result_file" 2>/dev/null || echo "0")
  duration_ms=$((duration * 1000))
  jq -cn \
    --argjson total_tokens "$total_tokens" \
    --argjson duration_ms "$duration_ms" \
    --argjson total_duration_seconds "$duration" \
    '{total_tokens: $total_tokens, duration_ms: $duration_ms, total_duration_seconds: $total_duration_seconds}' \
    > "$eval_dir/timing.json"

  echo -e "  Completed in ${duration}s"

  # ── Step 3: Grade with grader agent ──

  echo -e "  Grading..."

  local expectations_list
  expectations_list=$(echo "$expectations_json" | jq -r '.[]')

  local grader_prompt
  grader_prompt="$(cat <<GRADER_EOF
You are a grader evaluating whether an AI agent correctly followed the keel orchestration skill.

## Expectations to evaluate
$(echo "$expectations_json" | jq -r 'to_entries[] | "- \(.value)"')

## Transcript
$(cat "$readable_file")

## Instructions

For each expectation, determine PASS or FAIL based on evidence in the transcript.

Key things to look for:
- Bash tool calls containing "keel.sh init-phases" with the expected severity
- Bash tool calls containing "keel.sh advance"
- Agent tool calls for severity classification or investigation
- Whether certain phases were skipped or entered

Output ONLY a valid JSON object with this exact structure (no markdown fences):
{
  "expectations": [
    {"text": "<expectation text>", "passed": true/false, "evidence": "<quote or description>"}
  ],
  "summary": {"passed": N, "failed": N, "total": N, "pass_rate": 0.XX}
}
GRADER_EOF
)"

  local grading_file="$eval_dir/grading.json"

  local grader_output
  grader_output=$(
    unset CLAUDECODE 2>/dev/null
    claude -p "$grader_prompt" --model "$MODEL" --output-format text 2>/dev/null
  ) || true

  # Try to parse as JSON, handle markdown-wrapped responses
  local parsed_grading
  parsed_grading=$(echo "$grader_output" | jq '.' 2>/dev/null) || \
  parsed_grading=$(echo "$grader_output" | sed -n '/^```json/,/^```/p' | sed '1d;$d' | jq '.' 2>/dev/null) || \
  parsed_grading=$(echo "$grader_output" | sed -n '/^{/,/^}/p' | jq '.' 2>/dev/null) || true

  if [[ -n "$parsed_grading" ]]; then
    echo "$parsed_grading" > "$grading_file"
  else
    # Fallback: create grading from raw output
    echo -e "  ${YELLOW}Grader output not valid JSON, creating fallback grading${NC}"
    local num_expectations
    num_expectations=$(echo "$expectations_json" | jq 'length')
    local fallback_expectations="["
    for i in $(seq 0 $((num_expectations - 1))); do
      [[ $i -gt 0 ]] && fallback_expectations+=","
      local exp_text
      exp_text=$(echo "$expectations_json" | jq -r ".[$i]")
      fallback_expectations+=$(jq -cn --arg text "$exp_text" \
        '{text: $text, passed: false, evidence: "Grader output could not be parsed"}')
    done
    fallback_expectations+="]"
    jq -cn --argjson expectations "$fallback_expectations" \
      --argjson total "$num_expectations" \
      '{expectations: $expectations, summary: {passed: 0, failed: $total, total: $total, pass_rate: 0}}' \
      > "$grading_file"
  fi

  # ── Step 4: Print results ──

  local pass_count fail_count
  pass_count=$(jq -r '.summary.passed // 0' "$grading_file")
  fail_count=$(jq -r '.summary.failed // 0' "$grading_file")
  local exp_count
  exp_count=$(jq -r '.summary.total // 0' "$grading_file")

  jq -r '.expectations[] | if .passed then "  \u001b[32m✓\u001b[0m \(.text)" else "  \u001b[31m✗\u001b[0m \(.text)\n    \u001b[33m→ \(.evidence)\u001b[0m" end' "$grading_file" 2>/dev/null || \
    echo -e "  ${YELLOW}(could not display grading)${NC}"

  TOTAL_EVALS=$((TOTAL_EVALS + exp_count))
  TOTAL_PASS=$((TOTAL_PASS + pass_count))
  TOTAL_FAIL=$((TOTAL_FAIL + fail_count))

  # Write eval_metadata.json (skill-creator compatible)
  jq -cn \
    --argjson eval_id "$eval_id" \
    --arg eval_name "$eval_name" \
    --arg prompt "$prompt" \
    --argjson expectations "$expectations_json" \
    '{eval_id: $eval_id, eval_name: $eval_name, prompt: $prompt, assertions: $expectations}' \
    > "$eval_dir/eval_metadata.json"
}

# ─── Main ─────────────────────────────────────────────────────────────

echo -e "${BOLD}keel eval — LLM behavior evaluation${NC}"
echo "Model:   $MODEL"
echo "Results: $RESULTS_DIR"
echo "Evals:   $EVALS_FILE"

eval_count=$(jq '.evals | length' "$EVALS_FILE")

for i in $(seq 0 $((eval_count - 1))); do
  eval_id=$(jq -r ".evals[$i].id" "$EVALS_FILE")
  if [[ -n "$FILTER_ID" && "$eval_id" != "$FILTER_ID" ]]; then continue; fi

  prompt=$(jq -r ".evals[$i].prompt" "$EVALS_FILE")
  expected=$(jq -r ".evals[$i].expected_output" "$EVALS_FILE")
  expectations=$(jq -c ".evals[$i].expectations" "$EVALS_FILE")
  eval_name=$(jq -r ".evals[$i].prompt[:60]" "$EVALS_FILE")

  run_eval "$eval_id" "$prompt" "$expected" "$expectations" "$eval_name"
done

# ─── Summary ──────────────────────────────────────────────────────────

if ! $DRY_RUN; then
  echo ""
  echo "─────────────────────────────────────"
  echo -e "Results: ${GREEN}$TOTAL_PASS passed${NC}, ${RED}$TOTAL_FAIL failed${NC}, $TOTAL_EVALS total"
  echo "Artifacts: $RESULTS_DIR"

  # Generate aggregate benchmark.json
  if command -v python3 &>/dev/null; then
    echo ""
    echo "Generating benchmark..."
    # Build benchmark.json inline since we have all data
    local_benchmark="$RESULTS_DIR/benchmark.json"
    jq -cn \
      --arg skill_name "keel" \
      --arg model "$MODEL" \
      --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{metadata: {skill_name: $skill_name, executor_model: $model, timestamp: $timestamp}}' \
      > "$local_benchmark"
    echo "Benchmark: $local_benchmark"
  fi

  if [[ $TOTAL_FAIL -eq 0 ]]; then
    echo -e "\n${GREEN}ALL EVALS PASS${NC}"
    exit 0
  else
    echo -e "\n${RED}$TOTAL_FAIL FAILURES${NC}"
    exit 1
  fi
fi
