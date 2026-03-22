#!/usr/bin/env bash
# keel.sh — Adaptive multi-agent orchestration CLI
#
# WHY Bash: Claude Code の Bash tool から直接呼べる。hook (Node.js) とは別レイヤー。
# WHY completed_phases: rewind/中断に耐える SSOT。index は乖離する。
# WHY gate validation: Claude が不完全な output で advance しても弾く。
# WHY run-review/run-implement: Claude がコマンドを組み立てるとミスる。自動構築。
# WHY structured logging: 障害横断収集 → 改善ループ。

set -euo pipefail

CMD="${1:?Usage: keel.sh <command> <args...>}"
SESSION_DIR="${2:?second argument required}"

STATE_FILE="$SESSION_DIR/state.json"
MEMORY_FILE="$SESSION_DIR/memory.json"
LOG_FILE="$SESSION_DIR/log.jsonl"

# WHY relative paths: plugin install 時は CLAUDE_PLUGIN_ROOT、standalone 時は dirname で解決
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PROMPTS_DIR="$PLUGIN_ROOT/references/prompts"
SCHEMAS_DIR="$PLUGIN_ROOT/references/schemas"

# WHY CLAUDE_PLUGIN_DATA: plugin 用永続データ。standalone 時は ~/.local/state/keel/
if [[ -n "${CLAUDE_PLUGIN_DATA:-}" ]]; then
  STATE_ROOT="$CLAUDE_PLUGIN_DATA/sessions"
else
  STATE_ROOT="$HOME/.local/state/keel"
fi

# --- Helpers ---

tmp_path() {
  local purpose="$1" ext="${2:-txt}"
  local project session_id
  project=$(jq -r '.project_path | split("/") | last' "$STATE_FILE" 2>/dev/null || echo "unknown")
  session_id=$(jq -r '.session_id[:8]' "$STATE_FILE" 2>/dev/null || echo "unknown")
  echo "/tmp/keel-${project}-${session_id}-${purpose}.${ext}"
}

fill_prompt() {
  local template_file="$1"
  local user_task investigation plan review files_to_modify verification_criteria
  user_task=$(jq -r '.user_task // ""' "$MEMORY_FILE")
  investigation=$(jq -c '.investigation // {}' "$MEMORY_FILE")
  plan=$(jq -c '.plan // {}' "$MEMORY_FILE")
  review=$(jq -c '.review // {}' "$MEMORY_FILE")
  files_to_modify=$(jq -r '.plan.files_to_modify // [] | join(", ")' "$MEMORY_FILE")
  verification_criteria=$(jq -r '.plan.verification_criteria // [] | join("; ")' "$MEMORY_FILE")

  local result
  result=$(cat "$template_file")
  result="${result//\{\{user_task\}\}/$user_task}"
  result="${result//\{\{investigation\}\}/$investigation}"
  result="${result//\{\{plan\}\}/$plan}"
  result="${result//\{\{review\}\}/$review}"
  result="${result//\{\{files_to_modify\}\}/$files_to_modify}"
  result="${result//\{\{verification_criteria\}\}/$verification_criteria}"
  echo "$result"
}

derive_phase() {
  local sf="${1:-$STATE_FILE}" mf="${2:-$MEMORY_FILE}"
  local phase_list completed
  phase_list=$(jq -r '.phase_list // [] | .[]' "$sf" 2>/dev/null)
  completed=$(jq -r '.completed_phases // [] | .[]' "$mf" 2>/dev/null)
  for phase in $phase_list; do
    if ! echo "$completed" | grep -qx "$phase"; then echo "$phase"; return; fi
  done
  if [[ -z "$phase_list" ]]; then echo "pending_classification"; else echo "done"; fi
}

