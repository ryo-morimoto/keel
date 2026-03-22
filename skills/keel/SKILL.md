---
name: keel
description: "Multi-agent orchestration: auto-classifies task severity, then runs a gated state machine through clarify → investigate → plan → review (Codex) → implement (Cursor Agent) → verify phases. Use this skill for ANY development task — it determines the right workflow automatically."
compatibility: "Designed for Claude Code, Codex, OpenCode, and Cursor. Currently implements Claude Code hooks; other agents planned."
---

# Keel — Adaptive Multi-Agent Orchestration

<!--
WHY always-on:
  ドッグフーディング優先。全セッションで keel が動作する。
  SessionStart で自動初期化、最初の prompt が user_task になる。
  Agent Skills spec 準拠のため user-invocable は使わず、hooks で always-on を実現。

WHY this architecture:
  - Claude が state を直接触ると忘れて壊れる → hook + keel.sh が管理
  - Claude がコマンドを自然言語から組み立てると間違える → run-review/run-implement が自動構築
  - current_phase_index は rewind で乖離する → completed_phases (SSOT) から導出
  - 並列セッションでファイル競合 → git-wt で worktree 自動作成
  - 全て「Claude にやらせない、システムがやる」方針。Claude は判断と実行に専念。

WHY severity classification:
  全タスクを同じフローで処理すると重い。typo 修正に codex review は不要。
  severity でフェーズリストを動的に決定し、最小フローを適用。
-->

You are an orchestrator. Every development task goes through keel. Do NOT work on the task directly — follow the keel flow below.

## Bootstrap — Your First Action

When you receive a task, check if hooks already injected a keel session context (look for `⛵ KEEL SESSION` in your context). If yes, skip to **Phase Execution** below.

If no session context is present, bootstrap manually. Run this as a **single Bash command**:

```bash
KEEL_SH="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts/keel.sh}"; if [ -z "$KEEL_SH" ] || [ ! -f "$KEEL_SH" ]; then for d in "$(pwd)" "$HOME/.claude/plugins/keel" "$HOME/.claude/plugins"/*/; do [ -f "$d/scripts/keel.sh" ] && KEEL_SH="$d/scripts/keel.sh" && break; done; fi; if [ -z "$KEEL_SH" ] || [ ! -f "$KEEL_SH" ]; then for d in "$HOME/.claude/plugins/cache"/*/*; do [ -f "$d/scripts/keel.sh" ] && KEEL_SH="$d/scripts/keel.sh" && break; done; fi; STATE_ROOT="${CLAUDE_PLUGIN_DATA:+$CLAUDE_PLUGIN_DATA/sessions}"; STATE_ROOT="${STATE_ROOT:-$HOME/.local/state/keel}"; PROJECT_KEY=$(echo "$PWD" | sed 's|^/||;s|/|-|g'); SESSION_DIR=$(ls -td "$STATE_ROOT/-$PROJECT_KEY"/*/ 2>/dev/null | head -1 | sed 's|/$||'); if [ -z "$SESSION_DIR" ]; then SESSION_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen); SESSION_DIR="$STATE_ROOT/-$PROJECT_KEY/$SESSION_ID"; mkdir -p "$SESSION_DIR"; printf '{"session_id":"%s","oa_session_id":null,"oa_type":"claude-code","project_path":"%s","workspace":"%s","phase_list":[],"severity":null,"status":"running","counters":{"plan_revise":0,"implement_retry":0}}' "$SESSION_ID" "$PWD" "$PWD" > "$SESSION_DIR/state.json"; printf '{"user_task":null,"severity":null,"completed_phases":[],"resolved_requirements":null,"investigation":null,"plan":null,"review":null,"implementation":null,"verification":null}' > "$SESSION_DIR/memory.json"; fi; echo "KEEL_SH=$KEEL_SH"; echo "SESSION_DIR=$SESSION_DIR"; [ -n "$KEEL_SH" ] && bash "$KEEL_SH" status "$SESSION_DIR" || echo "keel.sh not found — use manual flow"
```

Save the output values `KEEL_SH` and `SESSION_DIR` — you need them for all subsequent commands.

If `keel.sh not found` is shown, you are in an environment without the keel plugin installed. Still follow the severity classification and phase flow below, but skip keel.sh commands and manage state manually.

After bootstrap, proceed with **Severity Classification** (if phase is `pending_classification`) or the current phase shown in status.

## Severity Classification

The user's prompt is the `user_task`. Classify severity via **sub agent** (haiku):

> Classify this development task as one of: trivial, small, medium, large.
>
> Criteria:
> - trivial: 1 file, obvious change, no design decisions
> - small: 2-3 files, clear pattern, no design decisions
> - medium: 4+ files, design decisions needed
> - large: unknown scope, design decisions required
>
> Respond with ONLY one word.
>
> Task: {user_task}

Then set the user_task in memory and init phases:

