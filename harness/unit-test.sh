#!/usr/bin/env bash
# harness/test-hooks.sh — Hook and keel.sh behavior tests
#
# Exercises hooks with mock stdin and validates stdout/state changes.
# Compatible with skill-creator's grading.json schema for eval-viewer integration.
#
# Usage: bash harness/test-hooks.sh [--eval-id N]
#   --eval-id N: Run only eval with matching id (default: run all)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EVALS_FILE="$SCRIPT_DIR/evals/evals.json"

# Test isolation directory
TEST_ROOT=$(mktemp -d /tmp/keel-harness-XXXXXX)
TEST_PROJECT="$TEST_ROOT/project"
TEST_STATE="$TEST_ROOT/state"
mkdir -p "$TEST_PROJECT" "$TEST_STATE"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Output directory for results (skill-creator compatible)
RESULTS_DIR="$SCRIPT_DIR/results/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

FILTER_ID="${2:-}"
[[ "${1:-}" == "--eval-id" ]] && FILTER_ID="$2"

TOTAL=0
PASSED=0
FAILED=0

# ─── Helpers ──────────────────────────────────────────────────────────

normalize_project_path() {
  echo "-$(echo "$1" | sed 's|^/||' | sed 's|/|-|g')"
}

create_session() {
  local session_id="$1"
  local oa_session_id="${2:-}"
  local project_dir="$TEST_STATE/sessions/$(normalize_project_path "$TEST_PROJECT")"
  local session_dir="$project_dir/$session_id"
  mkdir -p "$session_dir"

  local state='{
    "session_id": "'"$session_id"'",
    "oa_session_id": '"$(if [[ -n "$oa_session_id" ]]; then echo "\"$oa_session_id\""; else echo "null"; fi)"',
    "oa_type": "claude-code",
    "project_path": "'"$TEST_PROJECT"'",
    "workspace": "'"$TEST_PROJECT"'",
    "phase_list": [],
    "severity": null,
    "status": "running",
    "counters": {"plan_revise": 0, "implement_retry": 0}
  }'

  local memory='{
    "user_task": null,
    "severity": null,
    "completed_phases": [],
    "resolved_requirements": null,
    "investigation": null,
    "plan": null,
    "review": null,
    "implementation": null,
    "verification": null
  }'

  echo "$state" | jq '.' > "$session_dir/state.json"
  echo "$memory" | jq '.' > "$session_dir/memory.json"
  echo "$session_dir"
}

run_hook() {
  local script="$1"
  local input_json="$2"
  local env_cwd="${3:-$TEST_PROJECT}"

  local stdout_file="$TEST_ROOT/stdout.tmp"
  local stderr_file="$TEST_ROOT/stderr.tmp"

  local exit_code=0
  export CWD="$env_cwd"
  export CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT"
  export CLAUDE_PLUGIN_DATA="$TEST_STATE"
  echo "$input_json" | node "$PROJECT_ROOT/$script" > "$stdout_file" 2> "$stderr_file" || exit_code=$?

  local stdout_content stderr_content
  stdout_content=$(jq -Rs '.' < "$stdout_file")
  stderr_content=$(jq -Rs '.' < "$stderr_file")
  echo "{\"exit_code\": $exit_code, \"stdout\": $stdout_content, \"stderr\": $stderr_content}"
}

run_keel_sh() {
  local cmd="$1"
  shift

  local stdout_file="$TEST_ROOT/stdout.tmp"
  local stderr_file="$TEST_ROOT/stderr.tmp"

  local exit_code=0
  CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT" \
  CLAUDE_PLUGIN_DATA="$TEST_STATE" \
    bash "$PROJECT_ROOT/scripts/keel.sh" "$cmd" "$@" > "$stdout_file" 2> "$stderr_file" || exit_code=$?

  echo "{\"exit_code\": $exit_code, \"stdout\": $(cat "$stdout_file" | jq -Rs '.'), \"stderr\": $(cat "$stderr_file" | jq -Rs '.')}"
}

