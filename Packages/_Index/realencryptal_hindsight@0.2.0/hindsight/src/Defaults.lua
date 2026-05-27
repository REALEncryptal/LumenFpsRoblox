--!strict

--> Built-in defaults used when the caller omits a config block on
--> `createWorld`. Exposed at the top level (`Hindsight.Defaults`) so debug
--> tooling can introspect the values the world is actually running with.

local Types = require(script.Parent.Types)

local R15: Types.Rig = {
	parts = {
		"Head",
		"UpperTorso",
		"LowerTorso",
		"LeftUpperArm",
		"LeftLowerArm",
		"LeftHand",
		"RightUpperArm",
		"RightLowerArm",
		"RightHand",
		"LeftUpperLeg",
		"LeftLowerLeg",
		"LeftFoot",
		"RightUpperLeg",
		"RightLowerLeg",
		"RightFoot",
	},
	sizes = {
		Vector3.new(1.161, 1.181, 1.161) / 2,
		Vector3.new(1.943, 1.698, 1.004) / 2,
		Vector3.new(1.991, 0.401, 1.004) / 2,
		Vector3.new(1.001, 1.242, 1.002) / 2,
		Vector3.new(1.001, 1.118, 1.002) / 2,
		Vector3.new(0.984, 0.316, 1.028) / 2,
		Vector3.new(1.001, 1.242, 1.002) / 2,
		Vector3.new(1.001, 1.118, 1.002) / 2,
		Vector3.new(0.984, 0.316, 1.028) / 2,
		Vector3.new(0.993, 1.363, 0.973) / 2,
		Vector3.new(0.993, 1.301, 0.973) / 2,
		Vector3.new(1.009, 0.312, 1.001) / 2,
		Vector3.new(0.993, 1.363, 0.973) / 2,
		Vector3.new(0.993, 1.301, 0.973) / 2,
		Vector3.new(1.009, 0.312, 1.001) / 2,
	},
}

local R6: Types.Rig = {
	parts = { "Head", "Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg" },
	sizes = {
		Vector3.new(1.161, 1.181, 1.161) / 2,
		Vector3.new(2, 2, 1) / 2,
		Vector3.new(1, 2, 1) / 2,
		Vector3.new(1, 2, 1) / 2,
		Vector3.new(1, 2, 1) / 2,
		Vector3.new(1, 2, 1) / 2,
	},
}

--[=[
	@class Defaults

	The built-in defaults used when a [`WorldConfig`](Hindsight#WorldConfig)
	field is omitted. Exposed at the top level as `Hindsight.Defaults` so debug
	tooling can introspect the values the world is actually running with, and
	so user code can clone-and-edit a single field without rewriting an entire
	config block.

	```lua
	local rollback = table.clone(Hindsight.Defaults.rollback)
	rollback.lifetime = 2 -- longer history for very high-ping games

	local world = Hindsight.createWorld({
	    actorContainer    = ServerScriptService,
	    definitionsModule = definitionsModule,
	    rollback          = rollback,
	})
	```
]=]

--[=[
	@prop rigs { [string]: Rig }
	@within Defaults

	Hitbox layouts for the built-in `R15` and `R6` rigs. The sizes come from
	default Roblox avatar measurements (half-extents in studs).
]=]

--[=[
	@prop rollback RollbackConfig
	@within Defaults

	Default snapshot store configuration:
	```
	lifetime   = 1
	voxelSize  = 32
	gridCenter = Vector3.zero
	gridSize   = Vector3.new(4096, 512, 4096)
	hitboxSize = Vector3.new(3, 3, 3)
	rigs       = Defaults.rigs
	```
]=]

--[=[
	@prop penetration PenetrationConfig
	@within Defaults

	Default penetration model:
	```
	surfaceHardness        = { [Wood] = 2, [Concrete] = 10 }
	defaultHardness        = 10
	ricochetHardness       = 10
	mediumGapThreshold     = 0.1
	maxCompoundMediumParts = 32
	```
]=]

local Defaults = {}

Defaults.rigs = { R15 = R15, R6 = R6 }

Defaults.rollback = {
	lifetime = 1,
	voxelSize = 32,
	gridCenter = Vector3.zero,
	gridSize = Vector3.new(4096, 512, 4096),
	hitboxSize = Vector3.new(3, 3, 3),
	rigs = Defaults.rigs,
} :: Types.RollbackConfig

Defaults.penetration = {
	surfaceHardness = {
		[Enum.Material.Wood] = 2,
		[Enum.Material.Concrete] = 10,
	},
	defaultHardness = 10,
	ricochetHardness = 10,
	mediumGapThreshold = 0.1,
	maxCompoundMediumParts = 32,
} :: Types.PenetrationConfig

return Defaults
