--!strict

--> Single source of truth for every Hindsight type a consumer interacts with.
--> All other modules consume these via `local Types = require(script.Parent.Types)`;
--> the top-level `init.lua` re-exports them so users reach them through `Hindsight.X`.

local Types = {}

export type Extra = { [string]: any }

--> A caster is whatever the game considers the shooter. Players for player
--> weapons, Models for NPCs / turrets / vehicles. The reference must resolve
--> identically on every peer that runs a matching cast.
export type Caster = Player | Model

--> Optional per-character hit-skip predicate. Runs inside the simulation actor
--> in parallel context, so it must be read-only and thread-safe (no instance
--> writes, no Humanoid state inspection beyond what's already captured). Return
--> `true` to skip the hit. Must live in a definition (modifiers cannot carry
--> functions across actor VMs).
export type Filter = (caster: Caster, victim: Player?, character: Model, extra: Extra) -> boolean

--> Hitbox layout for one rig kind. `parts` and `sizes` are indexed in parallel;
--> `sizes[i]` is the half-extent of the OBB used to ray-test `parts[i]`.
export type Rig = {
	parts: { string },
	sizes: { Vector3 },
}

export type RollbackConfig = {
	lifetime: number,
	voxelSize: number,
	gridCenter: Vector3,
	gridSize: Vector3,
	hitboxSize: Vector3,
	rigs: { [string]: Rig },
}

export type PenetrationConfig = {
	surfaceHardness: { [Enum.Material]: number },
	defaultHardness: number,
	ricochetHardness: number,
	mediumGapThreshold: number,
	maxCompoundMediumParts: number,
}

--> Top-level configuration passed to `Hindsight.createWorld`. Every wiring
--> decision lives here — the library never looks anything up on its own.
--> `excludeContainers` is consulted by the penetration overlap probe (Pass 2),
--> which can't use OverlapParams in parallel context; descendants of these
--> instances are skipped as continuation candidates. Typical contents: the
--> visuals container and the user's characters container.
export type WorldConfig = {
	actorContainer: Instance,
	definitionsModule: ModuleScript,
	visualsContainer: Instance?,
	excludeContainers: { Instance }?,
	threads: number?,
	serverFrameRate: number?,
	frameTimeBudget: number?,
	interpolation: number?,
	rollback: RollbackConfig?,
	penetration: PenetrationConfig?,
	defaultRaycastFilter: RaycastParams?,
}

export type ImpactCtx = {
	type: string,
	caster: Caster,
	direction: Vector3,
	instance: Instance,
	normal: Vector3,
	position: Vector3,
	material: Enum.Material,
	extra: Extra,
}

export type IntersectionCtx = {
	type: string,
	caster: Caster,
	direction: Vector3,
	part: string,
	player: Player?,
	character: Model,
	position: Vector3,
	extra: Extra,
}

export type DestroyedCtx = {
	type: string,
	caster: Caster,
	position: Vector3,
	extra: Extra,
}

--> A single ammo type. Modifier values override the numeric/data fields per
--> cast; callbacks and `filter` are definition-only because functions cannot
--> safely cross actor VM boundaries. `range` is consulted only by the hitscan
--> path; `velocity` / `gravity` / `lifetime` are consulted only by the
--> projectile path.
export type ProjectileDefinition = {
	velocity: number,
	gravity: Vector3,
	lifetime: number,
	power: number,
	angle: number,
	loss: number,
	range: number?,
	collaterals: boolean?,
	raycastFilter: RaycastParams?,
	filter: Filter?,
	onImpact: ((ctx: ImpactCtx) -> ())?,
	onIntersection: ((ctx: IntersectionCtx) -> ())?,
	onDestroyed: ((ctx: DestroyedCtx) -> ())?,
}

--> Per-cast overrides for numeric / data fields only. Functions (callbacks,
--> filter) are not present — they live in the definitions module so each actor
--> can require its own copy.
export type ProjectileModifier = {
	velocity: number?,
	gravity: Vector3?,
	lifetime: number?,
	power: number?,
	angle: number?,
	loss: number?,
	range: number?,
	collaterals: boolean?,
	raycastFilter: RaycastParams?,
	extra: Extra?,
}

export type CastOptions = {
	caster: Caster,
	type: string,
	origin: Vector3,
	direction: Vector3,
	timestamp: number,
	visual: PVInstance?,
	modifier: ProjectileModifier?,
}

--> One character's frame data. The caller builds this every tick and pushes
--> it via `world.rollback:capture(time, poses)`. The library never iterates
--> the workspace to find characters.
export type CharacterPose = {
	rig: string,
	rootPosition: Vector3,
	parts: { CFrame },
	player: Player?,
}

export type CharacterPoses = { [Model]: CharacterPose }

export type RollbackHit = {
	player: Player?,
	character: Model,
	part: string,
	position: Vector3,
	distance: number,
}

--> Rollback exposes both halves of the snapshot system: the writer (`capture`)
--> and the readers (`queryRay`, `characterPoseAt`). When held by a World, the
--> writer fans out to every simulation actor; the reader queries the main-
--> thread store.
--> Auto-capture helpers (`autoCapture*`) are server-only opt-ins. Each
--> registers a "source" of characters with the proxy. The proxy runs a single
--> `PostSimulation` hook that walks every registered source, builds one merged
--> CharacterPoses table, and pushes it. Mixing helpers is safe — all sources
--> contribute to the same snapshot per tick. Each call returns its own
--> disconnect.
export type Rollback = {
	capture: (self: Rollback, time: number, poses: CharacterPoses) -> (),
	queryRay: (
		self: Rollback,
		time: number,
		origin: Vector3,
		direction: Vector3,
		length: number,
		filter: Filter?,
		caster: Caster?,
		extra: Extra?
	) -> RollbackHit?,
	characterPoseAt: (self: Rollback, time: number, character: Model) -> { [string]: CFrame }?,
	clear: (self: Rollback) -> (),
	autoCapturePlayers: (self: Rollback) -> () -> (),
	autoCaptureCharacters: (self: Rollback, folder: Instance) -> () -> (),
	autoCaptureCharacter: (self: Rollback, character: Model) -> () -> (),
}

export type World = {
	cast: (self: World, options: CastOptions) -> (),
	hitscan: (self: World, options: CastOptions) -> (),
	rollback: Rollback,
	destroy: (self: World) -> (),
}

return Types
