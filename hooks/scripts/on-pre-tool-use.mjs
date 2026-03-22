#!/usr/bin/env node

/**
 * on-pre-tool-use.mjs — PreToolUse Hook
 *
 * Blocks direct Read/Write/Edit of state.json and memory.json.
 * These files must be accessed through keel.sh commands to ensure
 * gate validation and logging are not bypassed.
 *
 * Exit code 2 = block the tool call.
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

  // Exit code 2 blocks the tool call
  process.stderr.write(
    `BLOCKED: Direct ${toolName} to ${basename} is not allowed. Use keel.sh commands instead.`
  );
  process.exit(2);
}

main();
