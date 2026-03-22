#!/usr/bin/env node

/**
 * on-post-tool-use.mjs — PostToolUse Hook
 *
 * WHY block direct access:
 *   state.json/memory.json への直接 Read/Write は gate 検証をバイパスし、
 *   completed_phases の更新が漏れ、ログも残らない。
 *   keel.sh 経由を強制することで全状態変更が gate + log を通る。
 */

import { STATE_ROOT, readHookInput } from "./lib.mjs";

function main() {
  const input = readHookInput();
  if (!input) process.exit(0);

  const toolName = input.tool_name || "";
  if (!["Read", "Write", "Edit"].includes(toolName)) process.exit(0);

  const filePath = input.tool_input?.file_path || "";
  if (!filePath.includes(STATE_ROOT)) process.exit(0);

  const basename = filePath.split("/").pop();
  if (basename !== "state.json" && basename !== "memory.json") process.exit(0);

  process.stdout.write(JSON.stringify({
    decision: "block",
    reason: `BLOCKED: Direct ${toolName} to ${basename} is not allowed. Use keel.sh commands from the injected session context.`,
  }));
  process.exit(0);
}

main();
