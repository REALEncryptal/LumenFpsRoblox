--!strict
--!optimize 2

--> Single-frame hitscan resolver. Runs entirely on the main thread (no actor
--> dispatch) because there's no per-tick state to step — one call resolves the
--> whole ray, ricochets, penetration, and collateral character hits in one
--> tight loop. Server-side: queries the main-thread Rollback for lag-
--> compensated character hits. Client-side: skips the character query (the
--> client World has no rollback path) and produces a pure world-geometry
--> resolution suitable for predictive visuals.
-->
--> The state shape passed to `Penetration.tryRicochet` mirrors the fields the
--> projectile loop uses: `angle`, `loss`, `speed`, `origin`, `velocity`. When
--> `state.speed` reaches zero (after `loss` accumulates), the top-of-loop
--> guard terminates the scan — no `state.velocity.Unit` evaluation on a zero
--> vector.

local Types = require(script.Parent.Types)
local Definitions = require(script.Parent.Definitions)
local Rollback = require(script.Parent.Rollback)
local Penetration = require(script.Parent.Simulation.Penetration)
local Projectile = require(script.Parent.Simulation.Projectile)

local DEFAULT_RANGE = 1024
local MAX_ITERATIONS = 16
local EPSILON = 1e-3

export type Config = {
	defaultRaycastFilter: RaycastParams,
	penetration: Types.PenetrationConfig,
	excludeContainers: { Instance },
}

export type Context = {
	definitions: Definitions.Definitions,
	rollback: Rollback.Rollback,
	config: Config,
	terrain: Terrain,
	isServer: boolean,
}

type State = {
	angle: number,
	loss: number,
	speed: number,
	power: number,
	origin: Vector3,
	velocity: Vector3,
}

local Hitscan = {}

local function cloneRaycastParams(source: RaycastParams): RaycastParams
	local clone = RaycastParams.new()
	clone.FilterType = source.FilterType
	clone.IgnoreWater = source.IgnoreWater
	clone.CollisionGroup = source.CollisionGroup
	clone.FilterDescendantsInstances = source.FilterDescendantsInstances
	return clone
end

local function newIncludeFilter(): RaycastParams
	local include = RaycastParams.new()
	include.FilterType = Enum.RaycastFilterType.Include
	return include
end

local function fireImpact(
	definition: Types.ProjectileDefinition,
	type: string,
	caster: Types.Caster,
	direction: Vector3,
	result: RaycastResult,
	extra: Types.Extra
)
	local callback = definition.onImpact
	if not callback then
		return
	end
	callback({
		type = type,
		caster = caster,
		direction = direction,
		instance = result.Instance,
		normal = result.Normal,
		position = result.Position,
		material = result.Material,
		extra = extra,
	})
end

local function fireIntersection(
	definition: Types.ProjectileDefinition,
	type: string,
	caster: Types.Caster,
	direction: Vector3,
	hit: Types.RollbackHit,
	extra: Types.Extra
)
	local callback = definition.onIntersection
	if not callback then
		return
	end
	callback({
		type = type,
		caster = caster,
		direction = direction,
		part = hit.part,
		player = hit.player,
		character = hit.character,
		position = hit.position,
		extra = extra,
	})
end

function Hitscan.resolve(context: Context, options: Types.CastOptions): ()
	local definition = context.definitions:get(options.type)
	if not definition then
		warn(`Hindsight: unknown hitscan type "{options.type}"`)
		return
	end
	local resolved = Projectile.resolveDefinition(definition, options.modifier)

	local direction = options.direction
	if direction.Magnitude > 1 + 1e-4 or direction.Magnitude < 1 - 1e-4 then
		direction = direction.Unit
	end

	local seedSpeed = math.max(resolved.velocity, 1)
	local state: State = {
		angle = math.rad(resolved.angle),
		loss = resolved.loss,
		speed = seedSpeed,
		power = resolved.power,
		origin = options.origin,
		velocity = direction * seedSpeed,
	}

	local raycastFilter = cloneRaycastParams(resolved.raycastFilter or context.config.defaultRaycastFilter)
	local extra = (options.modifier and options.modifier.extra) or {}
	local collaterals = resolved.collaterals == true
	local range = resolved.range or DEFAULT_RANGE

	for _ = 1, MAX_ITERATIONS do
		if range <= EPSILON or state.speed <= 0 then
			return
		end

		local rayDirection = state.velocity.Unit
		local segment = rayDirection * range
		local worldHit = workspace:Raycast(state.origin, segment, raycastFilter)
		local worldDistance = if worldHit then (worldHit.Position - state.origin).Magnitude else range

		if context.isServer and worldDistance > 0 then
			local charHit = context.rollback:queryRay(
				options.timestamp,
				state.origin,
				rayDirection,
				worldDistance,
				resolved.filter,
				options.caster,
				extra
			)
			if charHit then
				fireIntersection(resolved, options.type, options.caster, state.velocity, charHit, extra)
				if not collaterals then
					return
				end
				local advance = charHit.distance + EPSILON
				state.origin = charHit.position + rayDirection * EPSILON
				range -= advance
				continue
			end
		end

		if not worldHit then
			return
		end

		local unitDirection = rayDirection
		local normal = worldHit.Normal
		local surfaceAngle = math.acos(math.clamp(unitDirection:Dot(normal.Unit), -1, 1))
		local hardness = context.config.penetration.surfaceHardness[worldHit.Material]
			or context.config.penetration.defaultHardness

		local preRicochetOrigin = state.origin
		local ricocheted = Penetration.tryRicochet(
			state,
			worldHit.Position,
			unitDirection,
			normal,
			surfaceAngle,
			hardness,
			context.config.penetration
		)
		if ricocheted then
			range -= (state.origin - preRicochetOrigin).Magnitude
			continue
		end

		if worldHit.Instance == context.terrain then
			fireImpact(resolved, options.type, options.caster, state.velocity, worldHit, extra)
			return
		end

		local includeFilter = newIncludeFilter()
		local compound = Penetration.computeCompound(
			worldHit.Position,
			unitDirection,
			worldHit.Instance,
			worldHit.Material,
			context.config.penetration,
			raycastFilter,
			includeFilter,
			context.config.excludeContainers,
			context.terrain
		)

		if state.power < compound.cost then
			fireImpact(resolved, options.type, options.caster, state.velocity, worldHit, extra)
			return
		end

		state.power -= compound.cost
		range -= (compound.exitPosition - state.origin).Magnitude
		state.origin = compound.exitPosition
	end
end

return Hitscan
