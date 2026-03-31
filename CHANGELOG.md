# Changelog

## [0.5.0](https://github.com/ryo-morimoto/keel/compare/keel-v0.4.2...keel-v0.5.0) (2026-03-31)


### Features

* accept task as skill argument via $ARGUMENTS ([2c6d844](https://github.com/ryo-morimoto/keel/commit/2c6d844a838a8c7346f841395252bd9a4e422bba))


### Bug Fixes

* remove hooks wrapper object for correct auto-discovery format ([054b064](https://github.com/ryo-morimoto/keel/commit/054b064db08f048ff17185b9cbef34ffd4049663))

## [0.4.2](https://github.com/ryo-morimoto/keel/compare/keel-v0.4.1...keel-v0.4.2) (2026-03-31)


### Bug Fixes

* make keel skill user-invocable ([4cc68b6](https://github.com/ryo-morimoto/keel/commit/4cc68b619bd4c08c5cb46a0e5bf17cba500f1f5c))

## [0.4.1](https://github.com/ryo-morimoto/keel/compare/keel-v0.4.0...keel-v0.4.1) (2026-03-31)


### Bug Fixes

* remove explicit hooks field to avoid duplicate load ([53d1f3e](https://github.com/ryo-morimoto/keel/commit/53d1f3eed46f65739dbd54a6c58c3218fc601708))

## [0.4.0](https://github.com/ryo-morimoto/keel/compare/keel-v0.3.1...keel-v0.4.0) (2026-03-31)


### Features

* add XDG-based phase actions for local code review workflows ([3f03675](https://github.com/ryo-morimoto/keel/commit/3f03675c5750ad48b0bce896ba72727575a1eb46))


### Bug Fixes

* move state file protection from PostToolUse to PreToolUse ([01e9ac0](https://github.com/ryo-morimoto/keel/commit/01e9ac08b6c38bb1fbc0f07d6b26db9d7ec94a92))
* UserPromptSubmit hook not firing due to empty matcher ([d6a6320](https://github.com/ryo-morimoto/keel/commit/d6a6320ba347a812293453007314865ddc3603ea))

## [0.3.1](https://github.com/ryo-morimoto/keel/compare/keel-v0.3.0...keel-v0.3.1) (2026-03-22)


### Bug Fixes

* **cli:** read version from package.json instead of hardcoding ([156c7a4](https://github.com/ryo-morimoto/keel/commit/156c7a4d5d375cfabd6051eac1f69a27d390301f))

## [0.3.0](https://github.com/ryo-morimoto/keel/compare/keel-v0.2.0...keel-v0.3.0) (2026-03-22)


### Features

* add marketplace.json and improve plugin bootstrapping ([8991fec](https://github.com/ryo-morimoto/keel/commit/8991fec5e43220c8527ba0683dc820c04fcab887))
* add npx CLI installer for non-Claude Code agents ([59cb59b](https://github.com/ryo-morimoto/keel/commit/59cb59bc2e41a85c2bb22e9d4355f17b9cf1bbaa))
* initial release of keel — adaptive multi-agent orchestration ([df5648d](https://github.com/ryo-morimoto/keel/commit/df5648d99c1956bb6dabe6ceb153778bf4f2c554))


### Bug Fixes

* **ci:** correct release-please-action SHA pin ([ec1cc15](https://github.com/ryo-morimoto/keel/commit/ec1cc152a4f43ee1d0b86fc95c64540c5ee718b0))
* SKILL.md spec compliance and plugin.json paths ([4bbe694](https://github.com/ryo-morimoto/keel/commit/4bbe6949d7862357c203b273ab4de4e28efc7e64))