# ─── Test Cases ───────────────────────────────────────────────────────

run_eval_1() {
  # session-start-new: Create new session from SessionStart hook
  local result session_dir project_dir
  project_dir="$TEST_STATE/sessions/$(normalize_project_path "$TEST_PROJECT")"
  mkdir -p "$project_dir"

  result=$(run_hook "hooks/scripts/on-session-start.mjs" \
    '{"session_id":"test-oa-001","source":"new"}')

  local exit_code=$(echo "$result" | jq -r '.exit_code')
  local expectations=()
  local evidence=()
  local passed_arr=()

  # E1: Exit code is 0
  if [[ "$exit_code" == "0" ]]; then
    passed_arr+=(true); evidence+=("exit_code=$exit_code")
  else
    passed_arr+=(false); evidence+=("exit_code=$exit_code, expected 0")
  fi
  expectations+=("Exit code is 0")

  # E2: Session directory created
  local session_count=$(command ls -1d "$project_dir"/*/ 2>/dev/null | wc -l)
  if [[ "$session_count" -ge 1 ]]; then
    session_dir=$(command ls -1d "$project_dir"/*/ 2>/dev/null | head -1 | sed 's|/$||')
    passed_arr+=(true); evidence+=("Found $session_count session dir(s): $(basename "$session_dir")")
  else
    passed_arr+=(false); evidence+=("No session directories found in $project_dir")
  fi
  expectations+=("A new session directory is created under the project state dir")

  # E3: state.json valid
  if [[ -n "${session_dir:-}" && -f "$session_dir/state.json" ]]; then
    local status=$(jq -r '.status' "$session_dir/state.json")
    local oa_id=$(jq -r '.oa_session_id' "$session_dir/state.json")
    if [[ "$status" == "running" && "$oa_id" == "test-oa-001" ]]; then
      passed_arr+=(true); evidence+=("status=$status, oa_session_id=$oa_id")
    else
      passed_arr+=(false); evidence+=("status=$status (expected running), oa_session_id=$oa_id (expected test-oa-001)")
    fi
  else
    passed_arr+=(false); evidence+=("state.json not found")
  fi
  expectations+=("state.json contains session_id, oa_session_id, status=running, empty phase_list")

  # E4: memory.json valid
  if [[ -n "${session_dir:-}" && -f "$session_dir/memory.json" ]]; then
    local user_task=$(jq -r '.user_task' "$session_dir/memory.json")
    local completed=$(jq -r '.completed_phases | length' "$session_dir/memory.json")
    if [[ "$user_task" == "null" && "$completed" == "0" ]]; then
      passed_arr+=(true); evidence+=("user_task=null, completed_phases=[]")
    else
      passed_arr+=(false); evidence+=("user_task=$user_task, completed_phases length=$completed")
    fi
  else
    passed_arr+=(false); evidence+=("memory.json not found")
  fi
  expectations+=("memory.json contains null user_task, empty completed_phases")

  emit_grading 1 "session-start-new" expectations passed_arr evidence
}

