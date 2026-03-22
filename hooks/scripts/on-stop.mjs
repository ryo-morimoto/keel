#!/usr/bin/env node

/**
 * on-stop.mjs — Stop Hook
 *
 * WHY block: フェーズ未完了で止まると中途半端な状態になる。
 * WHY allow ur*: ユーザー入力待ちフェーズではブロックしない。
 * WHY oaSessionId filter: 並列時に自分のセッションだけチェック。
 */

import { getProjectDir, findActiveSession, deriveCurrentPhase, readHookInput } from "./lib.mjs";

function main() {
  const input = readHookInput();
  const oaSessionId = input?.session_id || null;

  const active = findActiveSession(getProjectDir(), { includeMemory: true, oaSessionId });
  if (!active) process.exit(0);

  const phase = deriveCurrentPhase(active.state.phase_list, active.memory);
  if (phase === "done" || phase === "pending_classification" || phase.startsWith("ur")) {
    process.exit(0);
  }

  const completed = active.memory?.completed_phases || [];
  const remaining = active.state.phase_list.filter(p => !completed.includes(p));

  process.stdout.write(JSON.stringify({
    decision: "block",
    reason: [
      `Keel session ${active.id} has incomplete phases.`,
      `Current: ${phase} | Remaining: ${remaining.join(" → ")}`,
      `Severity: ${active.state.severity}`,
      "",
      "Continue executing the current phase. Use keel.sh commands from the session context.",
    ].join("\n"),
  }));
  process.exit(0);
}

main();
