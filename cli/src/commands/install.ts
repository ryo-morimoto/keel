import { defineCommand } from "citty"
import os from "os"
import path from "path"
import { detectInstalledTools, targets } from "../targets"
import { discoverSkills, installSkill } from "../skill-parser"
import type { TargetScope } from "../targets"

export default defineCommand({
  meta: {
    name: "install",
    description: "Install keel skill for a coding agent",
  },
  args: {
    to: {
      type: "string",
      description: "Target agent: cc | codex | opencode | all (default: auto-detect)",
    },
    scope: {
      type: "string",
      default: "user",
      description: "Installation scope: user | project",
    },
    source: {
      type: "string",
      alias: "s",
      description: "Plugin source path (default: resolve from GitHub)",
    },
  },
  async run({ args }) {
    const scope = (args.scope === "project" ? "project" : "user") as TargetScope
    const home = os.homedir()
    const cwd = process.cwd()

    // Resolve plugin source
    const pluginRoot = args.source
      ? path.resolve(String(args.source))
      : await resolvePluginSource()

    // Discover skills
    const skills = discoverSkills(pluginRoot)
    if (skills.length === 0) {
      console.error("No skills found in", pluginRoot)
      process.exit(1)
    }
    console.log(`Found ${skills.length} skill(s): ${skills.map(s => s.name).join(", ")}`)

    // Resolve target(s)
    const targetName = args.to ? String(args.to) : undefined
    const targetNames = await resolveTargets(targetName, home, cwd)

    if (targetNames.length === 0) {
      console.error("No coding agents detected. Install at least one agent first.")
      process.exit(1)
    }

    // Install skills to each target
    for (const name of targetNames) {
      const target = targets[name]
      if (!target) {
        console.warn(`Unknown target: ${name}, skipping`)
        continue
      }

      console.log(`\nInstalling for ${target.name} (scope: ${scope})`)
      for (const skill of skills) {
        const destDir = installSkill(skill, target, scope, home, cwd)
        console.log(`  ✓ ${skill.name} → ${destDir}`)
      }
    }

    console.log("\nDone.")
  },
})

async function resolveTargets(
  targetName: string | undefined,
  home: string,
  cwd: string,
): Promise<string[]> {
  if (targetName === "all") {
    const detected = await detectInstalledTools(home, cwd)
    const active = detected.filter(t => t.detected)
    console.log(`Detected ${active.length} agent(s):`)
    for (const tool of detected) {
      console.log(`  ${tool.detected ? "✓" : "✗"} ${tool.displayName} — ${tool.reason}`)
    }
    return active.map(t => t.name)
  }

  if (targetName) {
    if (!targets[targetName]) {
      console.error(`Unknown target: ${targetName}. Available: ${Object.keys(targets).join(", ")}`)
      process.exit(1)
    }
    return [targetName]
  }

  // Auto-detect: pick first detected agent
  const detected = await detectInstalledTools(home, cwd)
  const active = detected.filter(t => t.detected)

  if (active.length === 0) return []

  if (active.length === 1) {
    console.log(`Auto-detected: ${active[0].displayName}`)
    return [active[0].name]
  }

  // Multiple agents detected — install to all
  console.log(`Detected ${active.length} agent(s):`)
  for (const tool of active) {
    console.log(`  ✓ ${tool.displayName} — ${tool.reason}`)
  }
  return active.map(t => t.name)
}

async function resolvePluginSource(): Promise<string> {
  // Check if running from within the keel repo
  const scriptDir = new URL(".", import.meta.url).pathname
  const repoRoot = path.resolve(scriptDir, "..", "..")

  const { existsSync } = await import("fs")
  if (existsSync(path.join(repoRoot, "skills", "keel", "SKILL.md"))) {
    // Running from the repo — use parent directory (plugin root)
    const pluginRoot = path.resolve(scriptDir, "..", "..", "..")
    if (existsSync(path.join(pluginRoot, ".claude-plugin", "plugin.json"))) {
      return pluginRoot
    }
  }

  // Fallback: clone from GitHub
  const { mkdtempSync } = await import("fs")
  const { execSync } = await import("child_process")
  const tmpDir = mkdtempSync(path.join(os.tmpdir(), "keel-install-"))
  console.log("Fetching keel from GitHub...")
  execSync("git clone --depth 1 https://github.com/ryo-morimoto/keel " + tmpDir, {
    stdio: "pipe",
  })
  return tmpDir
}