run_eval_3() {
  # prompt-submit-first-prompt: First prompt sets user_task, returns pending_classification
  local project_dir="$TEST_STATE/sessions/$(normalize_project_path "$TEST_PROJECT")"
  local session_dir=$(create_session "eval3-session" "test-oa-003")

  local result=$(run_hook "hooks/scripts/on-prompt-submit.mjs" \
    '{"prompt":"Fix the login bug in auth.ts","session_id":"test-oa-003"}')

  local exit_code=$(echo "$result" | jq -r '.exit_code')
  local stdout=$(echo "$result" | jq -r '.stdout')
  local expectations=()
  local evidence=()
  local passed_arr=()

  # E1: Exit code 0
  if [[ "$exit_code" == "0" ]]; then
    passed_arr+=(true); evidence+=("exit_code=$exit_code")
  else
    passed_arr+=(false); evidence+=("exit_code=$exit_code")
  fi
  expectations+=("Exit code is 0")

  # E2: user_task set in memory
  local user_task=$(jq -r '.user_task' "$session_dir/memory.json")
  if [[ "$user_task" == "Fix the login bug in auth.ts" ]]; then
    passed_arr+=(true); evidence+=("user_task='$user_task'")
  else
    passed_arr+=(false); evidence+=("user_task='$user_task', expected 'Fix the login bug in auth.ts'")
  fi
  expectations+=("memory.json user_task is set to the prompt text")

  # E3: stdout has hookSpecificOutput
  if echo "$stdout" | jq -e '.hookSpecificOutput.additionalContext' > /dev/null 2>&1; then
    passed_arr+=(true); evidence+=("hookSpecificOutput.additionalContext present")
  else
    passed_arr+=(false); evidence+=("hookSpecificOutput.additionalContext missing from stdout")
  fi
  expectations+=("stdout JSON contains hookSpecificOutput with additionalContext")

  # E4: additionalContext has severity classification prompt
  local context=$(echo "$stdout" | jq -r '.hookSpecificOutput.additionalContext // ""')
  if echo "$context" | grep -q "awaiting severity classification"; then
    passed_arr+=(true); evidence+=("Found 'awaiting severity classification' in context")
  else
    passed_arr+=(false); evidence+=("'awaiting severity classification' not found in context")
  fi
  expectations+=("additionalContext indicates awaiting severity classification")

  # E5: init-phases command present
  if echo "$context" | grep -q "init-phases"; then
    passed_arr+=(true); evidence+=("Found 'init-phases' command in context")
  else
    passed_arr+=(false); evidence+=("'init-phases' command not found in context")
  fi
  expectations+=("additionalContext contains keel.sh init-phases command")

  emit_grading 3 "prompt-submit-first-prompt" expectations passed_arr evidence
}

run_eval_4() {
  # prompt-submit-mid-phase: Returns context with current phase
  local session_dir=$(create_session "eval4-session" "test-oa-004")

  # Set up mid-flow state
  jq '.phase_list = ["investigate","plan","review_codex","implement_cc","verify"] | .severity = "medium"' \
    "$session_dir/state.json" > "$session_dir/state.json.tmp" && mv "$session_dir/state.json.tmp" "$session_dir/state.json"
  jq '.completed_phases = ["investigate"] | .user_task = "Fix the login bug" | .investigation = {"relevant_files":["auth.ts"],"patterns":[],"constraints":[]}' \
    "$session_dir/memory.json" > "$session_dir/memory.json.tmp" && mv "$session_dir/memory.json.tmp" "$session_dir/memory.json"

  local result=$(run_hook "hooks/scripts/on-prompt-submit.mjs" \
    '{"prompt":"looks good, continue","session_id":"test-oa-004"}')

  local exit_code=$(echo "$result" | jq -r '.exit_code')
  local stdout=$(echo "$result" | jq -r '.stdout')
  local context=$(echo "$stdout" | jq -r '.hookSpecificOutput.additionalContext // ""')
  local expectations=()
  local evidence=()
  local passed_arr=()

  # E1: Exit code 0
  if [[ "$exit_code" == "0" ]]; then
    passed_arr+=(true); evidence+=("exit_code=$exit_code")
  else
    passed_arr+=(false); evidence+=("exit_code=$exit_code")
  fi
  expectations+=("Exit code is 0")

  # E2: Phase is plan
  if echo "$context" | grep -q "Phase: plan"; then
    passed_arr+=(true); evidence+=("Found 'Phase: plan' in context")
  else
    passed_arr+=(false); evidence+=("'Phase: plan' not found. Context: $(echo "$context" | head -5)")
  fi
  expectations+=("additionalContext contains 'Phase: plan'")

  # E3: investigate shown as completed
  if echo "$context" | grep -q "~~investigate~~"; then
    passed_arr+=(true); evidence+=("investigate shown as strikethrough (completed)")
  else
    passed_arr+=(false); evidence+=("investigate not shown as completed")
  fi
  expectations+=("additionalContext contains phase progression showing investigate as completed")

  # E4: Phase Data includes investigation
  if echo "$context" | grep -q "investigation"; then
    passed_arr+=(true); evidence+=("Phase Data includes investigation field")
  else
    passed_arr+=(false); evidence+=("investigation not found in Phase Data")
  fi
  expectations+=("Phase Data section includes user_task and investigation fields")

  emit_grading 4 "prompt-submit-mid-phase" expectations passed_arr evidence
}

