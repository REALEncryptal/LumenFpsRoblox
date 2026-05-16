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
local SOURCE_GRAVITY = 55 -- bumped from Source's 37.5 for a snappier fall

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

-- Project a vector onto the slope's tangent plane so movement follows the surface.
local function ClipVelocityToSlope(v: Vector3, normal: Vector3): Vector3
	if normal.Y > 0.999 then
		return Vector3.new(v.X, 0, v.Z)
	end
	return v - normal * v:Dot(normal)
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

-- Source's CategorizePosition: AABB hull straight down. Flat bottom → no edge artifacts.
function Controller:DoGroundCast()
	local Params = RaycastParams.new()
	Params.FilterType = Enum.RaycastFilterType.Exclude
	Params.IgnoreWater = true
	Params.FilterDescendantsInstances = {Controller.Character}

	local colliderSize = Controller.Collider.Size
	local castSize = Vector3.new(colliderSize.X * 0.99, 0.05, colliderSize.Z * 0.99)
	-- Start the cast box ABOVE the collider's bottom face. If it starts exactly on
	-- the floor (which happens when resting after a landing), Blockcast returns nil
	-- because it begins in contact with geometry.
	local CAST_LIFT = 0.15
	local castOrigin = CFrame.new(Controller.Collider.Position - Vector3.new(0, colliderSize.Y / 2 - CAST_LIFT - 0.025, 0))
	local castDirection = Vector3.new(0, -(CAST_LIFT + GROUND_SNAP_DISTANCE), 0)

	Controller.GroundCastResult = workspace:Blockcast(castOrigin, castSize, castDirection, Params)
	Controller.WasGrounded = Controller.Grounded
	Controller.Grounded = false
	Controller.NormalDotProduct = 1

	if Controller.GroundCastResult then
		local dot = Controller.GroundCastResult.Normal:Dot(Vector3.yAxis)
		Controller.NormalDotProduct = dot
		-- Source: surfaces steeper than ~45.57° aren't ground — you slide off them.
		if dot >= MIN_GROUND_NORMAL_Y then
			Controller.Grounded = true
		end
	end

	if Controller._Debug then
		local castStart = castOrigin.Position
		local castEnd = castStart + castDirection
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
		velocity = ApplyFriction(velocity, dt)
		velocity = Accelerate(velocity, wishdir, MAX_GROUND_SPEED, SV_ACCELERATE, dt)
		if Controller.GroundCastResult then
			velocity = ClipVelocityToSlope(velocity, Controller.GroundCastResult.Normal)
		end
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

-- Source's StepMove: if a riser is in the way and the path is clear at step height
-- with ground waiting on the other side, lift the collider so the solver carries it over.
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
	local moveDelta = horizontal.Unit * math.max(horizontal.Magnitude * dt, 0.3)

	local forwardHit = workspace:Blockcast(origin, size, moveDelta, Params)
	if not forwardHit then return velocity end
	if math.abs(forwardHit.Normal.Y) > 0.2 then return velocity end

	local liftedOrigin = origin + Vector3.new(0, STEP_HEIGHT, 0)
	local liftedHit = workspace:Blockcast(liftedOrigin, size, moveDelta, Params)
	if liftedHit then return velocity end

	local landCFrame = liftedOrigin + moveDelta
	local landHit = workspace:Blockcast(landCFrame, size, Vector3.new(0, -(STEP_HEIGHT + 0.1), 0), Params)
	if not landHit then return velocity end
	if landHit.Normal:Dot(Vector3.yAxis) < 0.7 then return velocity end

	local liftAmount = STEP_HEIGHT - landHit.Distance + 0.05
	if liftAmount > 0 and liftAmount <= STEP_HEIGHT then
		Controller.Collider.CFrame = origin + Vector3.new(0, liftAmount, 0)
	end

	return velocity
end

return Controller