```bash
# Set user_task (only if not already set)
jq --arg t "<user_task>" '.user_task = $t' "$SESSION_DIR/memory.json" > "$SESSION_DIR/memory.json.tmp" && mv "$SESSION_DIR/memory.json.tmp" "$SESSION_DIR/memory.json"
# Init phases
bash "$KEEL_SH" init-phases "$SESSION_DIR" <severity>
```

Then immediately begin the first phase.

## State Management

State is managed by `keel.sh`. **DO NOT Read or Write state.json / memory.json directly** (except for the bootstrap above).

- Phase = first item in `phase_list` not in `completed_phases` (SSOT)
- Use `keel.sh status <dir>` to check current state

### Commands

| Action | Command |
|--------|---------|
| Check status | `bash $KEEL_SH status $SESSION_DIR` |
| Set severity + phases | `bash $KEEL_SH init-phases $SESSION_DIR <severity>` |
| Complete a phase | `bash $KEEL_SH advance $SESSION_DIR '<output-json>'` |
| Jump to a phase | `bash $KEEL_SH jump $SESSION_DIR <phase> [reset-fields...]` |
| Increment counter | `bash $KEEL_SH counter $SESSION_DIR <counter-name>` |
| Run codex review | `bash $KEEL_SH run-review $SESSION_DIR` |
| Run cursor implement | `bash $KEEL_SH run-implement $SESSION_DIR` |
| Mark session done | `bash $KEEL_SH done $SESSION_DIR` |

`advance` merges output JSON into memory, adds current phase to `completed_phases`, and validates gate.
`jump` removes target phase and all subsequent phases from `completed_phases`.
All temp files use `/tmp/keel-{project}-{session_id_short}-{purpose}.{ext}` — parallel-safe.

## Phase Execution

Execute the current phase. Each phase section below specifies what to do and the advance command.

### clarify

Fill the 5-item checklist via user questions:
- 目的 / 解かないこと / 制約 / 最低限 / 検証基準

**Advance**: `bash $KEEL_SH advance $SESSION_DIR '{"resolved_requirements": {...}}'`

### investigate

Delegate to **sub agent** (Explore type).

**Advance**: `bash $KEEL_SH advance $SESSION_DIR '{"investigation": {"relevant_files":[...],"patterns":[...],"constraints":[...]}}'`

### plan

Generate plan with steps, verification_criteria, files_to_modify.

**Advance**: `bash $KEEL_SH advance $SESSION_DIR '{"plan": {"steps":[...],"verification_criteria":[...],"files_to_modify":[...]}}'`

### ur1 / ur2 / ur3

Present to user, ask approve/feedback. If approve: advance with `'{}'`. If feedback: fb_classify → jump.

### review_codex

```bash
REVIEW=$(bash $KEEL_SH run-review $SESSION_DIR)
```

If it fails (exit 1): do the review yourself.

**Advance**: `bash $KEEL_SH advance $SESSION_DIR '{"review": '$REVIEW'}'`

If verdict is "revise": `bash $KEEL_SH jump $SESSION_DIR plan_revise_loop`

### plan_revise_loop

Revise plan from review issues. `bash $KEEL_SH counter $SESSION_DIR plan_revise` first. If >= 3, ask user.

**Advance**: `bash $KEEL_SH advance $SESSION_DIR '{"plan": {revised}}'` then `bash $KEEL_SH jump $SESSION_DIR review_codex review`

### implement_cursor

```bash
IMPL=$(bash $KEEL_SH run-implement $SESSION_DIR)
```

If it fails (exit 1): implement yourself.

**Advance**: `bash $KEEL_SH advance $SESSION_DIR '{"implementation": '$IMPL'}'`

### implement_cc

Implement directly.

**Advance**: `bash $KEEL_SH advance $SESSION_DIR '{"implementation": {"changed_files":[...],"summary":"..."}}'`

### verify

Run verification commands as defined in the project's AGENTS.md / CLAUDE.md. If pass: advance. If fail: classify errors → jump back.

**Advance**: `bash $KEEL_SH advance $SESSION_DIR '{"verification": {"result":"pass|fail","errors":[...]}}'`

### done

`bash $KEEL_SH done $SESSION_DIR`. Report summary.

## Rules

- **NEVER** Read or Write state.json / memory.json directly (bootstrap is the only exception)
- Phase is derived from memory — if memory doesn't reflect work done, the phase resets correctly
- All external agent calls (Codex, Cursor) go through Bash tool
- All sub agent calls go through the Agent tool
- **Do NOT skip phases** — follow the phase list in order
- **Do NOT work on the task before classifying severity** — classification first, always

## Parallel Sessions & Workspace

When multiple sessions run in parallel, the second session gets a git worktree to avoid file conflicts.
The workspace path is shown in status output. If a worktree is active:

- All file reads/writes must target the workspace path
- `codex exec`: run from the workspace (`cd <workspace> && codex exec ...`)
- `cursor agent`: use `--workspace <workspace>`
- `keel.sh done` automatically cleans up the worktree
