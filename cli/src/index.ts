#!/usr/bin/env node
import { defineCommand, runMain } from "citty"
import install from "./commands/install"

const main = defineCommand({
  meta: {
    name: "keel-skill",
    version: "0.2.0",
    description: "Install keel agent skill for coding agents",
  },
  subCommands: {
    install: () => install,
  },
})

runMain(main)
