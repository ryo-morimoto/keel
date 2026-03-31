---
name: keel
description: "Multi-agent orchestration: auto-classifies task severity, then runs a gated state machine through clarify → investigate → plan → review (Codex) → implement (Cursor Agent) → verify phases."
compatibility: "Designed for Claude Code, Codex, OpenCode, and Cursor. Currently implements Claude Code hooks; other agents planned."
user-invocable: true
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

Always-on orchestration. Sessions auto-created at SessionStart.
Phase derived from memory (`completed_phases`) — no manual index tracking.

## Arguments

Task: $ARGUMENTS

If a task is shown above, use it as `user_task` and immediately proceed to severity classification.
Do NOT ask the user to describe the task — it was already provided via the skill invocation.
If no task is shown (blank), wait for the first user prompt as usual.

## State Management

State is managed by hooks and `keel.sh`. **DO NOT Read or Write state.json / memory.json directly.**

- SessionStart hook creates/resumes sessions with `oa_session_id`
- UserPromptSubmit hook derives phase from memory and injects context
- Phase = first item in `phase_list` not in `completed_phases` (SSOT)
- Commands are injected each turn — use them as-is

### Commands

| Action | Command |
|--------|---------|
| Set severity + phases | `bash keel.sh init-phases <dir> <severity>` |
| Complete a phase | `bash keel.sh advance <dir> '<output-json>'` |
| Jump to a phase | `bash keel.sh jump <dir> <phase> [reset-fields...]` |
| Increment counter | `bash keel.sh counter <dir> <counter-name>` |
| Run codex review | `bash keel.sh run-review <dir>` |
| Run cursor implement | `bash keel.sh run-implement <dir>` |
| Run in parallel | `bash keel.sh run-parallel <dir> <label1> <cmd1> ...` |
| Mark session done | `bash keel.sh done <dir>` |

`advance` merges output JSON into memory, adds current phase to `completed_phases`, and validates gate.
`jump` removes target phase and all subsequent phases from `completed_phases`.
`run-review` reads memory, fills codex-review prompt template, runs codex, parses and returns JSON.
`run-implement` reads memory, fills cursor-implement prompt template, runs agent, parses and returns JSON.
All temp files use `/tmp/keel-{project}-{session_id_short}-{purpose}.{ext}` — parallel-safe.

## Flow

### 1. Task Capture → Severity Classification

If `$ARGUMENTS` was provided, use it as `user_task`. Otherwise, the first prompt becomes `user_task`.

Classify severity via **sub agent** (haiku):

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

Then run `keel.sh init-phases <dir> <severity>`.

### 2. Phase Execution

Execute the current phase (shown in injected context). Each phase section below specifies what to do and the advance command.

### clarify

Fill the 5-item checklist via user questions:
- 目的 / 解かないこと / 制約 / 最低限 / 検証基準

**Advance**: `keel.sh advance <dir> '{"resolved_requirements": {...}}'`

### investigate

Delegate to **sub agent** (Explore type).

**Advance**: `keel.sh advance <dir> '{"investigation": {"relevant_files":[...],"patterns":[...],"constraints":[...]}}'`

### plan

Generate plan with steps, verification_criteria, files_to_modify.

**Advance**: `keel.sh advance <dir> '{"plan": {"steps":[...],"verification_criteria":[...],"files_to_modify":[...]}}'`

### ur1 / ur2 / ur3

Present to user, ask approve/feedback. If approve: `keel.sh advance <dir> '{}'`. If feedback: fb_classify → jump.

### review_codex

```bash
REVIEW=$(bash keel.sh run-review <dir>)
```

`run-review` reads memory, fills the codex-review prompt template, runs codex, parses output. Returns JSON to stdout.

If it fails (exit 1): do the review yourself (Claude Code).

**Advance**: `keel.sh advance <dir> '{"review": '$REVIEW'}'`

If verdict is "revise": `keel.sh jump <dir> plan_revise_loop`

### plan_revise_loop

Revise plan from review issues. `keel.sh counter <dir> plan_revise` first. If >= 3, ask user.

**Advance**: `keel.sh advance <dir> '{"plan": {revised}}'` then `keel.sh jump <dir> review_codex review`

### implement_cursor

```bash
IMPL=$(bash keel.sh run-implement <dir>)
```

`run-implement` reads memory, fills the cursor-implement prompt template, runs cursor agent with `--output-format json --trust`, parses output. Returns JSON to stdout.

If it fails (exit 1): implement yourself (Claude Code).

**Advance**: `keel.sh advance <dir> '{"implementation": '$IMPL'}'`

### implement_cc

Implement directly as Claude Code.

**Advance**: `keel.sh advance <dir> '{"implementation": {"changed_files":[...],"summary":"..."}}'`

### verify

Run verification commands as defined in the project's AGENTS.md / CLAUDE.md. Use `run-parallel` when multiple checks apply.

If pass: advance. If fail: classify errors → jump back.

**Advance**: `keel.sh advance <dir> '{"verification": {"result":"pass|fail","errors":[...]}}'`

### fb_classify

Classify feedback → jump to appropriate phase.

### done

`keel.sh done <dir>`. Report summary.

## General Rules

- **NEVER** Read or Write state.json / memory.json directly
- Phase is derived from memory — if memory doesn't reflect work done, the phase resets correctly
- All external agent calls (Codex, Cursor) go through Bash tool
- All sub agent calls go through the Agent tool

## Parallel Sessions & Workspace

When multiple sessions run in parallel, the second session gets a git worktree to avoid file conflicts.
The workspace path is shown in the injected context. If a worktree is active:

- All file reads/writes must target the workspace path
- `codex exec`: run from the workspace (`cd <workspace> && codex exec ...`)
- `cursor agent`: use `--workspace <workspace>`
- `keel.sh done` automatically cleans up the worktree
