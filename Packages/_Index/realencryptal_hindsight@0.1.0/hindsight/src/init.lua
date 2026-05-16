--!strict

--> Hindsight — generalized hit detection + lag-compensated rollback for
--> Roblox gun systems. Public surface is intentionally minimal: one factory,
--> one method per concept on the returned World, plus type re-exports for
--> consumer-side annotations.

local Defaults = require(script.Defaults)
local Types = require(script.Types)
local World = require(script.World)

--[=[
	@class Hindsight

	The top-level module. Returned by `require(path.to.Hindsight)`.

	Hindsight exposes one factory ([`createWorld`](#createWorld)) plus a
	[`Defaults`](Defaults) table for introspection. Every other interaction —
	casting projectiles, capturing rollback poses, querying snapshots — goes
	through the [`World`](World) and [`Rollback`](Rollback) objects this factory
	builds.

	```lua
	local Hindsight = require(ReplicatedStorage.Hindsight)

	local world = Hindsight.createWorld({
	    actorContainer    = ServerScriptService,
	    definitionsModule = ReplicatedStorage.Shared.Definitions,
	})
	```
]=]

--[=[
	@prop Defaults Defaults
	@within Hindsight

	Built-in defaults used when the caller omits a config block on
	[`createWorld`](#createWorld). Useful for debug tooling that wants to
	introspect the values the world is actually running with, and as a base to
	clone-and-edit when you only want to override a few fields.
]=]

--[=[
	@type Extra { [string]: any }
	@within Hindsight

	An open table travelling with every projectile. Set on a per-cast basis via
	[`ProjectileModifier`](#ProjectileModifier).`extra`, surfaced on every
	callback's `ctx.extra`, and passed to the [`Filter`](#Filter).
]=]

--[=[
	@type Caster Player | Model
	@within Hindsight

	Whatever the game considers the shooter. Players for player weapons; Models
	for NPCs, turrets, or vehicles. The reference must resolve identically on
	every peer that runs a matching cast.
]=]

--[=[
	@type Filter (caster: Caster, victim: Player?, character: Model, extra: Extra) -> boolean
	@within Hindsight

	Optional per-character hit-skip predicate. Returns `true` to skip the
	candidate; `false`/`nil` to accept. Lives on a [`ProjectileDefinition`](#ProjectileDefinition)
	or is passed directly to [`Rollback:queryRay`](Rollback#queryRay).

	When used by the projectile simulator, runs inside the simulation actor in
	**parallel context** — read-only and thread-safe: no instance writes, no
	`Humanoid` state inspection beyond what's already captured.

	When used by a manual [`Rollback:queryRay`](Rollback#queryRay) call, runs on
	the main thread.
]=]

--[=[
	@interface Rig
	@within Hindsight
	.parts { string } -- Names of the BaseParts that form this rig's hitboxes, indexed in parallel with `sizes`.
	.sizes { Vector3 } -- Half-extents of each part's OBB, in stud-space. `sizes[i]` is paired with `parts[i]`.

	Hitbox layout for one rig kind. See [`Defaults.rigs`](Defaults#rigs) for the
	built-in R15 and R6 entries.
]=]

--[=[
	@interface RollbackConfig
	@within Hindsight
	.lifetime number -- Seconds of history retained. Older snapshots are dropped on `capture`.
	.voxelSize number -- Broadphase voxel cell size in studs.
	.gridCenter Vector3 -- World-space center of the voxel space.
	.gridSize Vector3 -- World-space size of the voxel space. Characters outside this AABB are not findable via `queryRay`.
	.hitboxSize Vector3 -- Half-extents used to fatten each character's footprint in the voxel grid.
	.rigs { [string]: Rig } -- Hitbox layouts, keyed by rig name (e.g. `"R15"`, `"R6"`).
]=]

--[=[
	@interface PenetrationConfig
	@within Hindsight
	.surfaceHardness { [Enum.Material]: number } -- Per-material hardness. Unlisted materials use `defaultHardness`.
	.defaultHardness number -- Fallback hardness for materials not in `surfaceHardness`.
	.ricochetHardness number -- Minimum hardness for a surface to be eligible to ricochet a projectile.
	.mediumGapThreshold number -- Gap size in studs below which adjacent parts are merged into one compound medium.
	.maxCompoundMediumParts number -- Upper bound on parts joined into one compound medium.
]=]

--[=[
	@interface WorldConfig
	@within Hindsight
	.actorContainer Instance -- Container into which the simulation Actors are parented.
	.definitionsModule ModuleScript -- ModuleScript returning `{ [string]: ProjectileDefinition }`.
	.visualsContainer Instance? -- Where bullet visuals get parented on the client. nil on the server.
	.excludeContainers { Instance }? -- Descendants are skipped as penetration continuation candidates (e.g. visuals folder, characters folder).
	.threads number? -- Number of simulation actors. Defaults to 16.
	.serverFrameRate number? -- Frame budget for the actor pool. Defaults to 1/60.
	.frameTimeBudget number? -- Fraction of `serverFrameRate` an actor will spend stepping projectiles per frame. Defaults to 0.5.
	.interpolation number? -- Client-side replication interpolation delay. Defaults to 0.048.
	.rollback RollbackConfig? -- Overrides [`Defaults.rollback`](Defaults#rollback).
	.penetration PenetrationConfig? -- Overrides [`Defaults.penetration`](Defaults#penetration).
	.defaultRaycastFilter RaycastParams? -- Fallback raycast filter used when a definition doesn't supply its own.

	The top-level configuration passed to [`createWorld`](#createWorld). Every
	wiring decision lives here — the library never looks anything up on its own.
]=]

--[=[
	@interface ImpactCtx
	@within Hindsight
	.type string -- Definition key the projectile was cast under.
	.caster Caster -- Whoever fired the projectile.
	.direction Vector3 -- Velocity at the moment of impact.
	.instance Instance -- The world part that was hit.
	.normal Vector3 -- Surface normal at the hit point.
	.position Vector3 -- World-space hit point.
	.material Enum.Material -- Surface material of the hit part.
	.extra Extra -- Per-cast extra table.

	Argument to a definition's `onImpact` callback. Fired on the main thread
	after `task.synchronize()`.
]=]

--[=[
	@interface IntersectionCtx
	@within Hindsight
	.type string -- Definition key the projectile was cast under.
	.caster Caster -- Whoever fired the projectile.
	.direction Vector3 -- Velocity at the moment of intersection.
	.part string -- Name of the character part that was hit (e.g. `"Head"`).
	.player Player? -- Player whose character was hit, if any.
	.character Model -- The hit character Model.
	.position Vector3 -- World-space intersection point.
	.extra Extra -- Per-cast extra table.

	Argument to a definition's `onIntersection` callback. Fired on the main
	thread after `task.synchronize()` — Humanoid state reads are safe here.
]=]

--[=[
	@interface DestroyedCtx
	@within Hindsight
	.type string -- Definition key the projectile was cast under.
	.caster Caster -- Whoever fired the projectile.
	.position Vector3 -- World-space position when destroyed.
	.extra Extra -- Per-cast extra table.

	Argument to a definition's `onDestroyed` callback. Fired when the projectile
	expires (lifetime, power exhausted, or destroyed by terrain).
]=]

--[=[
	@interface ProjectileDefinition
	@within Hindsight
	.velocity number -- Initial speed in studs/second.
	.gravity Vector3 -- World-space gravity vector applied every step.
	.lifetime number -- Seconds before the projectile self-destructs.
	.power number -- Penetration budget. Spent against material hardness when crossing surfaces.
	.angle number -- Maximum impact angle (degrees) that allows a ricochet. `360` always bounces; `0` never does.
	.loss number -- Speed lost per ricochet.
	.collaterals boolean? -- If true, continues through players instead of stopping on the first intersection.
	.raycastFilter RaycastParams? -- Optional `RaycastParams` overriding `World.defaultRaycastFilter`.
	.filter Filter? -- Per-character skip predicate. Parallel-safe.
	.onImpact ((ctx: ImpactCtx) -> ())? -- World-geometry hit callback.
	.onIntersection ((ctx: IntersectionCtx) -> ())? -- Captured-character intersection callback.
	.onDestroyed ((ctx: DestroyedCtx) -> ())? -- Expiration callback.

	A single ammo type. Lives in the [`WorldConfig.definitionsModule`](#WorldConfig).
	Modifier values override the numeric/data fields per cast; callbacks and
	`filter` are definition-only because functions cannot safely cross actor VM
	boundaries.
]=]

--[=[
	@interface ProjectileModifier
	@within Hindsight
	.velocity number?
	.gravity Vector3?
	.lifetime number?
	.power number?
	.angle number?
	.loss number?
	.collaterals boolean?
	.raycastFilter RaycastParams?
	.extra Extra?

	Per-cast overrides for numeric / data fields only. Functions (callbacks,
	`filter`) are not present — they live in the definitions module so each
	actor can `require` its own copy.
]=]

--[=[
	@interface CastOptions
	@within Hindsight
	.caster Caster -- Whoever fired the projectile.
	.type string -- Key in the definitions module (e.g. `"Bullet"`).
	.origin Vector3 -- World-space spawn point.
	.direction Vector3 -- Direction of travel. Normalized internally if not unit.
	.timestamp number -- Server time at which the projectile started. Used for rollback queries.
	.visual PVInstance? -- Optional visual template. Cloned into `World.visualsContainer` on the client.
	.modifier ProjectileModifier? -- Optional per-cast overrides.

	The single argument to [`World:cast`](World#cast).
]=]

--[=[
	@interface CharacterPose
	@within Hindsight
	.rig string -- Rig key (e.g. `"R15"`, `"R6"`) — must match one in [`RollbackConfig.rigs`](#RollbackConfig).
	.rootPosition Vector3 -- World-space position used to bucket the character into the voxel broadphase.
	.parts { CFrame } -- Per-part CFrames, indexed in parallel with the rig's `parts` list.
	.player Player? -- Owning player, if any. Surfaces on [`RollbackHit`](#RollbackHit).player and the [`Filter`](#Filter)'s `victim` argument.

	One character's frame data. The caller builds this every tick and pushes it
	via [`Rollback:capture`](Rollback#capture). Mismatched part counts are
	silently dropped at push time.
]=]

--[=[
	@type CharacterPoses { [Model]: CharacterPose }
	@within Hindsight

	The shape consumed by [`Rollback:capture`](Rollback#capture).
]=]

--[=[
	@interface RollbackHit
	@within Hindsight
	.player Player? -- Owning player of the character that was hit.
	.character Model -- The hit character Model.
	.part string -- Name of the part that was intersected (e.g. `"Head"`).
	.position Vector3 -- World-space hit point.
	.distance number -- Distance from the ray origin to the hit point.

	The shape returned by [`Rollback:queryRay`](Rollback#queryRay).
]=]

local Hindsight = {
	createWorld = World.new,
	Defaults = Defaults,
}

export type World = World.World
export type Caster = Types.Caster
export type Extra = Types.Extra
export type Filter = Types.Filter
export type Rig = Types.Rig
export type RollbackConfig = Types.RollbackConfig
export type PenetrationConfig = Types.PenetrationConfig
export type WorldConfig = Types.WorldConfig
export type ProjectileDefinition = Types.ProjectileDefinition
export type ProjectileModifier = Types.ProjectileModifier
export type CastOptions = Types.CastOptions
export type CharacterPose = Types.CharacterPose
export type CharacterPoses = Types.CharacterPoses
export type ImpactCtx = Types.ImpactCtx
export type IntersectionCtx = Types.IntersectionCtx
export type DestroyedCtx = Types.DestroyedCtx
export type Rollback = Types.Rollback
export type RollbackHit = Types.RollbackHit

return Hindsight