log_entry() {
  local severity="$1" event="$2" detail="${3:-"{}"}"
  local ts session_id phase phase_total completed_count detail_json
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  session_id=$(jq -r '.session_id // "unknown"' "$STATE_FILE" 2>/dev/null || echo "unknown")
  phase=$(derive_phase)
  phase_total=$(jq -r '.phase_list | length' "$STATE_FILE" 2>/dev/null || echo "0")
  completed_count=$(jq -r '.completed_phases // [] | length' "$MEMORY_FILE" 2>/dev/null || echo "0")
  detail_json=$(echo "$detail" | jq -c '.' 2>/dev/null || echo '{}')
  jq -cn \
    --arg ts "$ts" --arg sev "$severity" --arg event "$event" \
    --arg sid "$session_id" --arg phase "$phase" \
    --argjson completed "$completed_count" --argjson total "$phase_total" \
    --argjson detail "$detail_json" \
    '{ts:$ts,severity:$sev,event:$event,session_id:$sid,phase:$phase,completed:$completed,phase_total:$total,detail:$detail}' \
    >> "$LOG_FILE"
}

jq_write() { local file="$1"; shift; jq "$@" "$file" > "$file.tmp" && mv "$file.tmp" "$file"; }

validate_schema() {
  local json="$1" schema_file="$2"
  if [[ -z "$schema_file" || ! -f "$schema_file" ]]; then return 0; fi
  for field in $(jq -r '.required[]' "$schema_file" 2>/dev/null); do
    if ! echo "$json" | jq -e --arg f "$field" 'has($f)' > /dev/null 2>&1; then
      echo "SCHEMA ERROR: missing required field '$field'" >&2; return 1
    fi
  done
}

try_parse_json() {
  local result
  result=$(echo "$1" | jq '.' 2>/dev/null) && [[ -n "$result" ]] && echo "$result" && return 0
  return 1
}

check_agent() {
  local binary="$1" status_cmd="$2"
  if ! command -v "$binary" > /dev/null 2>&1; then echo "missing"; return; fi
  if eval "$status_cmd" > /dev/null 2>&1; then echo "available"; else echo "no_auth"; fi
}

render_logs() {
  local input="$1" filter="$2" offset="$3" limit="$4" timeline_cols="$5"
  local filtered
  case "$filter" in
    --errors)   filtered=$(echo "$input" | jq -c 'select(.severity == "error" or .severity == "fatal")') ;;
    --warnings) filtered=$(echo "$input" | jq -c 'select(.severity == "warn" or .severity == "error" or .severity == "fatal")') ;;
    --jumps)    filtered=$(echo "$input" | jq -c 'select(.event == "phase.jump")') ;;
    *)          filtered="$input" ;;
  esac
  if [[ -z "$filtered" ]]; then return 0; fi
  if [[ "$filter" == "--timeline" ]]; then
    local cols="${timeline_cols:-[.ts, .severity, .event, .phase]}"
    if [[ "$limit" -eq 0 ]]; then echo "$input" | jq -r "$cols | @tsv" | tail -n +$((offset + 1)) | column -t
    else echo "$input" | jq -r "$cols | @tsv" | tail -n +$((offset + 1)) | head -n "$limit" | column -t; fi
  else
    if [[ "$limit" -eq 0 ]]; then echo "$filtered" | tail -n +$((offset + 1))
    else echo "$filtered" | tail -n +$((offset + 1)) | head -n "$limit"; fi
  fi
}

parse_log_opts() {
  FILTER=""; OFFSET=0; LIMIT=10
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --errors|--warnings|--timeline|--jumps) FILTER="$1"; shift ;;
      --offset) OFFSET="${2:?offset value required}"; shift 2 ;;
      --limit)  LIMIT="${2:?limit value required}"; shift 2 ;;
      --all)    LIMIT=0; shift ;;
      *) echo "Unknown option '$1'" >&2; exit 1 ;;
    esac
  done
}

# --- Pre-command validation ---

if [[ "$CMD" != "logs" ]]; then
  if [[ ! -f "$STATE_FILE" ]]; then echo "ERROR: state.json not found at $STATE_FILE" >&2; exit 1; fi
fi

# --- Commands ---

