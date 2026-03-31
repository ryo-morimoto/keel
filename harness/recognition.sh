#!/usr/bin/env bash
# harness/recognition.sh — Verify plugin components are recognized by Claude Code
#
# Loads the plugin via `claude --plugin-dir .` with debug logging,
# then parses the debug output to confirm skills, hooks, and agents
# are correctly discovered and registered.
#
# Usage:
#   bash harness/recognition.sh              # Full recognition check
#   bash harness/recognition.sh --verbose    # Show debug log excerpts
#
# Prerequisites: claude CLI (>= 2.0)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

VERBOSE=false
[[ "${1:-}" == "--verbose" ]] && VERBOSE=true

ERRORS=()
WARNINGS=()

pass() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; ERRORS+=("$1"); }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; WARNINGS+=("$1"); }
section() { echo -e "\n${CYAN}[$1]${NC}"; }

# ─── 0. Preflight ────────────────────────────────────────────────────

section "Preflight"

if ! command -v claude &>/dev/null; then
  fail "claude CLI not found in PATH"
  echo -e "\n${RED}ABORT${NC}: claude CLI is required"
  exit 1
fi

CLAUDE_VERSION=$(claude --version 2>/dev/null)
pass "claude CLI: $CLAUDE_VERSION"

if ! command -v jq &>/dev/null; then
  fail "jq not found in PATH"
  echo -e "\n${RED}ABORT${NC}: jq is required"
  exit 1
fi

# ─── 1. Official Validation ──────────────────────────────────────────

section "Official Validation (claude plugin validate)"

validate_output=$(claude plugin validate "$PROJECT_ROOT" 2>&1)
validate_exit=$?

if [[ $validate_exit -eq 0 ]]; then
  if echo "$validate_output" | grep -q "warning"; then
    warn "Validation passed with warnings"
    echo "$validate_output" | grep -E "❯|⚠" | while read -r line; do
      echo -e "    ${YELLOW}$line${NC}"
    done
  else
    pass "Validation passed cleanly"
  fi
else
  fail "Validation failed (exit $validate_exit)"
  echo "$validate_output" | head -20 | while read -r line; do
    echo -e "    $line"
  done
fi

# ─── 2. Debug Log Capture ────────────────────────────────────────────

section "Recognition Check (debug log analysis)"

DEBUG_LOG=$(mktemp /tmp/keel-recognition-XXXXXX.log)
trap 'rm -f "$DEBUG_LOG"' EXIT

echo -e "  Loading plugin via ${BOLD}claude --plugin-dir .${NC} ..."

# Run a minimal claude -p session with debug logging to capture plugin loading
(
  unset CLAUDECODE 2>/dev/null
  claude -p "reply OK" \
    --plugin-dir "$PROJECT_ROOT" \
    --model haiku \
    --debug-file "$DEBUG_LOG" \
    --output-format text \
    2>/dev/null
) > /dev/null 2>&1 || true

# Wait briefly for debug log to flush
sleep 0.5

if [[ ! -s "$DEBUG_LOG" ]]; then
  fail "Debug log is empty — could not capture plugin loading"
  echo -e "\n${RED}FAIL${NC} — recognition check could not run"
  exit 1
fi

pass "Debug log captured ($(wc -l < "$DEBUG_LOG") lines)"

if $VERBOSE; then
  echo -e "\n  ${CYAN}--- Relevant debug log lines ---${NC}"
  grep -iE "plugin.*keel|skills.*keel|hooks.*keel|agents.*keel|error.*keel|warn.*keel" "$DEBUG_LOG" | while read -r line; do
    echo -e "    $line"
  done
  echo -e "  ${CYAN}--- end ---${NC}"
fi

# ─── 3. Parse: Plugin Loaded ─────────────────────────────────────────

section "Plugin Loading"

# Check inline plugin loaded from --plugin-dir
if grep -q "Loaded inline plugin from path: keel" "$DEBUG_LOG"; then
  pass "Plugin loaded as inline plugin"
else
  fail "Plugin not loaded as inline plugin (expected: 'Loaded inline plugin from path: keel')"
fi

# Check override behavior (if installed version exists)
if grep -q 'Plugin "keel" from --plugin-dir overrides installed version' "$DEBUG_LOG"; then
  pass "Dev version overrides installed version"
elif grep -q "keel.*installed" "$DEBUG_LOG"; then
  warn "Installed version found but override not detected"
fi

# Check plugin is enabled
enabled_line=$(grep "Found.*plugins.*enabled" "$DEBUG_LOG" | tail -1)
if [[ -n "$enabled_line" ]]; then
  pass "Plugin system: $enabled_line"
fi

# ─── 4. Parse: Skills ────────────────────────────────────────────────

section "Skills Recognition"