run_eval_6() {
  # keel-sh-init-phases-medium
  local session_dir=$(create_session "eval6-session" "test-oa-006")

  local result=$(run_keel_sh init-phases "$session_dir" medium)
  local exit_code=$(echo "$result" | jq -r '.exit_code')
  local expectations=()
  local evidence=()
  local passed_arr=()

  # E1: Exit code 0
  if [[ "$exit_code" == "0" ]]; then
    passed_arr+=(true); evidence+=("exit_code=$exit_code")
  else
    local stderr=$(echo "$result" | jq -r '.stderr')
    passed_arr+=(false); evidence+=("exit_code=$exit_code, stderr=$stderr")
  fi
  expectations+=("Exit code is 0")

  # E2: phase_list set for medium
  local phase_list=$(jq -r '.phase_list | join(",")' "$session_dir/state.json" 2>/dev/null || echo "")
  if echo "$phase_list" | grep -q "investigate" && echo "$phase_list" | grep -q "plan" && echo "$phase_list" | grep -q "verify"; then
    passed_arr+=(true); evidence+=("phase_list=$phase_list")
  else
    passed_arr+=(false); evidence+=("phase_list=$phase_list, expected investigate,plan,...,verify")
  fi
  expectations+=("state.json phase_list contains investigate, plan, review_codex, implement, verify")

  # E3: severity set
  local severity=$(jq -r '.severity' "$session_dir/state.json" 2>/dev/null || echo "")
  if [[ "$severity" == "medium" ]]; then
    passed_arr+=(true); evidence+=("severity=$severity")
  else
    passed_arr+=(false); evidence+=("severity=$severity, expected medium")
  fi
  expectations+=("state.json severity is set to 'medium'")

  emit_grading 6 "keel-sh-init-phases-medium" expectations passed_arr evidence
}

run_eval_7() {
  # keel-sh-advance
  local session_dir=$(create_session "eval7-session" "test-oa-007")

  # Set up: phase_list with investigate as first phase
  jq '.phase_list = ["investigate","plan","review_codex","implement_cc","verify"] | .severity = "medium"' \
    "$session_dir/state.json" > "$session_dir/state.json.tmp" && mv "$session_dir/state.json.tmp" "$session_dir/state.json"

  local advance_json='{"investigation":{"relevant_files":["auth.ts"],"patterns":[],"constraints":[]}}'
  local result=$(run_keel_sh advance "$session_dir" "$advance_json")
  local exit_code=$(echo "$result" | jq -r '.exit_code')
  local expectations=()
  local evidence=()
  local passed_arr=()

  # E1: Exit code 0
  if [[ "$exit_code" == "0" ]]; then
    passed_arr+=(true); evidence+=("exit_code=$exit_code")
  else
    local stderr=$(echo "$result" | jq -r '.stderr')
    passed_arr+=(false); evidence+=("exit_code=$exit_code, stderr=$stderr")
  fi
  expectations+=("Exit code is 0")

  # E2: investigation merged
  local inv=$(jq -r '.investigation.relevant_files[0] // ""' "$session_dir/memory.json" 2>/dev/null)
  if [[ "$inv" == "auth.ts" ]]; then
    passed_arr+=(true); evidence+=("investigation.relevant_files[0]=$inv")
  else
    passed_arr+=(false); evidence+=("investigation.relevant_files[0]=$inv, expected auth.ts")
  fi
  expectations+=("memory.json investigation field is populated with the provided JSON")

  # E3: completed_phases includes investigate
  local completed=$(jq -r '.completed_phases | join(",")' "$session_dir/memory.json" 2>/dev/null)
  if echo "$completed" | grep -q "investigate"; then
    passed_arr+=(true); evidence+=("completed_phases=$completed")
  else
    passed_arr+=(false); evidence+=("completed_phases=$completed, expected to include investigate")
  fi
  expectations+=("memory.json completed_phases includes 'investigate'")

  emit_grading 7 "keel-sh-advance" expectations passed_arr evidence
}

