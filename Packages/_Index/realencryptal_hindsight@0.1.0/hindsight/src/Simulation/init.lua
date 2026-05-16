--!strict
--!native
--!optimize 2

--> Per-actor simulation loop. Each actor runs an isolated copy of this module
--> (independent Lua VM) with its own projectile table, rollback store, and
--> definitions table. Cross-VM communication happens through:
--> - actor:SendMessage / BindToMessage (Initialize, Dispatch, Capture)
--> - the actor's Output BindableEvent (callback fan-out back to the main thread)

local RunService = game:GetService("RunService")

local Types = require(script.Parent.Types)
local Kinematics = require(script.Parent.Physics.Kinematics)
local Rollback = require(script.Parent.Rollback)
local Penetration = require(script.Penetration)
local Projectile = require(script.Projectile)

type CapturedIntersection = {
	part: string,
	player: Player?,
	character: Model,
	position: Vector3,
}

export type ResolvedConfig = {
	serverFrameRate: number,
	frameTimeBudget: number,
	interpolation: number,
	defaultRaycastFilter: RaycastParams,
	visualsContainer: Instance?,
	excludeContainers: { Instance },
	penetration: Types.PenetrationConfig,
}

type ActorState = {
	actor: Actor,
	output: BindableEvent,
	isServer: boolean,
	isClient: boolean,
	rollback: Rollback.Rollback?,
	definitions: { [string]: Types.ProjectileDefinition },
	projectiles: { [number]: Projectile.State },
	nextId: number,
	frameStartTick: number,
	config: ResolvedConfig,
	terrain: Terrain,
}

local Simulation = {}

local function incrementTasks(actor: Actor, amount: number)
	local current = (actor:GetAttribute("Tasks") :: number?) or 0
	actor:SetAttribute("Tasks", current + amount)
end

local function spawnProjectile(state: ActorState, options: Types.CastOptions)
	local definition = state.definitions[options.type]
	if not definition then
		warn(`Hindsight: unknown projectile type "{options.type}"`)
		return
	end

	local resolved = Projectile.resolveDefinition(definition, options.modifier)
	local direction = options.direction
	if direction.Magnitude > 1 + 1e-4 then
		direction = direction.Unit
	end

	local visual: PVInstance? = nil
	if state.isClient and options.visual and state.config.visualsContainer then
		local cloned = options.visual:Clone()
		cloned.Parent = state.config.visualsContainer
		visual = cloned
	end

	local projectile = Projectile.build(
		options.type,
		options.caster,
		options.origin,
		direction,
		options.timestamp,
		visual,
		resolved,
		options.modifier,
		{ defaultRaycastFilter = state.config.defaultRaycastFilter, now = os.clock() }
	)

	incrementTasks(state.actor, 1)
	state.nextId += 1
	state.projectiles[state.nextId] = projectile
end

local function queryPlayers(
	state: ActorState,
	projectile: Projectile.State,
	origin: Vector3,
	segment: Vector3,
	time: number
): CapturedIntersection?
	local rollback = state.rollback
	if not rollback then
		return nil
	end
	local length = segment.Magnitude
	if length < 1e-6 then
		return nil
	end

	local hit = rollback:queryRay(time, origin, segment / length, length, projectile.filter, projectile.caster, projectile.extra)
	if not hit then
		return nil
	end
	return {
		part = hit.part,
		player = hit.player,
		character = hit.character,
		position = hit.position,
	}
end

