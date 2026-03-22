#!/usr/bin/env node
import { defineCommand, runMain } from "citty"
import { readFileSync } from "fs"
import { fileURLToPath } from "url"
import { dirname, join } from "path"
import install from "./commands/install"

const __dirname = dirname(fileURLToPath(import.meta.url))
const pkg = JSON.parse(readFileSync(join(__dirname, "..", "package.json"), "utf-8"))

const main = defineCommand({
  meta: {
    name: "keel-skill",
    version: pkg.version,
    description: pkg.description,
  },
  subCommands: {
    install: () => install,
  },
})

runMain(main)
