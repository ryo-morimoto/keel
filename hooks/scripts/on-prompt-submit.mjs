#!/usr/bin/env node

/**
 * on-prompt-submit.mjs — UserPromptSubmit Hook
 *
 * WHY: Claude が state を直接触ると忘れて壊れる。hook が自動 inject する。
 * WHY PHASE_DATA_NEEDS: token compression — 各フェーズに必要なフィールドだけ inject。
 * WHY user_task from first prompt: SessionStart 時点ではタスク記述がない。
 * WHY pending_choice: 孤児セッション自動引き取りを防止。ユーザーに選択させる。
 */

import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { KEEL_SH, getProjectDir, findActiveSession, deriveCurrentPhase, readHookInput } from "./lib.mjs";

const PHASE_DATA_NEEDS = {
  clarify:           ["user_task"],
  investigate:       ["user_task", "resolved_requirements"],
  plan:              ["user_task", "investigation"],
  ur1:               ["plan"],
  review_codex:      ["user_task", "investigation", "plan"],
  plan_revise_loop:  ["plan", "review"],
  ur2:               ["plan", "review"],
  implement_cursor:  ["user_task", "plan"],
  implement_cc:      ["user_task", "plan"],
  verify:            ["implementation"],
  ur3:               ["implementation", "verification"],
};

function summarizeField(key, value) {
  if (value === null) return `  ${key}: pending`;
  if (Array.isArray(value)) return `  ${key}: [${value.length} items]`;
  if (typeof value === "object") {
    const keys = Object.keys(value);
    return keys.length === 0 ? `  ${key}: empty` : `  ${key}: filled (${keys.join(", ")})`;
  }
  const s = String(value);
  return `  ${key}: ${s.slice(0, 80)}${s.length > 80 ? "..." : ""}`;
}

function buildContext(session, { isNewOaSession = false, oaSessionId = null } = {}) {
  const { state, memory, dir, id } = session;
  const phase = deriveCurrentPhase(state.phase_list, memory);
  const completed = memory?.completed_phases || [];
  const total = state.phase_list.length;
  const workspace = state.workspace || state.project_path;
  const isWorktree = workspace !== state.project_path;

  const lines = [
    `⛵ KEEL SESSION: ${id}`,
    `OA: ${state.oa_type || "unknown"} (${state.oa_session_id?.slice(0, 8) || "?"})${isNewOaSession ? ` ⚠️ SESSION CHANGED (now: ${oaSessionId?.slice(0, 8)})` : ""}`,
    isWorktree ? `Workspace: ${workspace} (worktree)` : `Workspace: ${workspace}`,
  ];

  if (phase === "pending_classification") {
    lines.push(
      "Status: awaiting severity classification",
      "",
      "## First Action",
      "1. Classify severity via sub agent (haiku)",
      `2. Run: bash ${KEEL_SH} init-phases ${dir} <severity>`,
      "3. Begin executing the first phase",
    );
  } else {
    lines.push(
      `Severity: ${state.severity || "unclassified"} | Phase: ${phase} (${completed.length + 1}/${total})`,
      `Phases: ${state.phase_list.map(p => completed.includes(p) ? `~~${p}~~` : (p === phase ? `[${p}]` : p)).join(" → ")}`,
      `Counters: plan_revise=${state.counters.plan_revise} implement_retry=${state.counters.implement_retry}`,
    );
  }

  lines.push("", "## Memory");
  if (memory) {
    for (const [k, v] of Object.entries(memory)) {
      if (k === "completed_phases") continue;
      lines.push(summarizeField(k, v));
    }
  }

  lines.push("", "## Commands", `Dir: ${dir}`);
  lines.push(`  advance:     bash ${KEEL_SH} advance ${dir} '<json>'`);
  lines.push(`  jump:        bash ${KEEL_SH} jump ${dir} <phase> [resets...]`);
  lines.push(`  counter:     bash ${KEEL_SH} counter ${dir} <name>`);
  lines.push(`  init-phases: bash ${KEEL_SH} init-phases ${dir} <severity>`);
  lines.push(`  done:        bash ${KEEL_SH} done ${dir}`);

  lines.push("", "## Rules");
  lines.push("- DO NOT Read/Write state.json or memory.json directly — use commands above");
  lines.push("- Phase output JSON is merged into memory.json by `advance`");
  if (isWorktree) {
    lines.push(`- Worktree active. All operations must target: ${workspace}`);
    lines.push(`- codex: cd ${workspace} && codex exec ...`);
    lines.push(`- cursor: agent --workspace ${workspace} ...`);
  }

  if (isNewOaSession) {
    lines.push("", "## ⚠️ OA SESSION CHANGED");
    lines.push("Verify memory fields match actual work before proceeding.");
    lines.push(`Run \`keel.sh status ${dir}\` to inspect, or \`keel.sh jump\` to reset.`);
  }

  if (memory && phase !== "pending_classification" && phase !== "done") {
    const needed = PHASE_DATA_NEEDS[phase];
    if (needed?.length > 0) {
      lines.push("", "## Phase Data");
      for (const field of needed) {
        const value = memory[field];
        if (value != null) {
          lines.push(`${field}: ${typeof value === "string" ? value : JSON.stringify(value)}`);
        }
      }
    }
  }

  return lines.join("\n");
}

function main() {
  const input = readHookInput();
  if (!input) process.exit(0);

  const prompt = input.prompt || "";
  const oaSessionId = input.session_id || null;
  const projectDir = getProjectDir();

  const active = findActiveSession(projectDir, { includeMemory: true, oaSessionId });
  if (!active) process.exit(0);

  if (active.state.pending_choice) {
    const phase = deriveCurrentPhase(active.state.phase_list, active.memory);
    const completed = active.memory?.completed_phases || [];
    const task = active.memory?.user_task || "(no task)";

    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "UserPromptSubmit",
        additionalContext: [
          "⛵ KEEL: Active session found from previous OA session.",
          `Session: ${active.id}`,
          `Task: ${task}`,
          `Phase: ${phase} (${completed.length}/${active.state.phase_list.length} completed)`,
          "",
          "Ask the user: continue this session or start fresh?",
          `  Continue: bash ${KEEL_SH} clear-pending ${active.dir}`,
          `  New:      bash ${KEEL_SH} done ${active.dir}`,
        ].join("\n"),
      },
    }));
    process.exit(0);
  }

  if (active.memory && !active.memory.user_task && prompt.trim()) {
    active.memory.user_task = prompt.trim();
    writeFileSync(join(active.dir, "memory.json"), JSON.stringify(active.memory, null, 2));
  }

  const storedOaId = active.state.oa_session_id;
  const isNewOaSession = storedOaId && oaSessionId && storedOaId !== oaSessionId;

  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "UserPromptSubmit",
      additionalContext: buildContext(active, { isNewOaSession, oaSessionId }),
    },
  }));
  process.exit(0);
}

main();