--> Handle a world raycast hit. Returns:
--> - destroy: whether the projectile should be removed this tick
--> - step: updated step value (penetration advances it past the medium)
--> - position: updated position
--> - emitResult: the RaycastResult to fire onImpact for (nil = swallow)
local function resolveWorldHit(
	state: ActorState,
	projectile: Projectile.State,
	raycastResult: RaycastResult,
	rawDirection: Vector3,
	step: number
): (boolean, number, Vector3, RaycastResult?)
	local impact = raycastResult.Instance
	local normal = raycastResult.Normal
	local unitDirection = rawDirection.Unit
	local surfaceAngle = math.acos(unitDirection:Dot(normal.Unit))
	local hardness = state.config.penetration.surfaceHardness[raycastResult.Material]
		or state.config.penetration.defaultHardness

	local ricocheted = Penetration.tryRicochet(
		projectile,
		raycastResult.Position,
		unitDirection,
		normal,
		surfaceAngle,
		hardness,
		state.config.penetration
	)
	if ricocheted then
		return false, 0, raycastResult.Position, nil
	end

	if impact == state.terrain then
		return true, step, raycastResult.Position, raycastResult
	end

	local compound = Penetration.computeCompound(
		raycastResult.Position,
		unitDirection,
		impact,
		raycastResult.Material,
		state.config.penetration,
		projectile.raycastFilter,
		projectile.includeFilter,
		state.config.excludeContainers,
		state.terrain
	)

	if projectile.power < compound.cost then
		return true, step, raycastResult.Position, raycastResult
	end

	projectile.power -= compound.cost
	local newStep =
		Kinematics.timeAtPosition(projectile.origin, projectile.velocity, projectile.gravity, compound.exitPosition, step)
	local newPosition = Kinematics.positionAtCorrected(projectile.origin, projectile.velocity, projectile.gravity, newStep)
	return false, newStep, newPosition, raycastResult
end

local function stepProjectiles(
	state: ActorState,
	deltaTime: number
): ({ [Projectile.State]: RaycastResult }, { [Projectile.State]: CapturedIntersection }, { Projectile.State })
	local impacted: { [Projectile.State]: RaycastResult } = {}
	local intersected: { [Projectile.State]: CapturedIntersection } = {}
	local destroyed: { Projectile.State } = {}

	local now = os.clock()
	local frameDeadline = (state.config.serverFrameRate - (now - state.frameStartTick)) * state.config.frameTimeBudget

	for id, projectile in state.projectiles do
		if (os.clock() - now) > frameDeadline then
			break
		end

		if projectile.caster.Parent == nil then
			state.projectiles[id] = nil
			table.insert(destroyed, projectile)
			continue
		end

		local time = math.min(projectile.time + deltaTime, projectile.lifetime)
		local step = math.min(projectile.step + deltaTime, time)
		local position = projectile.position
		local destroyFlag = false

		if projectile.speed > 0 then
			position = Kinematics.positionAtCorrected(projectile.origin, projectile.velocity, projectile.gravity, step)
			local origin = projectile.position
			local segment = position - origin
			local raycastResult = workspace:Raycast(origin, segment, projectile.raycastFilter)
			local rayEnd = raycastResult and raycastResult.Position or (origin + segment)

			local capturedHit: CapturedIntersection? = nil
			if state.isServer then
				capturedHit = queryPlayers(state, projectile, origin, rayEnd - origin, projectile.timestamp + time)
				if capturedHit then
					destroyFlag = not projectile.collaterals
					intersected[projectile] = capturedHit
				end
			end

			if raycastResult and not capturedHit then
				local destroyHere, newStep, newPosition, emitResult =
					resolveWorldHit(state, projectile, raycastResult, segment, step)
				destroyFlag = destroyHere
				if newStep ~= step then
					time = math.min(time + (newStep - step), projectile.lifetime)
				end
				step = newStep
				position = newPosition
				if emitResult then
					impacted[projectile] = emitResult
				end
			end
		end

		projectile.tick = now
		projectile.time = time
		projectile.step = step
		projectile.position = position

		if destroyFlag or time == projectile.lifetime then
			state.projectiles[id] = nil
			table.insert(destroyed, projectile)
		end
	end

	return impacted, intersected, destroyed
end

--> Output:Fire uses POSITIONAL args, not a ctx table. Roblox demotes Instance
--> references nested inside a table to strings when the table crosses an
--> actor VM boundary. Positional args survive intact. Definitions.dispatch on
--> the main thread reassembles the ctx for the user's callback.
local function fireImpact(state: ActorState, projectile: Projectile.State, result: RaycastResult)
	state.output:Fire(
		"onImpact",
		projectile.type,
		projectile.caster,
		Kinematics.velocityAt(projectile.velocity, projectile.gravity, projectile.step),
		result.Instance,
		result.Normal,
		result.Position,
		result.Material,
		projectile.extra
	)
end