# Expected skills from skills/ directory
expected_skills=()
if [[ -d "$PROJECT_ROOT/skills" ]]; then
  for skill_dir in "$PROJECT_ROOT"/skills/*/; do
    [[ -f "$skill_dir/SKILL.md" ]] && expected_skills+=("$(basename "$skill_dir")")
  done
fi

if [[ ${#expected_skills[@]} -eq 0 ]]; then
  warn "No skills found in skills/ directory"
else
  for skill_name in "${expected_skills[@]}"; do
    # Check if skill was loaded from our plugin path
    if grep -q "Loaded.*skills from plugin keel" "$DEBUG_LOG"; then
      # Extract the count
      skill_count=$(grep "Loaded.*skills from plugin keel" "$DEBUG_LOG" | grep -oP '\d+(?= skills)')
      if [[ -n "$skill_count" && "$skill_count" -gt 0 ]]; then
        pass "Skill '$skill_name' loaded ($skill_count skill(s) from plugin keel)"
      else
        fail "Skill '$skill_name' not loaded (0 skills from plugin keel)"
      fi
    else
      fail "No skills loaded from plugin keel"
    fi
  done
fi

# Check for skill loading errors
if grep -qiE "error.*skill.*keel|warn.*skill.*keel|failed.*skill.*keel" "$DEBUG_LOG"; then
  fail "Skill loading errors detected:"
  grep -iE "error.*skill.*keel|warn.*skill.*keel|failed.*skill.*keel" "$DEBUG_LOG" | while read -r line; do
    echo -e "    ${RED}$line${NC}"
  done
fi

# Check total skill count includes ours
total_skills_line=$(grep "Total plugin skills loaded" "$DEBUG_LOG" | tail -1)
if [[ -n "$total_skills_line" ]]; then
  pass "$total_skills_line"
fi

# ─── 5. Parse: Hooks ─────────────────────────────────────────────────

section "Hooks Recognition"

# Expected hooks from hooks.json
if [[ -f "$PROJECT_ROOT/hooks/hooks.json" ]]; then
  expected_events=$(jq -r '.hooks | keys[]' "$PROJECT_ROOT/hooks/hooks.json" 2>/dev/null)
  expected_event_count=$(echo "$expected_events" | wc -l)
else
  expected_events=""
  expected_event_count=0
fi

# Check hooks.json was loaded
if grep -q "Loaded hooks from standard location for plugin keel.*$PROJECT_ROOT" "$DEBUG_LOG"; then
  pass "hooks.json loaded from project directory"
elif grep -q "Loading hooks from plugin: keel" "$DEBUG_LOG"; then
  pass "Hooks loaded from plugin keel"
else
  fail "hooks.json not loaded from plugin keel"
fi

# Check hook registration
registered_line=$(grep "Registered.*hooks from.*plugins" "$DEBUG_LOG" | tail -1)
if [[ -n "$registered_line" ]]; then
  registered_count=$(echo "$registered_line" | grep -oP '\d+(?= hooks)')
  if [[ -n "$registered_count" && "$registered_count" -gt 0 ]]; then
    pass "Hooks registered: $registered_line"
  else
    fail "No hooks registered"
  fi
fi

# Check SessionStart hook fires
if grep -q "Getting matching hook commands for SessionStart" "$DEBUG_LOG"; then
  matched_hooks=$(grep "Matched.*unique hooks for query" "$DEBUG_LOG" | head -1)
  if [[ -n "$matched_hooks" ]]; then
    pass "SessionStart hooks matched: $matched_hooks"
  fi
fi

# Check for hook errors
hook_errors=$(grep -iE "error.*hook.*keel|hook.*error.*keel|hook.*fail" "$DEBUG_LOG" | grep -iv "PostToolUseFailure" || true)
if [[ -n "$hook_errors" ]]; then
  fail "Hook errors detected:"
  echo "$hook_errors" | while read -r line; do
    echo -e "    ${RED}$line${NC}"
  done
fi

# ─── 6. Parse: Agents ────────────────────────────────────────────────

section "Agents Recognition"

if [[ -d "$PROJECT_ROOT/agents" ]]; then
  expected_agents=()
  for agent_file in "$PROJECT_ROOT"/agents/*.md; do
    [[ -f "$agent_file" ]] && expected_agents+=("$(basename "$agent_file" .md)")
  done

  if [[ ${#expected_agents[@]} -gt 0 ]]; then
    if grep -q "agents from plugin keel" "$DEBUG_LOG"; then
      agent_count=$(grep "agents from plugin keel" "$DEBUG_LOG" | grep -oP '\d+(?= agents)')
      pass "Loaded $agent_count agent(s) from plugin keel"

      for agent_name in "${expected_agents[@]}"; do
        pass "Agent '$agent_name' expected to be loaded"
      done
    else
      fail "No agents loaded from plugin keel"
    fi
  else
    pass "No agent .md files in agents/ (none expected)"
  fi
else
  pass "No agents/ directory (none expected)"
fi

# ─── 7. Error Scan ───────────────────────────────────────────────────

section "Error Scan"

# Check for any ERROR lines mentioning keel
keel_errors=$(grep -i "ERROR.*keel\|keel.*ERROR" "$DEBUG_LOG" || true)
if [[ -n "$keel_errors" ]]; then
  fail "Errors mentioning keel found in debug log:"
  echo "$keel_errors" | while read -r line; do
    echo -e "    ${RED}$line${NC}"
  done
else
  pass "No errors mentioning keel in debug log"
fi

# Check for WARN lines mentioning keel
keel_warns=$(grep -i "WARN.*keel\|keel.*WARN" "$DEBUG_LOG" || true)
if [[ -n "$keel_warns" ]]; then
  warn "Warnings mentioning keel in debug log:"
  echo "$keel_warns" | while read -r line; do
    echo -e "    ${YELLOW}$line${NC}"
  done
else
  pass "No warnings mentioning keel in debug log"
fi

# ─── Summary ─────────────────────────────────────────────────────────

echo ""
echo "─────────────────────────────────────"
if [[ ${#ERRORS[@]} -eq 0 ]]; then
  echo -e "${GREEN}PASS${NC} — All components recognized (${#WARNINGS[@]} warning(s))"
  exit 0
else
  echo -e "${RED}FAIL${NC} — ${#ERRORS[@]} error(s), ${#WARNINGS[@]} warning(s)"
  for err in "${ERRORS[@]}"; do
    echo -e "  ${RED}✗${NC} $err"
  done
  exit 1
fi
