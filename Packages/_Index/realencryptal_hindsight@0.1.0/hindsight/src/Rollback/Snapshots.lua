--!strict
--!optimize 2

--> Snapshot ring buffer. The caller pushes a CharacterPoses map every tick;
--> Snapshots stores it alongside a freshly built voxel grid keyed on root
--> position. Reads bracket a query time across two snapshots, then a higher-
--> level module (Rollback/init.lua) interpolates between them.

local Types = require(script.Parent.Parent.Types)
local Voxels = require(script.Parent.Voxels)

type Character = Model

export type Record = {
	rig: string,
	rootPosition: Vector3,
	parts: { CFrame },
	player: Player?,
}

export type Snapshot = {
	time: number,
	grid: Voxels.Grid<Character>,
	records: { [Character]: Record },
}

export type Store = {
	snapshots: { Snapshot },
	lifetime: number,
	rigs: { [string]: Types.Rig },
	hitboxSize: Vector3,
	space: Voxels.Space,
}

local Snapshots = {}

function Snapshots.create(lifetime: number, rigs: { [string]: Types.Rig }, hitboxSize: Vector3, space: Voxels.Space): Store
	assert(lifetime > 0, "lifetime must be positive")
	return {
		snapshots = {},
		lifetime = lifetime,
		rigs = rigs,
		hitboxSize = hitboxSize,
		space = space,
	}
end

function Snapshots.push(store: Store, time: number, poses: Types.CharacterPoses)
	local positions: { [Character]: Vector3 } = {}
	local records: { [Character]: Record } = {}

	for character, pose in poses do
		local rig = store.rigs[pose.rig]
		if not rig then
			continue
		end
		if #pose.parts ~= #rig.parts then
			continue
		end

		positions[character] = pose.rootPosition
		records[character] = {
			rig = pose.rig,
			rootPosition = pose.rootPosition,
			parts = pose.parts,
			player = pose.player,
		}
	end

	table.insert(store.snapshots, {
		time = time,
		grid = Voxels.buildGrid(store.space, positions, store.hitboxSize),
		records = records,
	})

	--> Expire from the back in case multiple snapshots aged out in one tick.
	for index = #store.snapshots, 1, -1 do
		if (time - store.snapshots[index].time) > store.lifetime then
			table.remove(store.snapshots, index)
		end
	end
end

--> Returns (previous, next, fraction). `fraction` is 0 at previous, 1 at next.
--> Caller does the actual interpolation — this only finds the bracketing pair.
function Snapshots.bracket(store: Store, time: number): (Snapshot?, Snapshot?, number?)
	local list = store.snapshots
	for index = #list - 1, 1, -1 do
		local current = list[index]
		if current.time < time then
			local nextSnap = list[index + 1]
			local frac = (time - current.time) / (nextSnap.time - current.time)
			return current, nextSnap, frac
		end
	end
	return nil, nil, nil
end

function Snapshots.clear(store: Store)
	table.clear(store.snapshots)
end

return Snapshots
