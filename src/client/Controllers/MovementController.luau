local Controller = {
	Priority = 5,
	Signals = {}
}

-- Exact Source / HL2 / HL:DM values from gamemovement.cpp.
-- Conversion: 1 stud = 16 Hammer units.
local HULL_SIZE = Vector3.new(2, 4.5, 2) -- 32 × 32 × 72 hu
local STEP_HEIGHT = 1.125 -- sv_stepsize = 18 hu
local GROUND_SNAP_DISTANCE = 0.125 -- CategorizePosition trace = 2 hu
local EYE_OFFSET_FROM_TOP = 0.5 -- VEC_VIEW = 64 hu (8 hu below top)
local MIN_GROUND_NORMAL_Y = 0.7 -- Source's walkable threshold (≈45.57°)

local SV_ACCELERATE = 10
local SV_AIRACCELERATE = 10
local SV_FRICTION = 4
local SV_STOPSPEED = 6.25 -- 100 hu/s
local AIR_SPEED_CAP = 1.875 -- 30 hu/s

local MAX_GROUND_SPEED = 20 -- sv_maxspeed = 320 hu/s
local JUMP_SPEED = 22 -- bumped from Source's 16.77 for a higher jump
local SOURCE_GRAVITY = 85 -- bumped from Source's 37.5 for a snappier fall

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CalculateRawMoveVector = shared.Import "CalculateRawMoveVector"
local ImGizmo = shared.Import "ImGizmo"

local Camera = workspace.CurrentCamera
local LocalPlayer = game.Players.LocalPlayer

local CAMERA_OFFSET_BIND = "MovementController_CameraOffset"

local PlayerModule, Iris
function Controller:Init()
	PlayerModule = require(LocalPlayer.PlayerScripts:WaitForChild("PlayerModule"))
	Iris = shared.Import("Iris")

	Controller.Controls = PlayerModule:GetControls()
	Controller._Debug = false

	Controller.Signals.CharacterAdded(LocalPlayer.Character)

	Iris:Connect(function()
		local windowSize = Iris.State(Vector2.new(120, 60))
		local windowPos = Iris.State(Vector2.new(300, 0))
		Iris.Window({"Movement Manager"}, {size = windowSize, position = windowPos})

		if Iris.Button("Toggle Debug").clicked() then
			Controller._Debug = not Controller._Debug
		end

		Iris.End()
	end)
end

function Controller.Signals.CharacterAdded(Character: Model)
	if not Character then
		LocalPlayer.CharacterAdded:Wait()
		Character = LocalPlayer.Character
		assert(Character, "No Character")
	end
	Controller.Character = Character
	Controller.Collider = Character:WaitForChild("Collider")
	Controller.ForceInstance = Character:WaitForChild("Force")
	Controller.VelocityInstance = Character:WaitForChild("Velocity")

	-- Resize hull to Source-style proportions. Shift up by half the height delta so
	-- feet don't sink into the floor on resize.
	local oldSize = Controller.Collider.Size
	Controller.Collider.Size = HULL_SIZE
	Controller.Collider.Position += Vector3.new(0, (HULL_SIZE.Y - oldSize.Y) / 2, 0)

	-- Zero friction/elasticity so the solver doesn't fight our velocity writes on contact.
	local existing = Controller.Collider.CustomPhysicalProperties
	Controller.Collider.CustomPhysicalProperties = PhysicalProperties.new(
		existing and existing.Density or 1,
		0,
		0,
		100,
		100
	)

	-- We manage Y ourselves via the LinearVelocity; cancel solver gravity.
	Controller.ForceInstance.Force = Vector3.new(0, workspace.Gravity * Controller.Collider.AssemblyMass, 0)

	pcall(function()
		Controller.Collider:SetNetworkOwner(LocalPlayer)
	end)

	task.spawn(function()
		Camera.CameraType = Enum.CameraType.Custom
		Camera:GetPropertyChangedSignal("CameraType"):Wait()
		Camera.CameraType = Enum.CameraType.Custom
	end)

	Camera.CameraSubject = Controller.Collider

	-- Run AFTER Roblox's built-in camera update and shift the camera up by our eye
	-- offset. No-Humanoid equivalent of Humanoid.CameraOffset.
	pcall(function() RunService:UnbindFromRenderStep(CAMERA_OFFSET_BIND) end)
	RunService:BindToRenderStep(CAMERA_OFFSET_BIND, Enum.RenderPriority.Camera.Value + 1, function()
		if not Controller.Collider or not Controller.Collider.Parent then return end
		local size = Controller.Collider.Size
		Camera.CFrame = Camera.CFrame + Vector3.new(0, size.Y / 2 - EYE_OFFSET_FROM_TOP, 0)
	end)
