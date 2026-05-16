--!strict
--!native
--!optimize 2

--> Penetration + ricochet decision logic, extracted from the per-frame
--> simulation loop. Two responsibilities:
--> 1. `tryRicochet` — decide whether a surface bounces the projectile and, if
-->    so, mutate origin/speed/velocity in place.
--> 2. `computeCompound` — gather every part that forms a single penetrable
-->    medium (touching or near-touching parts merge), return the total cost.

local Types = require(script.Parent.Parent.Types)

local FULL_CIRCLE = math.pi * 2
local COMPOUND_PROBE_EPSILON = 1e-3

local Penetration = {}

export type CompoundResult = {
	exitPosition: Vector3,
	cost: number,
	parts: { [BasePart]: boolean },
}

type RicochetState = {
	angle: number,
	loss: number,
	speed: number,
	origin: Vector3,
	velocity: Vector3,
}

function Penetration.tryRicochet(
	state: RicochetState,
	raycastPosition: Vector3,
	unitDirection: Vector3,
	normal: Vector3,
	surfaceAngle: number,
	surfaceHardness: number,
	config: Types.PenetrationConfig
): boolean
	local alwaysBounces = state.angle == FULL_CIRCLE
	local steepEnoughHardEnough = state.angle >= surfaceAngle and surfaceHardness >= config.ricochetHardness
	if not (alwaysBounces or steepEnoughHardEnough) then
		return false
	end

	state.origin = raycastPosition
	state.speed = math.max(0, state.speed - state.loss)
	state.velocity = (unitDirection - 2 * unitDirection:Dot(normal) * normal).Unit * state.speed
	return true
end

--> `raycastFilter` and `includeFilter` are mutated in place — every part that
--> joins the compound is added to both so future probes skip it. Caller passes
--> exactly the filters that the simulation loop already owns for this
--> projectile.
function Penetration.computeCompound(
	raycastPosition: Vector3,
	unitDirection: Vector3,
	firstPart: BasePart,
	firstMaterial: Enum.Material,
	config: Types.PenetrationConfig,
	raycastFilter: RaycastParams,
	includeFilter: RaycastParams,
	excludeContainers: { Instance },
	terrain: Terrain
): CompoundResult
	local entry = raycastPosition
	local exit = raycastPosition
	local hardnessSum = 0
	local partCount = 0
	local spanBound = 0
	local merged: { [BasePart]: boolean } = {}

	local currentPart: BasePart? = firstPart
	local currentHardness = config.surfaceHardness[firstMaterial] or config.defaultHardness

	for _ = 1, config.maxCompoundMediumParts do
		if not currentPart then
			break
		end

		--> AddToFilter is parallel-safe on RaycastParams; direct assignment of
		--> FilterDescendantsInstances is not.
		includeFilter:AddToFilter(currentPart)
		raycastFilter:AddToFilter(currentPart)
		merged[currentPart] = true
		hardnessSum += currentHardness
		partCount += 1
		spanBound += currentPart.Size.Magnitude

		--> Reverse-cast across every merged part to find the running compound
		--> exit. Each iteration can only push the exit further from `entry`.
		local span = -unitDirection * (spanBound + 1)
		local reverseOrigin = entry - span
		local reverseResult = workspace:Raycast(reverseOrigin, span, includeFilter)
		if reverseResult then
			exit = reverseResult.Position
		end

		currentPart = nil
		--> Pass 1: tiny forward raycast catches parts separated by a sub-
		--> threshold air gap.
		local probeOrigin = exit + unitDirection * COMPOUND_PROBE_EPSILON
		local probeHit = workspace:Raycast(probeOrigin, unitDirection * config.mediumGapThreshold, raycastFilter)
		if probeHit and probeHit.Instance ~= terrain then
			currentPart = probeHit.Instance
			currentHardness = config.surfaceHardness[probeHit.Material] or config.defaultHardness
		else
			--> Pass 2: spatial overlap — Roblox raycasts return nil when the
			--> origin is inside the part, so face-to-face / engulfing cases
			--> need a region query. Called without OverlapParams (parallel-
			--> unsafe), so candidates are filtered in Lua.
			local overlaps = workspace:GetPartBoundsInBox(
				CFrame.new(exit + unitDirection * (config.mediumGapThreshold * 0.5)),
				Vector3.new(COMPOUND_PROBE_EPSILON, COMPOUND_PROBE_EPSILON, config.mediumGapThreshold)
			)
			for _, candidate in overlaps do
				if candidate == terrain or merged[candidate] then
					continue
				end
				local skip = false
				for _, container in excludeContainers do
					if candidate:IsDescendantOf(container) then
						skip = true
						break
					end
				end
				if skip then
					continue
				end
				currentPart = candidate
				currentHardness = config.surfaceHardness[candidate.Material] or config.defaultHardness
				break
			end
		end
	end

	local thickness = (exit - entry).Magnitude
	local averageHardness = partCount > 0 and (hardnessSum / partCount) or 0
	return {
		exitPosition = exit,
		cost = thickness * averageHardness,
		parts = merged,
	}
end

return Penetration
