#!/usr/bin/env bash
# harness/run.sh — Main entry point for keel test harness
#
# Orchestrates: validate → unit-test → eval → summary
#
# Usage:
#   bash harness/run.sh              # validate + unit-test (fast, no LLM)
#   bash harness/run.sh validate     # Format validation only
#   bash harness/run.sh test         # Unit tests only
#   bash harness/run.sh eval         # LLM eval only (claude -p, haiku)
#   bash harness/run.sh all          # Everything including LLM eval
#   bash harness/run.sh --strict     # Reject Claude Code extension fields

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

MODE="${1:-default}"
EXTRA_ARGS="${@:2}"
STRICT_FLAG=""
[[ "$MODE" == "--strict" ]] && STRICT_FLAG="--strict" && MODE="default"

VALIDATE_OK=true
TEST_OK=true
EVAL_OK=true

run_validate() {
  echo -e "\n${BOLD}═══ Format Validation ═══${NC}"
  if bash "$SCRIPT_DIR/validate.sh" $STRICT_FLAG; then
    VALIDATE_OK=true
  else
    VALIDATE_OK=false
  fi
}

run_test() {
  echo -e "\n${BOLD}═══ Hook & Script Unit Tests ═══${NC}"
  if bash "$SCRIPT_DIR/unit-test.sh"; then
    TEST_OK=true
  else
    TEST_OK=false
  fi
}

run_eval() {
  echo -e "\n${BOLD}═══ LLM Behavior Eval (haiku) ═══${NC}"
  if bash "$SCRIPT_DIR/eval.sh" $EXTRA_ARGS; then
    EVAL_OK=true
  else
    EVAL_OK=false
  fi
}

case "$MODE" in
  validate) run_validate ;;
  test)     run_test ;;
  eval)     run_eval ;;
  default)  run_validate; run_test ;;
  all)      run_validate; run_test; run_eval ;;
  *)        echo "Usage: $0 [validate|test|eval|all|--strict]"; exit 1 ;;
esac

echo -e "\n${BOLD}═══ Summary ═══${NC}"
FAILED=false
$VALIDATE_OK || { echo -e "${RED}Format validation FAILED${NC}"; FAILED=true; }
$TEST_OK     || { echo -e "${RED}Unit tests FAILED${NC}"; FAILED=true; }
[[ "$MODE" == "eval" || "$MODE" == "all" ]] && ! $EVAL_OK && { echo -e "${RED}LLM eval FAILED${NC}"; FAILED=true; }

if ! $FAILED; then
  echo -e "${GREEN}ALL CHECKS PASSED${NC}"
  exit 0
else
  exit 1
fi