end

-- Source: ApplyFriction. Acts only on the horizontal component.
local function ApplyFriction(v: Vector3, dt: number): Vector3
	local horizontal = Vector3.new(v.X, 0, v.Z)
	local speed = horizontal.Magnitude
	if speed < 0.1 then
		return Vector3.new(0, v.Y, 0)
	end
	local control = math.max(speed, SV_STOPSPEED)
	local drop = control * SV_FRICTION * dt
	local newspeed = math.max(speed - drop, 0)
	local scale = newspeed / speed
	return Vector3.new(v.X * scale, v.Y, v.Z * scale)
end

-- Source: Accelerate (ground). Straight from gamemovement.cpp.
local function Accelerate(v: Vector3, wishdir: Vector3, wishspeed: number, accel: number, dt: number): Vector3
	if wishdir.Magnitude < 0.001 then return v end
	local currentspeed = v:Dot(wishdir)
	local addspeed = wishspeed - currentspeed
	if addspeed <= 0 then return v end
	local accelspeed = math.min(accel * dt * wishspeed, addspeed)
	return v + wishdir * accelspeed
end

-- Source: AirAccelerate. wishspd is clamped to AIR_SPEED_CAP for the addspeed cap,
-- but accelspeed uses the unclamped wishspeed. This is what enables air-strafing —
-- you can redirect velocity freely without adding raw speed.
local function AirAccelerate(v: Vector3, wishdir: Vector3, wishspeed: number, accel: number, dt: number): Vector3
	if wishdir.Magnitude < 0.001 then return v end
	local wishspd = math.min(wishspeed, AIR_SPEED_CAP)
	local currentspeed = v:Dot(wishdir)
	local addspeed = wishspd - currentspeed
	if addspeed <= 0 then return v end
	local accelspeed = math.min(accel * dt * wishspeed, addspeed)
	return v + wishdir * accelspeed
end

-- Source: ClipVelocity. Removes the component of v that goes INTO the plane,
-- so the result slides along the plane's surface. The second-pass adjustment
-- corrects for floating-point drift back into the plane.
local function ClipVelocity(v: Vector3, normal: Vector3, overbounce: number): Vector3
	local backoff = v:Dot(normal) * overbounce
	local out = v - normal * backoff
	local adjust = out:Dot(normal)
	if adjust < 0 then
		out = out - normal * adjust
	end
	return out
end

function Controller.Signals.Update(DeltaTime: number)
	if not Controller.Collider then return end

	Controller.WishJump = Controller.Controls.activeController.isJumping
	Controller.WishVector = Controller.Controls:GetMoveVector()
	Controller.MoveVector = CalculateRawMoveVector(Controller.WishVector)
	Controller.MoveVector = Controller.MoveVector.Magnitude > 0 and Controller.MoveVector.Unit or Vector3.zero

	Controller:DoGroundCast()

	local velocity = Controller.Collider.AssemblyLinearVelocity
	velocity = Controller:DoJump(velocity)
	velocity = Controller:DoMove(velocity, DeltaTime)
	velocity = Controller:DoStairStep(velocity, DeltaTime)
	velocity = Controller:DoGravity(velocity, DeltaTime)
	velocity = Controller:TryPlayerMove(velocity, DeltaTime)

	-- Write both: AssemblyLinearVelocity for immediate state, VectorVelocity for
	-- the constraint to maintain through any solver sub-steps.
	Controller.Collider.AssemblyLinearVelocity = velocity
	Controller.VelocityInstance.VectorVelocity = velocity
	Controller.ForceInstance.Force = Vector3.new(0, workspace.Gravity * Controller.Collider.AssemblyMass, 0)

	if Controller._Debug then
		local velOrigin = Controller.Collider.Position + Vector3.yAxis * (Controller.Collider.Size.Y / 2)
		ImGizmo.PushProperty("Color3", Color3.new(0, 0.615686, 1))
		ImGizmo.Arrow:Draw(velOrigin, velOrigin + velocity * 0.1, 0.1, 0.3, 10)

		ImGizmo.PushProperty("Color3", Color3.new(1, 1, 0))
		ImGizmo.Box:Draw(Controller.Collider.CFrame, Controller.Collider.Size, false)
	end
