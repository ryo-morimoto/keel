import { readFileSync, existsSync, readdirSync, statSync, cpSync, mkdirSync, writeFileSync } from "fs"
import path from "path"
import yaml from "js-yaml"
import type { Target, TargetScope } from "./targets"

export type SkillProperties = {
  name: string
  description: string
  metadata?: Record<string, string>
  [key: string]: unknown
}

export type ParsedSkill = {
  name: string
  properties: SkillProperties
  frontmatterRaw: string
  body: string
  sourceDir: string
}

/**
 * Parse SKILL.md frontmatter and body.
 */
export function parseSkillMd(skillMdPath: string): ParsedSkill {
  const content = readFileSync(skillMdPath, "utf-8")
  const parts = content.split("---")
  if (parts.length < 3) {
    throw new Error(`Invalid SKILL.md: missing frontmatter delimiters in ${skillMdPath}`)
  }

  const frontmatterRaw = parts[1]
  const body = parts.slice(2).join("---").trimStart()
  const properties = yaml.load(frontmatterRaw) as SkillProperties

  if (!properties.name || !properties.description) {
    throw new Error(`SKILL.md missing required fields (name, description) in ${skillMdPath}`)
  }

  return {
    name: properties.name,
    properties,
    frontmatterRaw,
    body,
    sourceDir: path.dirname(skillMdPath),
  }
}

/**
 * Discover all skills in the plugin's skills/ directory.
 */
export function discoverSkills(pluginRoot: string): ParsedSkill[] {
  const skillsDir = path.join(pluginRoot, "skills")
  if (!existsSync(skillsDir)) return []

  const skills: ParsedSkill[] = []
  for (const entry of readdirSync(skillsDir)) {
    const skillMd = path.join(skillsDir, entry, "SKILL.md")
    if (existsSync(skillMd)) {
      skills.push(parseSkillMd(skillMd))
    }
  }
  return skills
}

/**
 * Expand metadata fields for a target and generate the output SKILL.md.
 */
export function expandSkillForTarget(skill: ParsedSkill, target: Target): string {
  const metadata = skill.properties.metadata ?? {}
  const expanded = target.expandFields(metadata)

  // Build new frontmatter: original properties + expanded fields (minus metadata keys for this target)
  const newProps = { ...skill.properties }

  // Add expanded fields at top level
  for (const [key, value] of Object.entries(expanded)) {
    newProps[key] = value
  }

  const frontmatter = yaml.dump(newProps, {
    lineWidth: -1, // no line wrapping
    quotingType: '"',
    forceQuotes: false,
  }).trimEnd()

  return `---\n${frontmatter}\n---\n\n${skill.body}`
}

/**
 * Install a skill to the target's skills directory.
 * Copies the entire skill directory and rewrites SKILL.md with expanded fields.
 */
export function installSkill(
  skill: ParsedSkill,
  target: Target,
  scope: TargetScope,
  home: string,
  cwd: string,
): string {
  const skillsDir = target.skillsDir(scope, home, cwd)
  const destDir = path.join(skillsDir, skill.name)

  // Copy entire skill directory
  mkdirSync(destDir, { recursive: true })
  cpSync(skill.sourceDir, destDir, { recursive: true })

  // Overwrite SKILL.md with expanded version
  const expandedContent = expandSkillForTarget(skill, target)
  writeFileSync(path.join(destDir, "SKILL.md"), expandedContent)

  return destDir
}
