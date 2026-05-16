# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Lumen — a Roblox FPS project built on the **Cito** module-loader framework (`src/shared/Cito`). Code is Luau, synced into Roblox Studio via Rojo. Tooling is pinned via Aftman; Roblox dependencies via Wally.

## Common commands

```bash
aftman install                    # install rojo + wally at pinned versions
wally install                     # fetch Roblox deps into Packages/
rojo serve default.project.json   # live-sync to Roblox Studio (Rojo plugin)
rojo build default.project.json -o Lumen.rbxlx   # build a place file
```

There is no test runner, lint config, or CI in this repo — verify changes by syncing into Studio and running.

## Rojo layout (`default.project.json`)

| Filesystem path | Roblox location |
|---|---|
| `src/shared` | `ReplicatedStorage.Shared` |
| `Packages` (Wally output) | `ReplicatedStorage.Packages` |
| `src/server` | `ServerScriptService.Server` |
| `src/client` | `StarterPlayer.StarterPlayerScripts.Client` |

`src/client/init.client.luau` and `src/server/init.server.luau` are the entrypoints — both just hand off to Cito.

## Cito framework — how modules wire up

`src/client/init.client.luau` and `src/server/init.server.luau` both run:

```lua
Cito.new()
    :Discover({ReplicatedStorage.Shared, ReplicatedStorage.Packages, script})
    :LoadModules(script.Controllers)
    :Init()
```

What this means in practice:

- **`Discover` builds a flat name → ModuleScript map** via `Librarian` (`src/shared/Cito/Librarian.luau`). For `Packages`, only direct children are indexed. For everything else, ALL descendants are indexed by `.Name`. **Module names must be globally unique across the discovered tree** — duplicates are warned and the second one wins. Renaming a file is effectively renaming an import key.
- **`shared.Import("Name")` is the canonical way to grab any module** — including third-party Wally packages (`shared.Import("Trove")`, `shared.Import("Iris")`, etc.). Avoid `require(path)` for shared/library code; use it only for things outside the discovery tree (e.g. `LocalPlayer.PlayerScripts.PlayerModule`, or sibling files inside an ObjectProvider folder).
- **`LoadModules(Controllers)` requires every descendant `ModuleScript`** under `Controllers/`. Any module that ends up under a `Controllers/` folder will be auto-loaded and its `Init`/`Signals` invoked — this is sometimes undesirable for sub-files. To opt out: set `_Raw = true` on the returned table, or set the `IsServer` attribute on the ModuleScript to skip it on the wrong context.
- **Init order** = priority ascending (lower runs first), then dependency-resolved DFS. Default priority is `500`. Use `Constants.PRIORITY` (`FIRST=1, CORE=50, EARLY=150, NORMAL=500, INTERFACE=800, LATE=950, LAST=1000`) — don't hand-pick magic numbers when a band exists.
- **`Signals` is a magic table.** Cito auto-connects these names to engine signals, so don't connect them manually:
  - `Update` → `RenderStepped` on client, `Heartbeat` on server
  - `InputBegan`, `InputEnded` → `UserInputService` (client only)
  - `PlayerAdded`, `PlayerRemoving` → `Players`
  - `CharacterAdded`, `CharacterRemoving` → `LocalPlayer` (client only)
  Any other key under `Signals` is just a regular table entry — controllers sometimes invoke them manually (e.g. `Controller.Signals.CharacterAdded(LocalPlayer.Character)` to bootstrap on initial load, since the engine signal won't refire for the already-existing character).

## Other repo-specific conventions

- **`src/client/Controllers/ObjectProvider/`** holds OOP "objects" (ToolBase, Firearm, ToolManager, Cutscene). The `init.luau` controller runs at priority 50 and `require`s siblings directly via `script:FindFirstChild(Name)` — it deliberately loads them post-Init so they can use `shared.Import`. Add new objects by extending `Controller:Init()` in `ObjectProvider/init.luau`.
- **Server-only / client-only modules in shared paths**: set the `IsServer` attribute on the ModuleScript (true / false) — Cito's `LoadModules` will skip it on the wrong context.
- **`Event` library (`src/shared/Libraries/Event.luau`)** is a single shared `RemoteEvent` + `RemoteFunction` multiplexed by event name. Use `Event:Listen(name, cb)` / `Event:FireServer(name, ...)` / `Event:FireAllClients(name, ...)`. Don't create new `RemoteEvent` instances ad-hoc — route through this.
- **Wally `Packages/` is generated** — the `.lua` shim files (e.g. `Packages/Iris.lua`) are committed but `Packages/_Index/` contents are produced by `wally install`. Don't hand-edit shims.
- **`Constants` may load before `Librarian` is fully set up** — `Cito:Discover` has a fallback that synthesizes a minimal `Constants` table if the import fails. If you change the `Constants` module shape, keep `PRIORITY.NORMAL` and the `Debug` method present.

## Things easy to get wrong

- Calling `shared.Import("X")` at the top of a module file (outside `Init`) only works if `X` was discovered before this module was required. For anything not in `Packages/` or guaranteed-early, prefer importing inside `Init` (most controllers in this repo follow that pattern — see `MovementController.luau`, `CharacterController.luau`).
- Module file renames silently break `shared.Import("OldName")` calls — grep before renaming.
- Adding a file under `src/{client,server}/Controllers/` auto-runs it. If you want a helper that isn't a controller, put it under `src/shared/Libraries/` or `src/shared/Utilities/` and import it.
