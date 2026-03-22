#!/usr/bin/env bash
# harness/validate.sh — Format validation for keel plugin
#
# Validates:
#   1. Agent Skills spec compliance (via skills-ref)
#   2. Claude Code extension fields (known-good list)
#   3. plugin.json structure
#   4. hooks.json structure
#   5. Directory layout
#
# Usage: bash harness/validate.sh [--strict]
#   --strict: Reject Claude Code extension fields (pure Agent Skills spec mode)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

STRICT=false
[[ "${1:-}" == "--strict" ]] && STRICT=true

ERRORS=()
WARNINGS=()

pass() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; ERRORS+=("$1"); }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; WARNINGS+=("$1"); }
section() { echo -e "\n${CYAN}[$1]${NC}"; }

# ─── 1. Directory Structure ───────────────────────────────────────────

section "Directory Structure"

[[ -d "$PROJECT_ROOT/.claude-plugin" ]] && pass ".claude-plugin/ exists" || fail ".claude-plugin/ missing"
[[ -f "$PROJECT_ROOT/.claude-plugin/plugin.json" ]] && pass "plugin.json exists" || fail "plugin.json missing"
[[ -d "$PROJECT_ROOT/skills" ]] && pass "skills/ exists" || fail "skills/ missing"
[[ -d "$PROJECT_ROOT/hooks" ]] && pass "hooks/ exists" || fail "hooks/ missing"
[[ -f "$PROJECT_ROOT/hooks/hooks.json" ]] && pass "hooks/hooks.json exists" || fail "hooks/hooks.json missing"

# Check each skill has SKILL.md in a subdirectory
if [[ -d "$PROJECT_ROOT/skills" ]]; then
  for skill_dir in "$PROJECT_ROOT"/skills/*/; do
    skill_name="$(basename "$skill_dir")"
    if [[ -f "$skill_dir/SKILL.md" ]]; then
      pass "skills/$skill_name/SKILL.md exists"
    else
      fail "skills/$skill_name/SKILL.md missing"
    fi
  done
fi

# Check hook scripts referenced in hooks.json exist
if [[ -f "$PROJECT_ROOT/hooks/hooks.json" ]]; then
  # Extract script paths from hooks.json (commands referencing CLAUDE_PLUGIN_ROOT)
  scripts=$(jq -r '.. | .command? // empty' "$PROJECT_ROOT/hooks/hooks.json" \
    | sed 's|.*\${CLAUDE_PLUGIN_ROOT}/||' | sed 's/"//g')
  while IFS= read -r script_path; do
    [[ -z "$script_path" ]] && continue
    if [[ -f "$PROJECT_ROOT/$script_path" ]]; then
      pass "Hook script: $script_path"
    else
      fail "Hook script missing: $script_path"
    fi
  done <<< "$scripts"
fi

# ─── 2. Agent Skills Spec (skills-ref) ───────────────────────────────

section "Agent Skills Spec (skills-ref)"

# Claude Code extension fields — valid in Claude Code but not in Agent Skills spec
CLAUDE_CODE_EXTENSIONS=(
  "user-invocable"
  "disable-model-invocation"
  "argument-hint"
  "model"
  "effort"
  "context"
  "agent"
  "hooks"
)

for skill_dir in "$PROJECT_ROOT"/skills/*/; do
  skill_name="$(basename "$skill_dir")"

  if $STRICT; then
    # Pure Agent Skills spec mode — no extensions allowed
    output=$(uvx --from "git+https://github.com/agentskills/agentskills#subdirectory=skills-ref" \
      skills-ref validate "$skill_dir" 2>&1) && pass "skills/$skill_name: spec-compliant" || fail "skills/$skill_name: $output"
  else
    # Allow Claude Code extensions — strip them before validating
    skill_md="$skill_dir/SKILL.md"
    if [[ ! -f "$skill_md" ]]; then
      fail "skills/$skill_name: SKILL.md not found"
      continue
    fi

    # Create temp copy with extension fields removed
    tmp_dir=$(mktemp -d)
    tmp_skill="$tmp_dir/$skill_name"
    mkdir -p "$tmp_skill"
    cp "$skill_md" "$tmp_skill/SKILL.md"

    found_extensions=()
    for ext in "${CLAUDE_CODE_EXTENSIONS[@]}"; do
      if grep -qE "^${ext}:" "$tmp_skill/SKILL.md"; then
        found_extensions+=("$ext")
        # Remove the extension field line from frontmatter
        sed -i "/^${ext}:/d" "$tmp_skill/SKILL.md"
      fi
    done

    output=$(uvx --from "git+https://github.com/agentskills/agentskills#subdirectory=skills-ref" \
      skills-ref validate "$tmp_skill" 2>&1) && pass "skills/$skill_name: spec-compliant (core fields)" || fail "skills/$skill_name: $output"

    for ext in "${found_extensions[@]}"; do
      warn "skills/$skill_name: Claude Code extension field '${ext}' (not in Agent Skills spec)"
    done

    rm -rf "$tmp_dir"
  fi