end

-- Source's CategorizePosition + StayOnGround. The short trace decides "am I on
-- the ground right now?", the long trace handles "was I on ground last frame and
-- am still within stepsize of walkable ground?" (i.e. walking down stairs). If the
-- long trace succeeds we snap the collider down to the surface, like StayOnGround.
function Controller:DoGroundCast()
	local Params = RaycastParams.new()
	Params.FilterType = Enum.RaycastFilterType.Exclude
	Params.IgnoreWater = true
	Params.FilterDescendantsInstances = {Controller.Character}

	local colliderSize = Controller.Collider.Size
	local castSize = Vector3.new(colliderSize.X * 0.99, 0.05, colliderSize.Z * 0.99)
	local CAST_LIFT = 0.15
	local castOrigin = CFrame.new(Controller.Collider.Position - Vector3.new(0, colliderSize.Y / 2 - CAST_LIFT - 0.025, 0))

	Controller.WasGrounded = Controller.Grounded
	Controller.Grounded = false
	Controller.GroundCastResult = nil
	Controller.NormalDotProduct = 1

	-- Short trace: classic CategorizePosition (2hu in Source).
	local shortHit = workspace:Blockcast(castOrigin, castSize, Vector3.new(0, -(CAST_LIFT + GROUND_SNAP_DISTANCE), 0), Params)
	if shortHit then
		local dot = shortHit.Normal:Dot(Vector3.yAxis)
		if dot >= MIN_GROUND_NORMAL_Y then
			Controller.Grounded = true
			Controller.GroundCastResult = shortHit
			Controller.NormalDotProduct = dot
			return
		end
	end

	-- StayOnGround: if we were grounded last frame, look down up to stepsize for
	-- walkable ground. If found, snap to it. This is what keeps you "stuck" to
	-- stairs when walking down them.
	if Controller.WasGrounded then
		local longHit = workspace:Blockcast(castOrigin, castSize, Vector3.new(0, -(CAST_LIFT + STEP_HEIGHT), 0), Params)
		if longHit then
			local dot = longHit.Normal:Dot(Vector3.yAxis)
			if dot >= MIN_GROUND_NORMAL_Y then
				-- Compute target Y so the collider bottom sits just above the surface.
				local surfaceY = castOrigin.Position.Y - 0.025 - longHit.Distance
				local newCenterY = surfaceY + colliderSize.Y / 2 + 0.01
				Controller.Collider.CFrame = Controller.Collider.CFrame + Vector3.new(0, newCenterY - Controller.Collider.Position.Y, 0)

				-- Kill any accumulated vertical velocity so we don't keep falling on the next tick.
				local v = Controller.Collider.AssemblyLinearVelocity
				Controller.Collider.AssemblyLinearVelocity = Vector3.new(v.X, 0, v.Z)

				Controller.Grounded = true
				Controller.GroundCastResult = longHit
				Controller.NormalDotProduct = dot
				return
			end
		end
	end

	if Controller._Debug then
		local castStart = castOrigin.Position
		-- Visualize the long trace (StayOnGround range) so you can see where ground
		-- snap will/won't reach.
		local castEnd = castStart + Vector3.new(0, -(CAST_LIFT + STEP_HEIGHT), 0)
		ImGizmo.PushProperty("Color3", Controller.Grounded and Color3.new(0.1, 1, 0.1) or Color3.new(1, 0.1, 0.1))
		ImGizmo.Arrow:Draw(castStart, castEnd, 0.08, 0.2, 10)

		ImGizmo.PushProperty("Color3", Controller.Grounded and Color3.new(0.1, 1, 0.1) or Color3.new(1, 0.1, 0.1))
		ImGizmo.Box:Draw(CFrame.new(castEnd), castSize, false)

		if Controller.GroundCastResult then
			local normalOrigin = Controller.Collider.Position - Vector3.yAxis * (colliderSize.Y / 2)
			local clampedDot = math.clamp(Controller.NormalDotProduct, 0, 1)
			ImGizmo.PushProperty("Color3", Color3.new(1, clampedDot, 0))
			ImGizmo.Arrow:Draw(
				normalOrigin,
				normalOrigin + Controller.GroundCastResult.Normal * 1.5,
				0.06, 0.2, 10
			)
		end
	end
