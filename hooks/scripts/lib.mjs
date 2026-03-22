/**
 * lib.mjs — Shared utilities for keel hooks.
 *
 * WHY this exists:
 *   4 hook が同じロジック（パス正規化、セッション検索、phase 導出）を持っていた。
 *   重複を排除し、並列セッション対応のロジックを一箇所で管理するために分離。
 *
 * WHY deriveCurrentPhase is here (not in keel.sh):
 *   hook は Node.js、keel.sh は Bash。両方で phase 導出が必要。
 *   SSOT は memory.completed_phases — current_phase_index は廃止済み。
 *
 * WHY oaSessionId filter in findActiveSession:
 *   複数 CC セッションが並列で動く場合、各 CC は自分の oa_session_id に
 *   紐づくセッションだけを操作する必要がある。
 */

import { readFileSync, existsSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

export const HOME = process.env.HOME;
export const CWD = process.env.CWD || process.cwd();

// WHY: CLAUDE_PLUGIN_ROOT は plugin install 時に自動設定される。
// fallback は dirname ベースで standalone 実行にも対応。
const __dirname = dirname(fileURLToPath(import.meta.url));
export const PLUGIN_ROOT = process.env.CLAUDE_PLUGIN_ROOT || join(__dirname, "../..");

export const KEEL_SH = join(PLUGIN_ROOT, "scripts", "keel.sh");

// WHY: CLAUDE_PLUGIN_DATA は plugin 用の永続データディレクトリ。
// plugin 外で使う場合は ~/.local/state/keel/ にフォールバック。
export const STATE_ROOT = process.env.CLAUDE_PLUGIN_DATA
  ? join(process.env.CLAUDE_PLUGIN_DATA, "sessions")
  : join(HOME, ".local", "state", "keel");

export function normalizeProjectPath(cwd) {
  return "-" + cwd.replace(/^\//, "").replace(/\//g, "-");
}

export function getProjectDir() {
  return join(STATE_ROOT, normalizeProjectPath(CWD));
}

/**
 * Memory の completed_phases から現在フェーズを導出。
 *
 * WHY not index-based:
 *   current_phase_index は rewind/中断で memory と乖離する。
 *   completed_phases は gate 通過済みフェーズのみ記録 → memory が SSOT。
 */
export function deriveCurrentPhase(phaseList, memory) {
  if (!phaseList || phaseList.length === 0) return "pending_classification";
  const completed = memory?.completed_phases || [];
  for (const phase of phaseList) {
    if (!completed.includes(phase)) return phase;
  }
  return "done";
}

/**
 * WHY oaSessionId filter is optional:
 *   SessionStart では「他 OA がセッションを持っているか」を知るために
 *   フィルタなしで呼ぶ必要がある（worktree 要否判定）。
 */
export function findActiveSession(projectDir, { includeMemory = false, oaSessionId = null } = {}) {
  if (!existsSync(projectDir)) return null;

  for (const entry of readdirSync(projectDir)) {
    const stateFile = join(projectDir, entry, "state.json");
    if (!existsSync(stateFile)) continue;
    try {
      const state = JSON.parse(readFileSync(stateFile, "utf-8"));
      if (state.status === "done") continue;
      if (oaSessionId && state.oa_session_id && state.oa_session_id !== oaSessionId) continue;

      const result = { dir: join(projectDir, entry), state, id: entry };
      if (includeMemory) {
        const memoryFile = join(projectDir, entry, "memory.json");
        result.memory = existsSync(memoryFile)
          ? JSON.parse(readFileSync(memoryFile, "utf-8"))
          : null;
      }
      return result;
    } catch {}
  }
  return null;
}

/**
 * oa_session_id が null のセッションを検索。
 * SessionStart で孤児セッションを検出 → 新しい OA セッションに引き取らせるため。
 */
export function findUnownedSession(projectDir, opts = {}) {
  if (!existsSync(projectDir)) return null;

  for (const entry of readdirSync(projectDir)) {
    const stateFile = join(projectDir, entry, "state.json");
    if (!existsSync(stateFile)) continue;
    try {
      const state = JSON.parse(readFileSync(stateFile, "utf-8"));
      if (state.status === "done") continue;
      if (state.oa_session_id) continue;

      const result = { dir: join(projectDir, entry), state, id: entry };
      if (opts.includeMemory) {
        const memoryFile = join(projectDir, entry, "memory.json");
        result.memory = existsSync(memoryFile)
          ? JSON.parse(readFileSync(memoryFile, "utf-8"))
          : null;
      }
      return result;
    } catch {}
  }
  return null;
}

export function readHookInput() {
  try {
    return JSON.parse(readFileSync("/dev/stdin", "utf-8"));
  } catch {
    return null;
  }
}
