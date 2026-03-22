#!/usr/bin/env node

/**
 * on-session-start.mjs — SessionStart Hook
 *
 * WHY SessionStart (not UserPromptSubmit):
 *   セッション初期化を prompt inject と分離するため。
 *   oa_session_id の取得と resume/new 判定をここで行う。
 *
 * WHY parallel session → worktree:
 *   2つの OA セッションが同じ CWD で動くとファイル競合する。
 *   2番目以降に git worktree を割り当てて物理的に分離。
 *   worktree 管理は git-wt に委譲。--hook true で wt.hook を上書き。
 *
 * WHY pending_choice:
 *   unowned session がある場合、自動引き取りではなくユーザーに選択させる。
 */

import { writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { execSync } from "node:child_process";
import { CWD, getProjectDir, findActiveSession, findUnownedSession, readHookInput } from "./lib.mjs";

function createWorktree(sessionId) {
  const branch = `keel/${sessionId.slice(0, 8)}`;
  try {
    const output = execSync(`git wt ${branch} --nocd --hook true`, {
      cwd: CWD,
      encoding: "utf-8",
    }).trim();
    return output || null;
  } catch {
    return null;
  }
}

function createSession(projectDir, oaSessionId, { needsWorktree = false } = {}) {
  const sessionId = randomUUID();
  const sessionDir = join(projectDir, sessionId);
  mkdirSync(sessionDir, { recursive: true });

  let workspace = CWD;
  if (needsWorktree) {
    const wt = createWorktree(sessionId);
    if (wt) workspace = wt;
  }

  const state = {
    session_id: sessionId,
    oa_session_id: oaSessionId,
    oa_type: "claude-code",
    project_path: CWD,
    workspace,
    phase_list: [],
    severity: null,
    status: "running",
    counters: { plan_revise: 0, implement_retry: 0 },
  };

  const memory = {
    user_task: null,
    severity: null,
    completed_phases: [],
    resolved_requirements: null,
    investigation: null,
    plan: null,
    review: null,
    implementation: null,
    verification: null,
  };

  writeFileSync(join(sessionDir, "state.json"), JSON.stringify(state, null, 2));
  writeFileSync(join(sessionDir, "memory.json"), JSON.stringify(memory, null, 2));
  return { dir: sessionDir, state, memory, id: sessionId };
}

function main() {
  const input = readHookInput();
  if (!input) process.exit(0);

  const oaSessionId = input.session_id || null;
  const source = input.source || "new";
  const projectDir = getProjectDir();

  const owned = findActiveSession(projectDir, { oaSessionId });
  const unowned = findUnownedSession(projectDir);
  const anyOtherActive = findActiveSession(projectDir);

  if (source === "resume") {
    if (owned) {
      owned.state.oa_session_id = oaSessionId;
      writeFileSync(join(owned.dir, "state.json"), JSON.stringify(owned.state, null, 2));
    } else if (unowned) {
      unowned.state.oa_session_id = oaSessionId;
      writeFileSync(join(unowned.dir, "state.json"), JSON.stringify(unowned.state, null, 2));
    } else {
      mkdirSync(projectDir, { recursive: true });
      createSession(projectDir, oaSessionId, { needsWorktree: !!anyOtherActive });
    }
  } else {
    if (owned) {
      // noop
    } else if (unowned) {
      unowned.state.oa_session_id = oaSessionId;
      unowned.state.pending_choice = true;
      writeFileSync(join(unowned.dir, "state.json"), JSON.stringify(unowned.state, null, 2));
    } else {
      mkdirSync(projectDir, { recursive: true });
      createSession(projectDir, oaSessionId, { needsWorktree: !!anyOtherActive });
    }
  }

  process.exit(0);
}

main();