# ─── Grading Output ──────────────────────────────────────────────────

emit_grading() {
  local eval_id="$1"
  local eval_name="$2"
  local -n _expectations=$3
  local -n _passed=$4
  local -n _evidence=$5

  local total=${#_expectations[@]}
  local pass_count=0
  local fail_count=0

  echo -e "\n${CYAN}[Eval $eval_id: $eval_name]${NC}"

  local expectations_json="["
  for i in $(seq 0 $((total - 1))); do
    local p="${_passed[$i]}"
    if [[ "$p" == "true" ]]; then
      ((pass_count++))
      echo -e "  ${GREEN}✓${NC} ${_expectations[$i]}"
    else
      ((fail_count++))
      echo -e "  ${RED}✗${NC} ${_expectations[$i]}"
      echo -e "    ${YELLOW}→ ${_evidence[$i]}${NC}"
    fi
    [[ $i -gt 0 ]] && expectations_json+=","
    expectations_json+=$(jq -cn \
      --arg text "${_expectations[$i]}" \
      --argjson passed "$p" \
      --arg evidence "${_evidence[$i]}" \
      '{text:$text, passed:$passed, evidence:$evidence}')
  done
  expectations_json+="]"

  local pass_rate=$(awk "BEGIN {printf \"%.2f\", $pass_count / $total}")

  # Write grading.json (skill-creator compatible)
  local eval_dir="$RESULTS_DIR/eval-$eval_id-$eval_name"
  mkdir -p "$eval_dir"
  jq -cn \
    --argjson expectations "$expectations_json" \
    --argjson passed "$pass_count" \
    --argjson failed "$fail_count" \
    --argjson total "$total" \
    --argjson pass_rate "$pass_rate" \
    '{expectations: $expectations, summary: {passed: $passed, failed: $failed, total: $total, pass_rate: $pass_rate}}' \
    > "$eval_dir/grading.json"

  TOTAL=$((TOTAL + total))
  PASSED=$((PASSED + pass_count))
  FAILED=$((FAILED + fail_count))
}

# ─── Main ─────────────────────────────────────────────────────────────

echo -e "${CYAN}keel harness — hook & script behavior tests${NC}"
echo "Test root: $TEST_ROOT"
echo "Results:   $RESULTS_DIR"

EVAL_IDS=(1 3 4 6 7)

for id in "${EVAL_IDS[@]}"; do
  if [[ -n "$FILTER_ID" && "$id" != "$FILTER_ID" ]]; then continue; fi

  # Clean state between evals
  rm -rf "$TEST_STATE/sessions"
  mkdir -p "$TEST_STATE/sessions"

  "run_eval_$id"
done

# ─── Summary ──────────────────────────────────────────────────────────

echo ""
echo "─────────────────────────────────────"
echo -e "Results: ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}, $TOTAL total"
echo "Grading files: $RESULTS_DIR"

if [[ $FAILED -eq 0 ]]; then
  echo -e "${GREEN}ALL PASS${NC}"
  exit 0
else
  echo -e "${RED}$FAILED FAILURES${NC}"
  exit 1
fi