end

function Controller:DoJump(velocity)
	Controller.Jump = false
	if not Controller.Grounded then return velocity end
	if not Controller.WishJump then return velocity end

	Controller.Jump = true
	Controller.Grounded = false

	return Vector3.new(velocity.X, JUMP_SPEED, velocity.Z)
end

function Controller:DoMove(velocity, dt)
	local wishdir = Controller.MoveVector

	if Controller.Grounded then
		-- Source's WalkMove zeros Y before and after Accelerate. Slope handling
		-- happens later in TryPlayerMove via ClipVelocity, which produces the
		-- Y-component needed to walk up/down a ramp.
		velocity = Vector3.new(velocity.X, 0, velocity.Z)
		velocity = ApplyFriction(velocity, dt)
		velocity = Accelerate(velocity, wishdir, MAX_GROUND_SPEED, SV_ACCELERATE, dt)
		velocity = Vector3.new(velocity.X, 0, velocity.Z)
	else
		velocity = AirAccelerate(velocity, wishdir, MAX_GROUND_SPEED, SV_AIRACCELERATE, dt)
	end

	return velocity
end

-- We cancel solver gravity and apply Source's exact value ourselves.
function Controller:DoGravity(velocity, dt)
	if Controller.Grounded then return velocity end
	return velocity - Vector3.new(0, SOURCE_GRAVITY * dt, 0)
end

-- Source's TryPlayerMove: up to 4 collision-and-clip bumps per frame. Casts the
-- player hull along the intended velocity, clips velocity against whatever it
-- hits, and tries again with the remaining time. This is what makes wall-sliding,
-- slope-walking, and surfing all "just work" — the surface clipping math is
-- identical for floors, walls, steep slopes, and creases between them.
function Controller:TryPlayerMove(velocity: Vector3, dt: number): Vector3
	local Params = RaycastParams.new()
	Params.FilterType = Enum.RaycastFilterType.Exclude
	Params.IgnoreWater = true
	Params.FilterDescendantsInstances = {Controller.Character}

	local size = Controller.Collider.Size
	local origin = Controller.Collider.CFrame
	local primalVelocity = velocity
	local originalVelocity = velocity
	local timeLeft = dt
	local planes: {Vector3} = {}

	for _ = 1, 4 do
		if velocity.Magnitude < 0.001 then break end

		local moveDelta = velocity * timeLeft
		local hit = workspace:Blockcast(origin, size, moveDelta, Params)

		if not hit then break end -- full distance traveled freely

		local moveLen = moveDelta.Magnitude
		local fraction = hit.Distance / moveLen

		-- Advance the predicted origin to where the cast actually stopped.
		if hit.Distance > 0 then
			origin = origin + moveDelta.Unit * hit.Distance
			originalVelocity = velocity
			table.clear(planes)
		end

		timeLeft = timeLeft * (1 - fraction)

		if #planes >= 5 then
			velocity = Vector3.zero
			break
		end

		table.insert(planes, hit.Normal)

		-- Find a single plane whose clip doesn't push velocity into any other
		-- contact plane. This is Source's multi-plane resolution loop.
		local found = false
		for i, p in ipairs(planes) do
			local candidate = ClipVelocity(originalVelocity, p, 1)
			local valid = true
			for j, q in ipairs(planes) do
				if i ~= j and candidate:Dot(q) < 0 then
					valid = false
					break
				end
			end
			if valid then
				velocity = candidate
				found = true
				break
			end
		end

		if not found then
			-- Two planes pinching us: slide along their intersection (crease).
			if #planes == 2 then
				local dir = planes[1]:Cross(planes[2])
				if dir.Magnitude > 0.0001 then
					dir = dir.Unit
					velocity = dir * dir:Dot(velocity)
				else
					velocity = Vector3.zero
					break
				end
			else
				velocity = Vector3.zero
				break
			end
		end

		-- If we've been clipped to where we'd move backwards relative to the
		-- original intent, stop dead (prevents tiny oscillations in corners).
		if velocity:Dot(primalVelocity) <= 0 then
			velocity = Vector3.zero
			break
		end
	end

	return velocity
