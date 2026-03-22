# keel

Adaptive multi-agent orchestration for coding agents. Routes tasks to the right agents based on severity.

## Install

```bash
claude plugin install github:ryo-morimoto/keel
```

## What it does

Keel automatically classifies your task's severity and runs the minimum necessary workflow:

| Severity | Flow |
|----------|------|
| trivial | implement → verify |
| small | investigate → implement → verify → review |
| medium | investigate → plan → codex review → implement → verify → review |
| large | clarify → investigate → plan → user review → codex review → implement → verify → review |

Agents are selected based on availability:
- **Codex** for plan review (`codex login status`)
- **Cursor Agent** for implementation (`agent status`)
- Falls back to Claude Code if either is unavailable

## How it works

- **SessionStart hook** creates a session automatically
- **UserPromptSubmit hook** injects current phase and context every turn
- **keel.sh** manages state transitions with gate validation
- **Memory is the single source of truth** — phase derived from `completed_phases`, resilient to rewind/interruption
- **Parallel sessions** get isolated git worktrees via `git-wt`

## Architecture

```
hooks/          → detect, inject, guard (Node.js)
scripts/        → execute, transition, run agents (Bash)
skills/         → phase execution instructions (Markdown)
references/     → prompt templates + output schemas
```

State lives in `$CLAUDE_PLUGIN_DATA/sessions/` (or `~/.local/state/keel/`).

## Requirements

- Claude Code
- `jq`
- Optional: `codex` (OpenAI), `agent` (Cursor), `git-wt`

## License

MIT
