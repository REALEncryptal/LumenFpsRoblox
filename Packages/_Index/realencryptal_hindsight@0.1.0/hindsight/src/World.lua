--!strict

--> World object. Owns the actor pool (Dispatcher), the main-thread definitions
--> registry, and the main-thread Rollback store. Casts forward to the least-
--> loaded actor; rollback captures fan out to every actor + the main store;
--> rollback reads come from the main store.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Types = require(script.Parent.Types)
local Defaults = require(script.Parent.Defaults)
local Definitions = require(script.Parent.Definitions)
local Dispatcher = require(script.Parent.Dispatcher)
local Rollback = require(script.Parent.Rollback)
local Simulation = require(script.Parent.Simulation)

local DEFAULT_THREADS = 16
local DEFAULT_SERVER_FRAME_RATE = 1 / 60
local DEFAULT_FRAME_TIME_BUDGET = 0.5
local DEFAULT_INTERPOLATION = 0.048

--[=[
	@class World

	A simulation world. Owns the actor pool, the snapshot store, and the
	projectile definitions registry. Built by [`Hindsight.createWorld`](Hindsight#createWorld).

	A typical server uses one World; clients use one World per peer for
	visuals only. Server and client Worlds do not share state — both speak the
	same definitions module independently because each Actor `require`s the
	module in its own VM.
]=]

--[=[
	@class Rollback

	The snapshot store half of Hindsight. Reachable via [`World.rollback`](World#rollback).

	Owns both the **writer** ([`capture`](#capture)) and the **readers**
	([`queryRay`](#queryRay), [`characterPoseAt`](#characterPoseAt)). When held
	by a World, the writer fans out to every simulation actor; the reader
	queries the main-thread store.

	The auto-capture helpers ([`autoCapturePlayers`](#autoCapturePlayers),
	[`autoCaptureCharacters`](#autoCaptureCharacters),
	[`autoCaptureCharacter`](#autoCaptureCharacter)) are server-only opt-ins.
	Each registers a "source" of characters with the proxy; the proxy runs a
	single `PostSimulation` hook that walks every registered source, builds one
	merged [`CharacterPoses`](Hindsight#CharacterPoses) table, and pushes it.
	Mixing helpers is safe — all sources contribute to the same snapshot per
	tick.
]=]

--[=[
	@prop rollback Rollback
	@within World

	The rollback store. See the [`Rollback`](Rollback) class for the full
	method list.
]=]

type PoseSource = (poses: Types.CharacterPoses) -> ()

local function rigNameForHumanoid(humanoid: Humanoid): string?
	if humanoid.RigType == Enum.HumanoidRigType.R15 then
		return "R15"
	end
	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		return "R6"
	end
	return nil
end

--> Builds a CharacterPose for one Model. Returns nil when the character isn't
--> ready (no humanoid, dead, missing parts, unknown rig). One place to make
--> "is this character snapshot-eligible" decisions.
local function buildPose(character: Model, rigs: { [string]: Types.Rig }): Types.CharacterPose?
	if character.Parent == nil then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end

	local rigName = rigNameForHumanoid(humanoid)
	if not rigName then
		return nil
	end
	local rig = rigs[rigName]
	if not rig then
		return nil
	end

	local root = character.PrimaryPart or character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end

	local parts: { CFrame } = table.create(#rig.parts)
	for index, name in rig.parts do
		local part = character:FindFirstChild(name)
		if not part or not part:IsA("BasePart") then
			return nil
		end
		parts[index] = part.CFrame
	end

	return {
		rig = rigName,
		rootPosition = root.Position,
		parts = parts,
		player = Players:GetPlayerFromCharacter(character),
	}
end

type RollbackProxySelf = {
	_main: Rollback.Rollback,
	_dispatcher: Dispatcher.Dispatcher,
	_rigs: { [string]: Types.Rig },
	_sources: { PoseSource },
	_connection: RBXScriptConnection?,
}

local RollbackProxy = {}
RollbackProxy.__index = RollbackProxy

local function newRollbackProxy(
	main: Rollback.Rollback,
	dispatcher: Dispatcher.Dispatcher,
	rigs: { [string]: Types.Rig }
): Types.Rollback
	local self: RollbackProxySelf = {
		_main = main,
		_dispatcher = dispatcher,
		_rigs = rigs,
		_sources = {},
		_connection = nil,
	}
	return (setmetatable(self, RollbackProxy) :: any) :: Types.Rollback
end

--> Wire format for the Capture broadcast. Character lives as a VALUE in each
--> entry, not as the table key — Roblox demotes Instance keys to their `.Name`
--> string when a table crosses an actor VM boundary, but Instance values in a
--> table survive intact.
type CaptureEntry = {
	character: Model,
	rig: string,
	rootPosition: Vector3,
	parts: { CFrame },
	player: Player?,
}

--[=[
	@within Rollback
	@method capture
	@server
	@param time number -- Server time the snapshot represents. Typically `workspace:GetServerTimeNow()`.
	@param poses CharacterPoses -- Map of character `Model` → [`CharacterPose`](Hindsight#CharacterPose).

	Pushes a snapshot of every character's current pose. Fans out to every
	simulation actor in addition to the main-thread store. Characters whose
	`parts` length doesn't match the configured rig are silently dropped.

	Most consumers should use one of the [`autoCapture*`](#autoCapturePlayers)
	helpers instead of calling this directly.
]=]
function RollbackProxy.capture(self: RollbackProxySelf, time: number, poses: Types.CharacterPoses)
	self._main:capture(time, poses)

	local entries: { CaptureEntry } = {}
	for character, pose in poses do
		table.insert(entries, {
			character = character,
			rig = pose.rig,
			rootPosition = pose.rootPosition,
			parts = pose.parts,
			player = pose.player,
		})
	end
	self._dispatcher:broadcast("Capture", time, entries)
end

--[=[
	@within Rollback
	@method clear

	Drops every retained snapshot from both the main-thread store and every
	simulation actor. Use on round transitions when "now" and "earlier" should
	not bracket the boundary.
]=]
function RollbackProxy.clear(self: RollbackProxySelf)
	self._main:clear()
	self._dispatcher:broadcast("ClearRollback")
end

--[=[
	@within Rollback
	@method queryRay
	@param time number -- Server time at which to evaluate the snapshot.
	@param origin Vector3 -- World-space ray origin.
	@param direction Vector3 -- Unit ray direction. Must be normalized.
	@param length number -- Maximum scan distance in studs.
	@param filter Filter? -- Optional skip predicate. Requires `caster` if provided.
	@param caster Caster? -- The Caster argument forwarded to `filter`.
	@param extra Extra? -- Extra table forwarded to `filter`.
	@return RollbackHit? -- First character whose per-part OBB the ray intersects, or `nil`.

	Ray query against the snapshot at `time`. Brackets `time` between two
	snapshots, interpolates each character's pose, runs a voxel broadphase +
	AABB midphase, then OBB narrowphase per part. Returns the **first** hit
	encountered — Hindsight does not aggregate multi-character hits in a
	single query.

	Returns `nil` if `time` is outside the retained snapshot window, or every
	candidate was filtered, or the ray missed.
]=]
function RollbackProxy.queryRay(
	self: RollbackProxySelf,
	time: number,
	origin: Vector3,
	direction: Vector3,
	length: number,
	filter: Types.Filter?,
	caster: Types.Caster?,
	extra: Types.Extra?
): Types.RollbackHit?
	return self._main:queryRay(time, origin, direction, length, filter, caster, extra)
end

--[=[
	@within Rollback
	@method characterPoseAt
	@param time number -- Server time at which to evaluate the snapshot.
	@param character Model -- The character to retrieve.
	@return { [string]: CFrame }? -- Part-name → interpolated CFrame, or `nil` if the snapshot doesn't bracket `time` for this character.

	Interpolated pose of a single character at a past time. Useful for debug
	rendering (e.g. "where was this player when the server saw the shot?")
	and for building custom hit shapes the standard `queryRay` doesn't cover.
]=]
function RollbackProxy.characterPoseAt(self: RollbackProxySelf, time: number, character: Model): { [string]: CFrame }?
	return self._main:characterPoseAt(time, character)
end

local function captureAll(self: RollbackProxySelf)
	local poses: Types.CharacterPoses = {}
	for _, source in self._sources do
		source(poses)
	end
	(self :: any):capture(workspace:GetServerTimeNow(), poses)
end

--> Registers a pose source. The first registration starts the shared
--> PostSimulation hook; the last disconnect stops it. Returns a disconnect
--> bound to this source.
local function addSource(self: RollbackProxySelf, source: PoseSource): () -> ()
	assert(RunService:IsServer(), "Rollback auto-capture helpers must be called from the server.")
	table.insert(self._sources, source)

	if not self._connection then
		self._connection = RunService.PostSimulation:Connect(function()
			captureAll(self)
		end)
	end

	return function()
		local index = table.find(self._sources, source)
		if index then
			table.remove(self._sources, index)
		end
		if #self._sources == 0 and self._connection then
			self._connection:Disconnect()
			self._connection = nil
		end
	end
end

--[=[
	@within Rollback
	@method autoCapturePlayers
	@server
	@return () -> () -- Disconnect function. Call it to remove this source.

	Registers a pose source that walks `Players:GetPlayers()` every
	`PostSimulation` and pushes each player's `.Character` into the snapshot.
	Skips dead, parentless, or rig-incompatible characters.

	The first auto-capture registration on a world starts a shared
	`PostSimulation` hook; the last disconnect stops it. Server-only — asserts
	on the client.

	```lua
	local stop = world.rollback:autoCapturePlayers()
	-- later:
	stop()
	```
]=]
function RollbackProxy.autoCapturePlayers(self: RollbackProxySelf): () -> ()
	local rigs = self._rigs
	return addSource(self, function(poses)
		for _, player in Players:GetPlayers() do
			local character = player.Character
			if not character then
				continue
			end
			local pose = buildPose(character, rigs)
			if pose then
				poses[character] = pose
			end
		end
	end)
end

--[=[
	@within Rollback
	@method autoCaptureCharacters
	@server
	@param folder Instance -- Container whose immediate Model children should be captured.
	@return () -> () -- Disconnect function. Call it to remove this source.

	Registers a pose source that walks `folder:GetChildren()` every
	`PostSimulation`. Use this when both players and NPCs live under one
	container — typically `workspace.Characters` — so a single registration
	covers everyone. Skips non-Model children, dead Humanoids, and
	rig-incompatible characters.

	Server-only.
]=]
function RollbackProxy.autoCaptureCharacters(self: RollbackProxySelf, folder: Instance): () -> ()
	local rigs = self._rigs
	return addSource(self, function(poses)
		for _, child in folder:GetChildren() do
			if not child:IsA("Model") then
				continue
			end
			local pose = buildPose(child, rigs)
			if pose then
				poses[child] = pose
			end
		end
	end)
end

--[=[
	@within Rollback
	@method autoCaptureCharacter
	@server
	@param character Model -- The Model to capture each tick.
	@return () -> () -- Disconnect function. Call it to remove this source.

	Registers a pose source for one specific Model. Useful for boss enemies,
	scripted NPCs, or any character that lives outside the main characters
	container. Stops contributing automatically once the character is dead or
	reparented to `nil`, but the source itself stays registered until the
	disconnect runs.

	Server-only.
]=]
function RollbackProxy.autoCaptureCharacter(self: RollbackProxySelf, character: Model): () -> ()
	local rigs = self._rigs
	return addSource(self, function(poses)
		local pose = buildPose(character, rigs)
		if pose then
			poses[character] = pose
		end
	end)
end

type WorldSelf = {
	_dispatcher: Dispatcher.Dispatcher,
	_definitions: Definitions.Definitions,
	_mainRollback: Rollback.Rollback,
	rollback: Types.Rollback,
}

local World = {}
World.__index = World

export type World = typeof(setmetatable({} :: WorldSelf, World))

local function resolvePayload(config: Types.WorldConfig, penetration: Types.PenetrationConfig): Simulation.ResolvedConfig
	return {
		serverFrameRate = config.serverFrameRate or DEFAULT_SERVER_FRAME_RATE,
		frameTimeBudget = config.frameTimeBudget or DEFAULT_FRAME_TIME_BUDGET,
		interpolation = config.interpolation or DEFAULT_INTERPOLATION,
		defaultRaycastFilter = config.defaultRaycastFilter or RaycastParams.new(),
		visualsContainer = config.visualsContainer,
		excludeContainers = config.excludeContainers or {},
		penetration = penetration,
	}
end

--[=[
	@within Hindsight
	@function createWorld
	@param config WorldConfig
	@return World

	Builds a new [`World`](World). Spins up `config.threads` simulation actors
	(default 16) under `config.actorContainer`, requires the definitions module
	in every actor VM, builds the main-thread snapshot store, and returns the
	handle.

	`actorContainer` and `definitionsModule` are required; every other field
	falls back to the values on [`Hindsight.Defaults`](Defaults).

	```lua
	local world = Hindsight.createWorld({
	    actorContainer    = ServerScriptService,
	    definitionsModule = ReplicatedStorage.Shared.Definitions,
	    visualsContainer  = workspace.Bullets,
	})
	```
]=]
function World.new(config: Types.WorldConfig): World
	assert(config.actorContainer, "Hindsight.createWorld: `actorContainer` is required")
	assert(config.definitionsModule, "Hindsight.createWorld: `definitionsModule` is required")

	local rollbackConfig = config.rollback or Defaults.rollback
	local penetrationConfig = config.penetration or Defaults.penetration

	local definitions = Definitions.new(config.definitionsModule)
	local payload = resolvePayload(config, penetrationConfig)
	local mainRollback = Rollback.new(rollbackConfig)

	local dispatcher = Dispatcher.new({
		container = config.actorContainer,
		threads = config.threads or DEFAULT_THREADS,
		simulationModule = script.Parent.Simulation,
		definitionsModule = config.definitionsModule,
		definitions = definitions,
		payload = payload,
		rollbackConfig = rollbackConfig,
	})

	local self: WorldSelf = {
		_dispatcher = dispatcher,
		_definitions = definitions,
		_mainRollback = mainRollback,
		rollback = newRollbackProxy(mainRollback, dispatcher, rollbackConfig.rigs),
	}
	return (setmetatable(self, World) :: any) :: World
end

--[=[
	@within World
	@method cast
	@param options CastOptions

	Fires a projectile. Resolves `options.type` against the definitions module,
	then dispatches to the least-loaded simulation actor in the pool.

	On the server, `timestamp` should reflect the moment from the shooter's
	perspective — typically `clientTimestamp - playerPing - interpolation`.
	On the client, `workspace:GetServerTimeNow()` is fine — the client World
	has no rollback path.
]=]
function World.cast(self: World, options: Types.CastOptions)
	self._dispatcher:dispatch(options)
end

--[=[
	@within World
	@method destroy

	Tears down the simulation actor pool. Disconnects every Output binding,
	destroys every Actor, and clears internal references. After `destroy`, the
	World is unusable — build a new one with [`Hindsight.createWorld`](Hindsight#createWorld).
]=]
function World.destroy(self: World)
	self._dispatcher:destroy()
end

return World
