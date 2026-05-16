--!strict
--!optimize 2

--> Projectile state struct + the per-cast builder that merges a definition
--> with a modifier (modifier wins on every field it provides). Behaviour lives
--> in the simulation loop; this module is data + assembly.

local Types = require(script.Parent.Parent.Types)

local Projectile = {}

export type State = {
	type: string,
	caster: Types.Caster,

	origin: Vector3,
	gravity: Vector3,
	velocity: Vector3,
	position: Vector3,

	loss: number,
	power: number,
	speed: number,
	angle: number,

	tick: number,
	step: number,
	time: number,
	lifetime: number,
	timestamp: number,

	raycastFilter: RaycastParams,
	includeFilter: RaycastParams,
	filter: Types.Filter?,
	collaterals: boolean,

	instance: PVInstance?,
	extra: Types.Extra,
}

local function cloneRaycastParams(source: RaycastParams): RaycastParams
	local clone = RaycastParams.new()
	clone.FilterType = source.FilterType
	clone.IgnoreWater = source.IgnoreWater
	clone.CollisionGroup = source.CollisionGroup
	clone.FilterDescendantsInstances = source.FilterDescendantsInstances
	return clone
end

--> Merges a definition with an optional modifier. Modifier wins on every field
--> it provides; everything else falls back to the definition.
function Projectile.resolveDefinition(
	definition: Types.ProjectileDefinition,
	modifier: Types.ProjectileModifier?
): Types.ProjectileDefinition
	if not modifier then
		return definition
	end

	local merged = table.clone(definition)
	for key, value in modifier :: any do
		if value ~= nil then
			(merged :: any)[key] = value
		end
	end
	return merged
end

export type BuildContext = {
	defaultRaycastFilter: RaycastParams,
	now: number,
}

function Projectile.build(
	type: string,
	caster: Types.Caster,
	origin: Vector3,
	direction: Vector3,
	timestamp: number,
	visual: PVInstance?,
	resolved: Types.ProjectileDefinition,
	modifier: Types.ProjectileModifier?,
	context: BuildContext
): State
	local raycastFilter = cloneRaycastParams(resolved.raycastFilter or context.defaultRaycastFilter)
	local includeFilter = RaycastParams.new()
	includeFilter.FilterType = Enum.RaycastFilterType.Include

	return {
		type = type,
		caster = caster,

		origin = origin,
		gravity = resolved.gravity,
		velocity = direction * resolved.velocity,
		position = origin,

		loss = resolved.loss,
		power = resolved.power,
		speed = resolved.velocity,
		angle = math.rad(resolved.angle),

		tick = context.now,
		step = 0,
		time = 0,
		lifetime = resolved.lifetime,
		timestamp = timestamp,

		raycastFilter = raycastFilter,
		includeFilter = includeFilter,
		filter = resolved.filter,
		collaterals = resolved.collaterals == true,

		instance = visual,
		extra = (modifier and modifier.extra) or {},
	}
end

return Projectile
