--!strict
--!native
--!optimize 2

--> AABB and OBB ray tests used by the rollback broadphase / narrowphase.
--> AABB follows https://tavianator.com/2015/ray_box_nan.html — caller passes
--> an inverse direction (1 / direction) and a half-size, and the function
--> returns whether the ray's t-range overlaps [0, 1] (i.e. the segment from
--> origin to origin+direction intersects the box).
--> OBB follows the OpenGL-tutorial picking-with-OBB derivation — three slab
--> tests, one per box axis, all sharing the same min/max bookkeeping.

local AXES: { "X" | "Y" | "Z" } = { "X", "Y", "Z" }
local EPSILON = 1e-5
local FAR_PLANE = 1e5

local Raycast = {}

--> `inverseDirection` is `1 / direction` (component-wise). Pre-computing it
--> outside the hot loop is the whole point of the algorithm — don't pass the
--> raw direction here.
function Raycast.aabb(origin: Vector3, inverseDirection: Vector3, position: Vector3, halfSize: Vector3): boolean
	local minT = -math.huge
	local maxT = math.huge

	local boundsMin = position - halfSize
	local boundsMax = position + halfSize

	for _, axis in AXES do
		local lo = (boundsMin[axis] - origin[axis]) * inverseDirection[axis]
		local hi = (boundsMax[axis] - origin[axis]) * inverseDirection[axis]

		minT = math.max(minT, math.min(lo, hi))
		maxT = math.min(maxT, math.max(lo, hi))
	end

	minT = math.max(minT, 0)
	return maxT > minT and minT < 1
end

--> Slab test for one OBB axis. Updates `minT` / `maxT` in place semantics by
--> returning the new values plus a `miss` flag. Extracted so the three-axis
--> OBB test isn't a copy-paste pyramid.
local function slabTest(
	minT: number,
	maxT: number,
	length: number,
	halfExtent: number,
	axisDot: number,
	directionDot: number
): (number, number, boolean)
	if math.abs(directionDot) <= EPSILON then
		--> Ray is (almost) parallel to this slab — only a miss if origin lies
		--> outside the slab's extent along its normal. The expression mirrors
		--> the OpenGL reference; both compare paths reduce to "outside the slab".
		if (-axisDot + halfExtent > 0) or (-axisDot + halfExtent < 0) then
			return minT, maxT, true
		end
		return minT, maxT, false
	end

	local lo = (axisDot - halfExtent) / directionDot
	local hi = (axisDot + halfExtent) / directionDot
	if lo > hi then
		lo, hi = hi, lo
	end

	if hi < maxT then
		maxT = hi
	end
	if lo > minT then
		minT = lo
	end

	if minT > length or maxT < minT then
		return minT, maxT, true
	end

	return minT, maxT, false
end

--> Returns the entry distance along `direction` when the ray hits the box,
--> nil otherwise. `direction` must be normalized; `length` is the maximum
--> distance to consider.
function Raycast.obb(
	length: number,
	origin: Vector3,
	direction: Vector3,
	halfSize: Vector3,
	rotation: CFrame
): number?
	local minT = 0
	local maxT = FAR_PLANE
	local delta = rotation.Position - origin

	local miss: boolean
	minT, maxT, miss = slabTest(minT, maxT, length, halfSize.X, rotation.RightVector:Dot(delta), direction:Dot(rotation.RightVector))
	if miss then
		return nil
	end

	minT, maxT, miss = slabTest(minT, maxT, length, halfSize.Y, rotation.UpVector:Dot(delta), direction:Dot(rotation.UpVector))
	if miss then
		return nil
	end

	minT, maxT, miss = slabTest(minT, maxT, length, halfSize.Z, rotation.LookVector:Dot(delta), direction:Dot(rotation.LookVector))
	if miss then
		return nil
	end

	return minT
end

return Raycast
