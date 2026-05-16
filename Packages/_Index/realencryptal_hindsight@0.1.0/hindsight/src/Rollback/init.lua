--!strict
--!optimize 2

--> Public Rollback object. Owns the snapshot store and exposes the writer
--> (`capture`) plus two readers (`queryRay` for ray-against-history, and
--> `characterPoseAt` for inspecting one character's pose at a past time). The
--> reader path is what backs the projectile simulator's lag-compensated player
--> hit detection — but it's also usable on its own for hit-scan, melee cones,
--> ability validation, etc.

local Types = require(script.Parent.Types)
local Raycast = require(script.Parent.Physics.Raycast)
local Voxels = require(script.Voxels)
local Snapshots = require(script.Snapshots)

type Character = Model

type Self = {
	_store: Snapshots.Store,
	_rigs: { [string]: Types.Rig },
	_space: Voxels.Space,
	_hitboxSize: Vector3,
}

local Rollback = {}
Rollback.__index = Rollback

export type Rollback = typeof(setmetatable({} :: Self, Rollback))

function Rollback.new(config: Types.RollbackConfig): Rollback
	local space = Voxels.createSpace(config.voxelSize, config.gridCenter, config.gridSize)
	local store = Snapshots.create(config.lifetime, config.rigs, config.hitboxSize, space)

	local self: Self = {
		_store = store,
		_rigs = config.rigs,
		_space = space,
		_hitboxSize = config.hitboxSize,
	}
	return (setmetatable(self, Rollback) :: any) :: Rollback
end

function Rollback.capture(self: Rollback, time: number, poses: Types.CharacterPoses)
	Snapshots.push(self._store, time, poses)
end

function Rollback.clear(self: Rollback)
	Snapshots.clear(self._store)
end

--> Returns a part-name → interpolated CFrame map at the requested time, or
--> nil if the character has no record bracketing that time.
function Rollback.characterPoseAt(self: Rollback, time: number, character: Model): { [string]: CFrame }?
	local previous, nextSnap, fraction = Snapshots.bracket(self._store, time)
	if not previous or not nextSnap or not fraction then
		return nil
	end

	local previousRecord = previous.records[character]
	local nextRecord = nextSnap.records[character]
	if not previousRecord or not nextRecord then
		return nil
	end

	local rig = self._rigs[nextRecord.rig]
	if not rig then
		return nil
	end

	local pose: { [string]: CFrame } = {}
	for index, partName in rig.parts do
		pose[partName] = previousRecord.parts[index]:Lerp(nextRecord.parts[index], fraction)
	end
	return pose
end

--> Ray query against the snapshot at `time`. Returns the first character whose
--> per-part OBB the ray intersects, after broadphase voxel traversal + AABB
--> mid-phase culling. `direction` must be normalized; `length` is the scan
--> distance in studs.
function Rollback.queryRay(
	self: Rollback,
	time: number,
	origin: Vector3,
	direction: Vector3,
	length: number,
	filter: Types.Filter?,
	caster: Types.Caster?,
	extra: Types.Extra?
): Types.RollbackHit?
	if filter and not caster then
		error("Rollback:queryRay called with a filter but no caster — filter requires a caster.", 2)
	end

	local previous, nextSnap, fraction = Snapshots.bracket(self._store, time)
	if not previous or not nextSnap or not fraction then
		return nil
	end

	local fullRay = direction * length
	local inverse = 1 / fullRay
	local candidates = Voxels.traverseGrid(self._space, origin, fullRay, previous.grid)
	local effectiveExtra = extra or {}

	for character in candidates do
		local previousRecord = previous.records[character]
		local nextRecord = nextSnap.records[character]
		if not previousRecord or not nextRecord then
			continue
		end

		local player = nextRecord.player or previousRecord.player
		if filter and filter((caster :: any) :: Types.Caster, player, character, effectiveExtra) then
			continue
		end

		local lerpedPosition = previousRecord.rootPosition:Lerp(nextRecord.rootPosition, fraction)
		if not Raycast.aabb(origin, inverse, lerpedPosition, self._hitboxSize) then
			continue
		end

		local rig = self._rigs[nextRecord.rig]
		if not rig then
			continue
		end

		local partNames = rig.parts
		local partSizes = rig.sizes
		for index, previousCFrame in previousRecord.parts do
			local interpolated = previousCFrame:Lerp(nextRecord.parts[index], fraction)
			local hitDistance = Raycast.obb(length, origin, direction, partSizes[index], interpolated)
			if hitDistance then
				return {
					player = player,
					character = character,
					part = partNames[index],
					position = origin + direction * hitDistance,
					distance = hitDistance,
				}
			end
		end
	end

	return nil
end

return Rollback