local function fireIntersection(state: ActorState, projectile: Projectile.State, intersection: CapturedIntersection)
	state.output:Fire(
		"onIntersection",
		projectile.type,
		projectile.caster,
		Kinematics.velocityAt(projectile.velocity, projectile.gravity, projectile.step),
		intersection.part,
		intersection.player,
		intersection.character,
		intersection.position,
		projectile.extra
	)
end

local function fireDestroyed(state: ActorState, projectile: Projectile.State)
	if projectile.caster.Parent ~= nil then
		state.output:Fire(
			"onDestroyed",
			projectile.type,
			projectile.caster,
			projectile.position,
			projectile.extra
		)
	end

	if projectile.instance and state.isClient then
		projectile.instance:Destroy()
	end

	incrementTasks(state.actor, -1)
	table.clear(projectile :: any)
end

local function onPostSimulation(state: ActorState, deltaTime: number)
	local impacted, intersected, destroyed = stepProjectiles(state, deltaTime)

	task.synchronize()

	for projectile, result in impacted do
		fireImpact(state, projectile, result)
	end
	for projectile, intersection in intersected do
		fireIntersection(state, projectile, intersection)
	end
	for _, projectile in destroyed do
		fireDestroyed(state, projectile)
	end
end

local function onPreRender(state: ActorState)
	local now = os.clock()
	local parts: { BasePart } = {}
	local cframes: { CFrame } = {}

	for _, projectile in state.projectiles do
		local visual = projectile.instance
		if not visual then
			continue
		end

		local time = projectile.step + (now - projectile.tick)
		local position = Kinematics.positionAtCorrected(projectile.origin, projectile.velocity, projectile.gravity, time)
		local heading = Kinematics.velocityAt(projectile.velocity, projectile.gravity, time)
		local orientation = CFrame.lookAt(position, position + heading)

		if visual:IsA("BasePart") then
			table.insert(parts, visual)
			table.insert(cframes, orientation)
		else
			visual:PivotTo(orientation)
		end
	end

	task.synchronize()
	workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
end

function Simulation.initialize(
	actor: Actor,
	payload: ResolvedConfig,
	definitions: { [string]: Types.ProjectileDefinition },
	rollbackConfig: Types.RollbackConfig?
)
	local outputBindable = actor:FindFirstChild("Output")
	assert(
		outputBindable and outputBindable:IsA("BindableEvent"),
		"Hindsight actor template is missing its `Output` BindableEvent."
	)

	local state: ActorState = {
		actor = actor,
		output = outputBindable :: BindableEvent,
		isServer = RunService:IsServer(),
		isClient = RunService:IsClient(),
		rollback = if rollbackConfig then Rollback.new(rollbackConfig) else nil,
		definitions = definitions,
		projectiles = {},
		nextId = 0,
		frameStartTick = os.clock(),
		config = payload,
		terrain = workspace.Terrain,
	}

	actor:BindToMessage("Dispatch", function(options: Types.CastOptions)
		spawnProjectile(state, options)
	end)
	if state.rollback then
		--> Cross-VM wire format mirror of `RollbackProxy.capture`: entries
		--> arrive with character as a value, not a key, because Instance keys
		--> get demoted to their `.Name` string when crossing actor boundaries.
		--> Rebuild the {[Model]: pose} map locally before pushing.
		actor:BindToMessage("Capture", function(time: number, entries: { any })
			local poses: Types.CharacterPoses = {}
			for _, entry in entries do
				poses[entry.character] = {
					rig = entry.rig,
					rootPosition = entry.rootPosition,
					parts = entry.parts,
					player = entry.player,
				}
			end
			(state.rollback :: Rollback.Rollback):capture(time, poses)
		end)
		actor:BindToMessage("ClearRollback", function()
			(state.rollback :: Rollback.Rollback):clear()
		end)
	end

	RunService.PreSimulation:Connect(function()
		state.frameStartTick = os.clock()
	end)
	RunService.PostSimulation:ConnectParallel(function(deltaTime: number)
		onPostSimulation(state, deltaTime)
	end)
	if state.isClient then
		RunService.PreRender:ConnectParallel(function()
			onPreRender(state)
		end)
	end
end

return Simulation