end

-- Source's StepMove. The original algorithm tries forward, then tries
-- lift→forward→drop, and takes the path that traveled further horizontally. We're
-- a hybrid (solver does horizontal integration), so we only need the Y lift —
-- but we still run the comparison to know *whether* lifting helps. No surface-
-- normal heuristic: any block ahead is a candidate for stepping.
function Controller:DoStairStep(velocity, dt)
	if not Controller.Grounded then return velocity end

	local horizontal = Vector3.new(velocity.X, 0, velocity.Z)
	if horizontal.Magnitude < 0.5 then return velocity end

	local Params = RaycastParams.new()
	Params.FilterType = Enum.RaycastFilterType.Exclude
	Params.IgnoreWater = true
	Params.FilterDescendantsInstances = {Controller.Character}

	local size = Controller.Collider.Size
	local origin = Controller.Collider.CFrame
	-- Cast a bit farther than one tick so we catch the wall before the solver does.
	local moveDelta = horizontal.Unit * math.max(horizontal.Magnitude * dt, 0.3)
	local moveLen = moveDelta.Magnitude

	-- 1. Forward at current Y. If unblocked, no step needed.
	local forwardHit = workspace:Blockcast(origin, size, moveDelta, Params)
	if not forwardHit then return velocity end
	local forwardDistance = forwardHit.Distance

	-- 2. Clearance above the player up to stepsize.
	local clearanceHit = workspace:Blockcast(origin, size, Vector3.new(0, STEP_HEIGHT, 0), Params)
	if clearanceHit then return velocity end

	-- 3. Forward at lifted Y.
	local liftedOrigin = origin + Vector3.new(0, STEP_HEIGHT, 0)
	local liftedHit = workspace:Blockcast(liftedOrigin, size, moveDelta, Params)
	local liftedDistance = liftedHit and liftedHit.Distance or moveLen

	-- StepMove compares horizontal progress. Only lift if the up-path went further.
	if liftedDistance <= forwardDistance + 0.01 then return velocity end

	-- 4. Drop down to find the surface we'd be landing on.
	local liftedEnd = liftedOrigin + moveDelta.Unit * liftedDistance
	local landHit = workspace:Blockcast(liftedEnd, size, Vector3.new(0, -(STEP_HEIGHT + 0.1), 0), Params)
	if not landHit then return velocity end
	if landHit.Normal:Dot(Vector3.yAxis) < MIN_GROUND_NORMAL_Y then return velocity end

	-- 5. Lift Y. Solver carries XZ forward this frame; next frame's StayOnGround
	-- snaps the collider firmly down onto the step's top surface.
	local liftAmount = STEP_HEIGHT - landHit.Distance + 0.05
	if liftAmount > 0 and liftAmount <= STEP_HEIGHT then
		Controller.Collider.CFrame = origin + Vector3.new(0, liftAmount, 0)
	end

	return velocity
end

return Controller
