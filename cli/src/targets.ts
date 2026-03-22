import os from "os"
import path from "path"
import { existsSync } from "fs"

export type TargetScope = "user" | "project"

export type Target = {
  name: string
  prefix: string
  detectPaths: (home: string, cwd: string) => string[]
  skillsDir: (scope: TargetScope, home: string, cwd: string) => string
  /** Fields that need to be promoted from metadata to frontmatter top-level */
  expandFields: (metadata: Record<string, string>) => Record<string, unknown>
}

export const targets: Record<string, Target> = {
  cc: {
    name: "Claude Code",
    prefix: "cc",
    detectPaths: (home) => [
      path.join(home, ".claude"),
    ],
    skillsDir: (scope, home, cwd) =>
      scope === "user"
        ? path.join(home, ".claude", "skills")
        : path.join(cwd, ".claude", "skills"),
    expandFields: (metadata) => {
      const fields: Record<string, unknown> = {}
      for (const [key, value] of Object.entries(metadata)) {
        if (!key.startsWith("cc:")) continue
        const field = key.slice(3) // remove "cc:"
        // Convert "true"/"false" strings to booleans
        if (value === "true") fields[field] = true
        else if (value === "false") fields[field] = false
        else fields[field] = value
      }
      return fields
    },
  },

  codex: {
    name: "Codex",
    prefix: "codex",
    detectPaths: (home) => [
      path.join(home, ".codex"),
    ],
    skillsDir: (scope, home, cwd) =>
      scope === "user"
        ? path.join(home, ".codex", "skills")
        : path.join(cwd, ".codex", "skills"),
    expandFields: (metadata) => {
      const fields: Record<string, unknown> = {}
      for (const [key, value] of Object.entries(metadata)) {
        if (!key.startsWith("codex:")) continue
        const field = key.slice(6)
        if (value === "true") fields[field] = true
        else if (value === "false") fields[field] = false
        else fields[field] = value
      }
      return fields
    },
  },

  opencode: {
    name: "OpenCode",
    prefix: "opencode",
    detectPaths: (home) => [
      path.join(home, ".config", "opencode"),
    ],
    skillsDir: (scope, home, cwd) =>
      scope === "user"
        ? path.join(home, ".config", "opencode", "skills")
        : path.join(cwd, ".opencode", "skills"),
    expandFields: (metadata) => {
      const fields: Record<string, unknown> = {}
      for (const [key, value] of Object.entries(metadata)) {
        if (!key.startsWith("opencode:")) continue
        const field = key.slice(9)
        if (value === "true") fields[field] = true
        else if (value === "false") fields[field] = false
        else fields[field] = value
      }
      return fields
    },
  },
}

export type DetectedTool = {
  name: string
  displayName: string
  detected: boolean
  reason: string
}

export async function detectInstalledTools(
  home: string = os.homedir(),
  cwd: string = process.cwd(),
): Promise<DetectedTool[]> {
  const results: DetectedTool[] = []
  for (const [key, target] of Object.entries(targets)) {
    let detected = false
    let reason = "not found"
    for (const p of target.detectPaths(home, cwd)) {
      if (existsSync(p)) {
        detected = true
        reason = `found ${p}`
        break
      }
    }
    results.push({ name: key, displayName: target.name, detected, reason })
  }
  return results
}
