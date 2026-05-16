# Hindsight

[![Docs](https://github.com/realencryptal/hindsight/actions/workflows/docs.yml/badge.svg)](https://github.com/realencryptal/hindsight/actions/workflows/docs.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Wally](https://img.shields.io/badge/wally-realencryptal%2Fhindsight-orange)](https://wally.run/package/realencryptal/hindsight)

A generalized hit-detection and lag-compensated rollback library for Roblox gun systems.

**Docs:** https://realencryptal.github.io/Hindsight/

Hindsight provides two primitives:

1. **Projectile simulation** — a server-authoritative, parallelized projectile engine with penetration, ricochet, and snapshot-based hit detection. Same shape as a casting library, but every wiring decision (actors, containers, projectile definitions, rig hitboxes) is supplied by the caller through code.
2. **Standalone rollback** — the snapshot system is exposed on its own. Query a ray, retrieve a character's interpolated pose, or build hit-scan / melee / ability checks on top of it without touching the projectile path.


## Install

```toml
# wally.toml
[dependencies]
Hindsight = "realencryptal/hindsight@^0.1"
```

## Quick reference

```lua
local Hindsight = require(ReplicatedStorage.Hindsight)

local world = Hindsight.createWorld({
    actorContainer    = ServerScriptService,
    visualsContainer  = workspace.Bullets, -- optional
    definitionsModule = ReplicatedStorage.Shared.Definitions,
    threads           = 16,
    rollback          = { ... },
    penetration       = { ... },
})

world.rollback:autoCapturePlayers()

world:cast({
    caster    = player,
    type      = "Bullet",
    origin    = origin,
    direction = direction,
    timestamp = workspace:GetServerTimeNow(),
})

-- Standalone rollback query (server-only):
local hit = world.rollback:queryRay(timestamp, origin, direction, 500)
```

## Documentation

- [Getting started](https://realencryptal.github.io/Hindsight/docs/getting-started) — end-to-end setup in under five minutes
- [Concepts](https://realencryptal.github.io/Hindsight/docs/concepts) — how the snapshot model, actor pool, and definitions fit together
- [Wiring server and client](https://realencryptal.github.io/Hindsight/docs/wiring) — what your scripts need to do
- [Defining projectiles](https://realencryptal.github.io/Hindsight/docs/defining-projectiles) — the definitions module
- [Standalone rollback](https://realencryptal.github.io/Hindsight/docs/rollback) — using snapshots without projectiles
- [Configuration reference](https://realencryptal.github.io/Hindsight/docs/configuration) — every `WorldConfig` knob
- [API reference](https://realencryptal.github.io/Hindsight/api/Hindsight) — generated from source

A complete working server + client lives in [`example/`](example).

## License

[MIT](LICENSE)