done

# ─── 3. plugin.json Validation ───────────────────────────────────────

section "plugin.json"

if [[ -f "$PROJECT_ROOT/.claude-plugin/plugin.json" ]]; then
  # Valid JSON check
  if jq empty "$PROJECT_ROOT/.claude-plugin/plugin.json" 2>/dev/null; then
    pass "Valid JSON"
  else
    fail "Invalid JSON"
  fi

  # Required fields
  name=$(jq -r '.name // empty' "$PROJECT_ROOT/.claude-plugin/plugin.json")
  [[ -n "$name" ]] && pass "name: $name" || fail "Missing required field: name"

  # Recommended fields
  version=$(jq -r '.version // empty' "$PROJECT_ROOT/.claude-plugin/plugin.json")
  [[ -n "$version" ]] && pass "version: $version" || warn "Missing recommended field: version"

  description=$(jq -r '.description // empty' "$PROJECT_ROOT/.claude-plugin/plugin.json")
  [[ -n "$description" ]] && pass "description present" || warn "Missing recommended field: description"

  # Path references check
  skills_path=$(jq -r '.skills // empty' "$PROJECT_ROOT/.claude-plugin/plugin.json")
  if [[ -n "$skills_path" ]]; then
    resolved="${PROJECT_ROOT}/${skills_path#./}"
    [[ -d "$resolved" ]] && pass "skills path resolves: $skills_path" || fail "skills path not found: $skills_path → $resolved"
  else
    warn "No explicit 'skills' path in plugin.json (relying on convention)"
  fi

  hooks_path=$(jq -r '.hooks // empty' "$PROJECT_ROOT/.claude-plugin/plugin.json")
  if [[ -n "$hooks_path" ]]; then
    resolved="${PROJECT_ROOT}/${hooks_path#./}"
    [[ -f "$resolved" ]] && pass "hooks path resolves: $hooks_path" || fail "hooks path not found: $hooks_path → $resolved"
  else
    warn "No explicit 'hooks' path in plugin.json (relying on convention)"
  fi
fi

# ─── 4. hooks.json Validation ────────────────────────────────────────

section "hooks.json"

VALID_EVENTS=(
  "SessionStart" "SessionEnd"
  "UserPromptSubmit"
  "PreToolUse" "PostToolUse" "PostToolUseFailure"
  "PermissionRequest"
  "Stop"
  "SubagentStart" "SubagentStop"
  "ConfigChange"
  "PreCompact" "PostCompact"
)

if [[ -f "$PROJECT_ROOT/hooks/hooks.json" ]]; then
  if jq empty "$PROJECT_ROOT/hooks/hooks.json" 2>/dev/null; then
    pass "Valid JSON"
  else
    fail "Invalid JSON"
  fi

  # Check top-level structure
  has_hooks_key=$(jq 'has("hooks")' "$PROJECT_ROOT/hooks/hooks.json")
  [[ "$has_hooks_key" == "true" ]] && pass "Top-level 'hooks' key present" || fail "Missing top-level 'hooks' key"

  # Validate event names
  events=$(jq -r '.hooks | keys[]' "$PROJECT_ROOT/hooks/hooks.json" 2>/dev/null)
  while IFS= read -r event; do
    [[ -z "$event" ]] && continue
    found=false
    for valid in "${VALID_EVENTS[@]}"; do
      [[ "$event" == "$valid" ]] && found=true && break
    done
    $found && pass "Event: $event" || fail "Unknown event name: $event (case-sensitive)"
  done <<< "$events"

  # Validate hook entries have required fields
  jq -r '.hooks | to_entries[] | .key as $event | .value[] | .hooks[]? | "\($event)|\(.type // "MISSING")"' \
    "$PROJECT_ROOT/hooks/hooks.json" 2>/dev/null | while IFS='|' read -r event hook_type; do
    if [[ "$hook_type" == "MISSING" ]]; then
      fail "$event: hook missing 'type' field"
    elif [[ "$hook_type" =~ ^(command|http|prompt|agent)$ ]]; then
      pass "$event: type=$hook_type"
    else
      fail "$event: invalid hook type '$hook_type' (expected: command|http|prompt|agent)"
    fi
  done
fi

# ─── Summary ─────────────────────────────────────────────────────────

echo ""
echo "─────────────────────────────────────"
if [[ ${#ERRORS[@]} -eq 0 ]]; then
  echo -e "${GREEN}PASS${NC} — ${#WARNINGS[@]} warning(s)"
  exit 0
else
  echo -e "${RED}FAIL${NC} — ${#ERRORS[@]} error(s), ${#WARNINGS[@]} warning(s)"
  exit 1
fi
