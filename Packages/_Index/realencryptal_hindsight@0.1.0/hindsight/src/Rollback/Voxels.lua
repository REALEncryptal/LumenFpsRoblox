--!strict
--!native

--> Voxel broadphase: each character lives in one or more voxel cells based on
--> root position + hitbox half-extents. A ray query walks the cells along the
--> ray (DDA) and gathers candidates instead of testing every character. The
--> grid's world-space center and size are caller-supplied so the lib never
--> assumes a particular world layout.

local Voxels = {}

export type Grid<T> = { [Vector3]: { [T]: boolean } }

export type Space = {
	voxelSize: number,
	gridCorner: CFrame,
}

local function floorVector(v: Vector3): Vector3
	return Vector3.new(math.floor(v.X), math.floor(v.Y), math.floor(v.Z))
end

function Voxels.createSpace(voxelSize: number, gridCenter: Vector3, gridSize: Vector3): Space
	assert(voxelSize > 0, "voxelSize must be positive")
	return {
		voxelSize = voxelSize,
		gridCorner = CFrame.new(gridCenter - gridSize / 2),
	}
end

local function insert<T>(grid: Grid<T>, key: Vector3, value: T)
	local cell = grid[key]
	if not cell then
		cell = {}
		grid[key] = cell
	end
	cell[value] = true
end

--> `inputs[value] = worldPosition`. `bounds` is half-extents in world units;
--> values whose AABB straddles cell faces are inserted into all overlapping
--> cells (centre cell plus axis-extents) so a ray that only clips the AABB
--> still finds them.
function Voxels.buildGrid<T>(space: Space, inputs: { [T]: Vector3 }, bounds: Vector3): Grid<T>
	local grid: Grid<T> = {}
	local voxelSize = space.voxelSize
	local cornerSpace = space.gridCorner
	local boundsLocal = bounds / voxelSize
	local hasBounds = bounds.X > 0 or bounds.Y > 0 or bounds.Z > 0

	for value, worldPosition in inputs do
		local local_ = cornerSpace:PointToObjectSpace(worldPosition) / voxelSize

		if hasBounds then
			local maximum = floorVector(local_ + boundsLocal)
			local minimum = floorVector(local_ - boundsLocal)

			insert(grid, Vector3.new(maximum.X, local_.Y, local_.Z), value)
			insert(grid, Vector3.new(minimum.X, local_.Y, local_.Z), value)
			insert(grid, Vector3.new(local_.X, maximum.Y, local_.Z), value)
			insert(grid, Vector3.new(local_.X, minimum.Y, local_.Z), value)
			insert(grid, Vector3.new(local_.X, local_.Y, maximum.Z), value)
			insert(grid, Vector3.new(local_.X, local_.Y, minimum.Z), value)
		end

		insert(grid, floorVector(local_), value)
	end

	return grid
end

--> Amanatides-Woo voxel traversal. Returns the union of values stored in every
--> cell the ray passes through.
function Voxels.traverseGrid<T>(space: Space, origin: Vector3, direction: Vector3, grid: Grid<T>): { [T]: boolean }
	local voxelSize = space.voxelSize
	local cornerSpace = space.gridCorner

	local rayStart = cornerSpace:PointToObjectSpace(origin) / voxelSize
	local rayEnd = cornerSpace:PointToObjectSpace(origin + direction) / voxelSize
	local rayDirection = rayEnd - rayStart

	local x = math.floor(rayStart.X)
	local y = math.floor(rayStart.Y)
	local z = math.floor(rayStart.Z)

	--> Same start and end cell — single lookup, skip DDA setup entirely.
	if x == math.floor(rayEnd.X) and y == math.floor(rayEnd.Y) and z == math.floor(rayEnd.Z) then
		return grid[Vector3.new(x, y, z)] or {}
	end

	local stepX = math.sign(rayDirection.X)
	local stepY = math.sign(rayDirection.Y)
	local stepZ = math.sign(rayDirection.Z)

	local tX, dX = math.huge, math.huge
	if stepX ~= 0 then
		dX = stepX / rayDirection.X
		tX = stepX > 0 and dX * (1 - rayStart.X + x) or dX * (rayStart.X - x)
	end

	local tY, dY = math.huge, math.huge
	if stepY ~= 0 then
		dY = stepY / rayDirection.Y
		tY = stepY > 0 and dY * (1 - rayStart.Y + y) or dY * (rayStart.Y - y)
	end

	local tZ, dZ = math.huge, math.huge
	if stepZ ~= 0 then
		dZ = stepZ / rayDirection.Z
		tZ = stepZ > 0 and dZ * (1 - rayStart.Z + z) or dZ * (rayStart.Z - z)
	end

	local visited: { { [T]: boolean } } = {}
	while true do
		local cell = grid[Vector3.new(x, y, z)]
		if cell then
			table.insert(visited, cell)
		end

		if tX > 1 and tY > 1 and tZ > 1 then
			break
		end

		if tZ < tX and tZ < tY then
			z += stepZ
			tZ += dZ
		elseif tX < tY then
			x += stepX
			tX += dX
		else
			y += stepY
			tY += dY
		end
	end

	local result: { [T]: boolean } = {}
	for _, cell in visited do
		for item in cell do
			result[item] = true
		end
	end
	return result
end

return Voxels