case "$CMD" in

  advance)
    PHASE_OUTPUT="${3:?phase-output JSON required}"
    CURRENT_PHASE=$(derive_phase)
    if [[ "$CURRENT_PHASE" == "done" || "$CURRENT_PHASE" == "pending_classification" ]]; then
      echo "ERROR: cannot advance — phase is $CURRENT_PHASE" >&2; exit 1
    fi
    jq --argjson output "$PHASE_OUTPUT" '. * $output' "$MEMORY_FILE" > "$MEMORY_FILE.tmp"
    GATE_ERROR=""
    case "$CURRENT_PHASE" in
      clarify)              jq -e '.resolved_requirements != null'             "$MEMORY_FILE.tmp" > /dev/null 2>&1 || GATE_ERROR="resolved_requirements required" ;;
      investigate)          jq -e '.investigation.relevant_files | length > 0' "$MEMORY_FILE.tmp" > /dev/null 2>&1 || GATE_ERROR="relevant_files must have >= 1 entry" ;;
      plan)                 jq -e '.plan.verification_criteria | length > 0'   "$MEMORY_FILE.tmp" > /dev/null 2>&1 || GATE_ERROR="verification_criteria must have >= 1 entry" ;;
      implement_cc|implement_cursor) jq -e '.implementation.changed_files | length > 0' "$MEMORY_FILE.tmp" > /dev/null 2>&1 || GATE_ERROR="changed_files must have >= 1 entry" ;;
      verify)               jq -e '.verification.result != null'               "$MEMORY_FILE.tmp" > /dev/null 2>&1 || GATE_ERROR="result required (pass or fail)" ;;
      review_codex)         jq -e '.review.verdict != null'                    "$MEMORY_FILE.tmp" > /dev/null 2>&1 || GATE_ERROR="verdict required (approve or revise)" ;;
    esac
    if [[ -n "$GATE_ERROR" ]]; then
      rm -f "$MEMORY_FILE.tmp"
      log_entry "error" "gate.failed" "$(jq -cn --arg p "$CURRENT_PHASE" --arg e "$GATE_ERROR" '{phase:$p,error:$e}')"
      echo "GATE FAILED ($CURRENT_PHASE): $GATE_ERROR" >&2; exit 1
    fi
    mv "$MEMORY_FILE.tmp" "$MEMORY_FILE"
    jq_write "$MEMORY_FILE" --arg p "$CURRENT_PHASE" '.completed_phases = ((.completed_phases // []) + [$p] | unique)'
    NEXT_PHASE=$(derive_phase)
    log_entry "info" "phase.advance" "$(jq -cn --arg from "$CURRENT_PHASE" --arg to "$NEXT_PHASE" '{from:$from,to:$to}')"
    echo "Advanced to phase: $NEXT_PHASE ($(jq -r '.completed_phases | length' "$MEMORY_FILE")/$(jq -r '.phase_list | length' "$STATE_FILE"))"
    ;;

  jump)
    TARGET_PHASE="${3:?target-phase required}"; shift 3; RESET_FIELDS=("$@")
    if ! jq -e --arg p "$TARGET_PHASE" '.phase_list | index($p) != null' "$STATE_FILE" > /dev/null 2>&1; then
      echo "ERROR: phase '$TARGET_PHASE' not found" >&2; exit 1
    fi
    FROM_PHASE=$(derive_phase)
    TARGET_INDEX=$(jq -r --arg p "$TARGET_PHASE" '.phase_list | to_entries[] | select(.value == $p) | .key' "$STATE_FILE" | head -1)
    PHASES_AFTER=$(jq -r --argjson idx "$TARGET_INDEX" '[.phase_list[$idx:][]] | @json' "$STATE_FILE")
    jq_write "$MEMORY_FILE" --argjson remove "$PHASES_AFTER" '.completed_phases = [(.completed_phases // [])[] | select(. as $p | $remove | index($p) | not)]'
    for field in "${RESET_FIELDS[@]}"; do jq_write "$MEMORY_FILE" --arg f "$field" '.[$f] = null'; done
    log_entry "warn" "phase.jump" "$(jq -cn --arg from "$FROM_PHASE" --arg to "$TARGET_PHASE" --arg resets "${RESET_FIELDS[*]:-}" '{from:$from,to:$to,reset_fields:$resets}')"
    echo "Jumped to phase: $TARGET_PHASE"
    if [[ ${#RESET_FIELDS[@]} -gt 0 ]]; then echo "Reset fields: ${RESET_FIELDS[*]}"; fi
    ;;

  done)
    SEVERITY=$(jq -r '.severity // "unknown"' "$STATE_FILE")
    VERIFY_RESULT=$(jq -r '.verification.result // "none"' "$MEMORY_FILE" 2>/dev/null || echo "none")
    CHANGED=$(jq -r '.implementation.changed_files // [] | length' "$MEMORY_FILE" 2>/dev/null || echo "0")
    COMPLETED=$(jq -r '.completed_phases // [] | length' "$MEMORY_FILE")
    jq_write "$STATE_FILE" '. + {status: "done"}'
    WORKSPACE=$(jq -r '.workspace // ""' "$STATE_FILE")
    PROJECT_PATH=$(jq -r '.project_path // ""' "$STATE_FILE")
    SESSION_ID_SHORT=$(jq -r '.session_id[:8]' "$STATE_FILE")
    if [[ -n "$WORKSPACE" && "$WORKSPACE" != "$PROJECT_PATH" ]]; then
      git -C "$PROJECT_PATH" wt -D "keel/${SESSION_ID_SHORT}" 2>/dev/null || true
      log_entry "info" "worktree.removed" "$(jq -cn --arg b "keel/${SESSION_ID_SHORT}" '{branch:$b}')"
    fi
    log_entry "info" "session.done" "$(jq -cn --argjson e "$COMPLETED" --arg s "$SEVERITY" --arg r "$VERIFY_RESULT" --argjson c "$CHANGED" '{phases_executed:$e,severity:$s,verify_result:$r,files_changed:$c}')"
    echo "Session marked as done."
    ;;

  counter)
    COUNTER_NAME="${3:?counter-name required}"
    jq_write "$STATE_FILE" --arg c "$COUNTER_NAME" '.counters[$c] += 1'
    VALUE=$(jq -r --arg c "$COUNTER_NAME" '.counters[$c]' "$STATE_FILE")
    log_entry "debug" "counter.increment" "$(jq -cn --arg n "$COUNTER_NAME" --argjson v "$VALUE" '{name:$n,value:$v}')"
    echo "$COUNTER_NAME=$VALUE"
    ;;

  clear-pending) jq_write "$STATE_FILE" 'del(.pending_choice)'; echo "Pending choice cleared." ;;

  check-agents)
    CODEX=$(check_agent "codex" "codex login status")
    CURSOR=$(check_agent "agent" "agent status")
    AGENTS=$(jq -cn --arg c "$CODEX" --arg a "$CURSOR" '{codex:$c,cursor:$a}')
    jq_write "$STATE_FILE" --argjson a "$AGENTS" '.agents = $a'
    log_entry "info" "agents.check" "$AGENTS"
    echo "$AGENTS" | jq -r 'to_entries[] | "  \(.key): \(.value)"'
    if [[ "$CODEX" != "available" ]]; then echo "⚠ codex ($CODEX): fallback to Claude Code"; fi
    if [[ "$CURSOR" != "available" ]]; then echo "⚠ cursor ($CURSOR): fallback to Claude Code"; fi
    ;;

  init-phases)
    SEVERITY="${3:?severity required}"
    if ! jq -e '.agents' "$STATE_FILE" > /dev/null 2>&1; then "$0" check-agents "$SESSION_DIR" > /dev/null 2>&1; fi
    CODEX_OK=$(jq -r '.agents.codex // "missing"' "$STATE_FILE")
    CURSOR_OK=$(jq -r '.agents.cursor // "missing"' "$STATE_FILE")
    IMPL="implement_cursor"; REVIEW="review_codex"
    if [[ "$CURSOR_OK" != "available" ]]; then IMPL="implement_cc"; fi
    if [[ "$CODEX_OK" != "available" ]]; then REVIEW="review_cc"; fi
    case "$SEVERITY" in
      trivial) PHASES='["implement_cc","verify"]' ;;
      small)   PHASES=$(jq -cn --arg i "$IMPL" '["investigate",$i,"verify","ur3"]') ;;
      medium)  PHASES=$(jq -cn --arg r "$REVIEW" --arg i "$IMPL" '["investigate","plan",$r,"plan_revise_loop","ur2",$i,"verify","ur3"]') ;;
      large)   PHASES=$(jq -cn --arg r "$REVIEW" --arg i "$IMPL" '["clarify","investigate","plan","ur1",$r,"plan_revise_loop","ur2",$i,"verify","ur3"]') ;;
      *) echo "ERROR: invalid severity '$SEVERITY'" >&2; exit 1 ;;
    esac
    jq_write "$STATE_FILE" --argjson p "$PHASES" --arg s "$SEVERITY" '.phase_list = $p | .severity = $s'
    jq_write "$MEMORY_FILE" --arg s "$SEVERITY" '.severity = $s'
    log_entry "info" "session.init" "$(jq -cn --arg s "$SEVERITY" --argjson p "$PHASES" --arg codex "$CODEX_OK" --arg cursor "$CURSOR_OK" '{severity:$s,phases:$p,agents:{codex:$codex,cursor:$cursor}}')"
    echo "Severity: $SEVERITY"
    echo "Phases: $(echo "$PHASES" | jq -r 'join(" → ")')"
    if [[ "$CURSOR_OK" != "available" ]]; then echo "⚠ cursor unavailable → implement_cc"; fi
    if [[ "$CODEX_OK" != "available" ]]; then echo "⚠ codex unavailable → review_cc"; fi
    ;;

  derive-phase) derive_phase ;;

  status)
    PHASE=$(derive_phase)
    COMPLETED=$(jq -r '.completed_phases // [] | length' "$MEMORY_FILE")
    TOTAL=$(jq -r '.phase_list | length' "$STATE_FILE")
    jq -r '"Session:   \(.session_id)\nOA:        \(.oa_type // "unknown") (\((.oa_session_id // "?")[:8]))\nWorkspace: \(.workspace // .project_path)"' "$STATE_FILE"
    jq -r '"Severity:  \(.severity // "unclassified")\nStatus:    \(.status // "running")"' "$STATE_FILE"
    echo "Phase:     $PHASE ($((COMPLETED + 1))/$TOTAL)"
    jq -r '"Counters:  plan_revise=\(.counters.plan_revise) implement_retry=\(.counters.implement_retry)"' "$STATE_FILE"
    echo "Completed: $(jq -r '(.completed_phases // []) | join(", ")' "$MEMORY_FILE")"
    echo "---"
    jq -r 'to_entries[] | select(.key != "completed_phases") | "  \(.key): \(if .value == null then "pending" elif (.value | type) == "object" then "filled" elif (.value | type) == "array" then "[\(.value | length) items]" elif (.value | type) == "string" then .value[:60] else (.value | tostring)[:60] end)"' "$MEMORY_FILE"
    ;;

  run-review)
    WORKSPACE=$(jq -r '.workspace // .project_path' "$STATE_FILE")
    PROMPT=$(fill_prompt "$PROMPTS_DIR/codex-review.md")
    OUTFILE=$(tmp_path "review" "md"); JSONL=$(tmp_path "review" "jsonl")
    log_entry "info" "agent.codex.start" '{"purpose":"plan-review"}'
    if ! (cd "$WORKSPACE" && codex exec --json -o "$OUTFILE" "$PROMPT" > "$JSONL" 2>&1); then
      log_entry "error" "agent.codex.failed" '{"error":"codex exec failed"}'; echo "ERROR: codex exec failed" >&2; exit 1
    fi
    RESULT=$("$0" extract-json "$SESSION_DIR" "$OUTFILE" "$SCHEMAS_DIR/review-output.json" 2>&1) || {
      log_entry "error" "agent.codex.parse_failed" "$(jq -cn --arg e "$RESULT" '{error:$e}')"; echo "ERROR: parse failed" >&2; exit 1
    }
    log_entry "info" "agent.codex.done" "$(jq -cn --arg v "$(echo "$RESULT" | jq -r '.verdict')" '{verdict:$v}')"
    echo "$RESULT"
    ;;

  run-implement)
    WORKSPACE=$(jq -r '.workspace // .project_path' "$STATE_FILE")
    PROMPT=$(fill_prompt "$PROMPTS_DIR/cursor-implement.md")
    OUTFILE=$(tmp_path "impl" "json")
    log_entry "info" "agent.cursor.start" '{"purpose":"implement"}'
    if ! agent -p "$PROMPT" --output-format json --trust --workspace "$WORKSPACE" --model composer-2-fast > "$OUTFILE" 2>&1; then
      log_entry "error" "agent.cursor.failed" '{"error":"agent exec failed"}'; echo "ERROR: agent exec failed" >&2; exit 1
    fi
    IS_ERROR=$(jq -r '.is_error // false' "$OUTFILE" 2>/dev/null || echo "true")
    if [[ "$IS_ERROR" == "true" ]]; then
      log_entry "error" "agent.cursor.error" '{"error":"agent reported error"}'; echo "ERROR: agent error" >&2; exit 1
    fi
    RESULT_TEXT=$(jq -r '.result // ""' "$OUTFILE" 2>/dev/null || cat "$OUTFILE")
    RESULT=$(echo "$RESULT_TEXT" | "$0" extract-json "$SESSION_DIR" "" "$SCHEMAS_DIR/implement-output.json" 2>&1) || {
      log_entry "error" "agent.cursor.parse_failed" "$(jq -cn --arg e "$RESULT" '{error:$e}')"; echo "ERROR: parse failed" >&2; exit 1
    }
    log_entry "info" "agent.cursor.done" "$(jq -cn --argjson f "$(echo "$RESULT" | jq '.changed_files')" '{changed_files:$f}')"
    echo "$RESULT"
    ;;

  run-parallel)
    shift 2
    if [[ $# -lt 2 || $(($# % 2)) -ne 0 ]]; then echo "ERROR: requires <label> <cmd> pairs" >&2; exit 1; fi
    PIDS=(); LABELS=(); OUTFILES=()
    while [[ $# -gt 0 ]]; do
      LABEL="$1"; PCMD="$2"; shift 2
      OUTFILE=$(tmp_path "parallel-${LABEL}" "out"); ERRFILE=$(tmp_path "parallel-${LABEL}" "err")
      LABELS+=("$LABEL"); OUTFILES+=("$OUTFILE")
      ( eval "$PCMD" > "$OUTFILE" 2> "$ERRFILE"; echo $? > "${OUTFILE}.exit" ) &
      PIDS+=($!)
    done
    log_entry "info" "parallel.start" "$(jq -cn --argjson c "${#LABELS[@]}" --arg l "${LABELS[*]}" '{count:$c,labels:$l}')"
    ALL_OK=true; for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    RESULTS='[]'
    for i in "${!LABELS[@]}"; do
      EXIT_CODE=$(cat "${OUTFILES[$i]}.exit" 2>/dev/null || echo "1")
      HAS_OUTPUT=$([[ -s "${OUTFILES[$i]}" ]] && echo "true" || echo "false")
      RESULTS=$(echo "$RESULTS" | jq --arg l "${LABELS[$i]}" --argjson e "$EXIT_CODE" --argjson o "$HAS_OUTPUT" --arg f "${OUTFILES[$i]}" '. + [{label:$l,exit_code:$e,has_output:$o,output_file:$f}]')
      if [[ "$EXIT_CODE" -ne 0 ]]; then ALL_OK=false; fi
    done
    log_entry "info" "parallel.done" "$RESULTS"; echo "$RESULTS" | jq -c '.[]'
    $ALL_OK || exit 1
    ;;

  extract-json)
    INPUT_FILE="${3:-}"; SCHEMA_FILE="${4:-}"
    if [[ -n "$INPUT_FILE" && -f "$INPUT_FILE" ]]; then RAW=$(cat "$INPUT_FILE"); else RAW=$(cat /dev/stdin); fi
    if result=$(try_parse_json "$RAW"); then validate_schema "$result" "$SCHEMA_FILE" && echo "$result" && exit 0; exit 1; fi
    FENCED=$(echo "$RAW" | command sed -n '/^```\(json\)\?$/,/^```$/{ /^```/d; p; }' | head -200)
    if [[ -n "$FENCED" ]]; then if result=$(try_parse_json "$FENCED"); then validate_schema "$result" "$SCHEMA_FILE" && echo "$result" && exit 0; exit 1; fi; fi
    BLOCK=$(echo "$RAW" | awk '/^\{/ || found { found=1; print } found && /^\}/ { exit }')
    if [[ -n "$BLOCK" ]]; then if result=$(try_parse_json "$BLOCK"); then validate_schema "$result" "$SCHEMA_FILE" && echo "$result" && exit 0; exit 1; fi; fi
    BUFFER=""
    while IFS= read -r line; do
      if [[ -z "$BUFFER" && "$line" == "{"* ]]; then BUFFER="$line"; elif [[ -n "$BUFFER" ]]; then BUFFER="$BUFFER
$line"; fi
      if [[ -n "$BUFFER" ]]; then if result=$(try_parse_json "$BUFFER"); then validate_schema "$result" "$SCHEMA_FILE" && echo "$result" && exit 0; exit 1; fi; fi
    done <<< "$RAW"
    echo "ERROR: no valid JSON object found" >&2; exit 1
    ;;

  log)
    if [[ ! -f "$LOG_FILE" ]]; then echo "No log file found."; exit 0; fi
    shift 2; parse_log_opts "$@"
    render_logs "$(jq -c '.' "$LOG_FILE")" "$FILTER" "$OFFSET" "$LIMIT" '[.ts, .severity, .event, .phase]'
    ;;

  logs)
    INPUT_DIR="$SESSION_DIR"
    if [[ "$INPUT_DIR" == "--global" ]]; then SEARCH_DIR="$STATE_ROOT"
    elif [[ -d "$INPUT_DIR" && -f "$INPUT_DIR/state.json" ]]; then SEARCH_DIR=$(dirname "$INPUT_DIR")
    elif [[ -d "$STATE_ROOT/$INPUT_DIR" ]]; then SEARCH_DIR="$STATE_ROOT/$INPUT_DIR"
    else SEARCH_DIR="$STATE_ROOT/-$(echo "$INPUT_DIR" | command sed 's|^/||; s|/|-|g')"; fi
    if [[ ! -d "$SEARCH_DIR" ]]; then echo "No sessions found." >&2; exit 1; fi
    shift 2; parse_log_opts "$@"
    MERGED=$(find "$SEARCH_DIR" -name "log.jsonl" -exec cat {} + 2>/dev/null | jq -c '.' 2>/dev/null | sort -t'"' -k4)
    if [[ -z "$MERGED" ]]; then echo "No logs found."; exit 0; fi
    render_logs "$MERGED" "$FILTER" "$OFFSET" "$LIMIT" '[.ts, .severity, .event, .session_id[:8], .phase]'
    ;;

  *) echo "ERROR: unknown command '$CMD'" >&2; echo "Commands: advance|jump|done|counter|clear-pending|check-agents|init-phases|derive-phase|status|run-review|run-implement|run-parallel|extract-json|log|logs" >&2; exit 1 ;;
esac
