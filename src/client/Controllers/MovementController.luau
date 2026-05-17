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
local JUMP_SPEED = 22
local SOURCE_GRAVITY = 85

-- Collide and Slide tuning
local SKIN_WIDTH = 0.05 -- Buffer kept between collider and surfaces
local MAX_BOUNCES = 4

-- Debug prediction visualization. Total time shown is PREDICTION_DURATION
-- regardless of framerate, divided into PREDICTION_STEPS equal slices.
local PREDICTION_DURATION = 1.0 -- seconds
local PREDICTION_STEPS = 5

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
	-- Individual visual toggles. All gated by Controller._Debug being true.
	Controller._ShowHitbox = true
	Controller._ShowWishDir = true
	Controller._ShowVelocity = true
	Controller._ShowGroundCast = true
	Controller._ShowCollideSlide = true
	Controller._ShowDrift = true
	Controller._LogFrame = false

	-- Per-frame intermediate velocity snapshots for the slope-drift diagnostic.
	-- Captured at each stage of Update so the Iris panel can show what each
	-- step did. Magenta arrow in the world view visualizes the perpendicular
	-- (drift) component of the final horizontal velocity relative to wishdir.
	Controller.Diag = {
		VelIn = Vector3.zero,         -- read from collider at start of Update
		VelAfterAccel = Vector3.zero, -- after friction + Accelerate (horizontal only)
		VelAfterSlope = Vector3.zero, -- after ClipVelocityToSlope rotates onto slope plane
		VelAfterClip = Vector3.zero,  -- after CollideAndSlide
		HorizSpeed = 0,
		DriftSpeed = 0,               -- |component of horiz velocity perpendicular to wishdir|
		DriftSign = 0,                -- +1 right of wishdir, -1 left of wishdir, 0 if no input
	}

	Controller.Signals.CharacterAdded(LocalPlayer.Character)

	Iris:Connect(function()
		local windowSize = Iris.State(Vector2.new(260, 460))
		local windowPos = Iris.State(Vector2.new(300, 0))
		local debugState = Iris.State(false)
		local hitboxState = Iris.State(true)
		local wishDirState = Iris.State(true)
		local velocityState = Iris.State(true)
		local groundCastState = Iris.State(true)
		local collideSlideState = Iris.State(true)
		local driftState = Iris.State(true)
		local logFrameState = Iris.State(false)

		Iris.Window({"Movement Manager"}, {size = windowSize, position = windowPos})

		Iris.Checkbox({"Debug Enabled"}, {isChecked = debugState})
		Iris.Checkbox({"Hitbox"}, {isChecked = hitboxState})
		Iris.Checkbox({"Wish Dir"}, {isChecked = wishDirState})
		Iris.Checkbox({"Velocity"}, {isChecked = velocityState})
		Iris.Checkbox({"Ground Cast"}, {isChecked = groundCastState})
		Iris.Checkbox({"Collide & Slide"}, {isChecked = collideSlideState})
		Iris.Checkbox({"Drift Arrow"}, {isChecked = driftState})

		Iris.SeparatorText({"Slope Diagnostics"})
		Iris.Checkbox({"Log Frame to Output"}, {isChecked = logFrameState})

		local d = Controller.Diag
		local normal = Controller.GroundCastResult and Controller.GroundCastResult.Normal or Vector3.yAxis
		local angle = math.deg(math.acos(math.clamp(Controller.NormalDotProduct or 1, -1, 1)))
		local groundedText = Controller.Grounded and "yes" or "no"
		local wd = Controller.MoveVector or Vector3.zero
		local driftDir = d.DriftSign > 0 and "->R" or (d.DriftSign < 0 and "<-L" or "--")

		Iris.Text({string.format("Grounded: %s | Slope: %.1f deg", groundedText, angle)})
		Iris.Text({string.format("Normal:   (%.2f, %.2f, %.2f)", normal.X, normal.Y, normal.Z)})
		Iris.Text({string.format("WishDir:  (%.2f, %.2f)", wd.X, wd.Z)})
		Iris.Text({string.format("HorizSpd: %.2f  Drift: %.2f %s", d.HorizSpeed, d.DriftSpeed, driftDir)})
		Iris.Text({string.format("VelIn:    (%.2f, %.2f, %.2f)", d.VelIn.X, d.VelIn.Y, d.VelIn.Z)})
		Iris.Text({string.format("AfterAcc: (%.2f, %.2f, %.2f)", d.VelAfterAccel.X, d.VelAfterAccel.Y, d.VelAfterAccel.Z)})
		Iris.Text({string.format("AfterSlp: (%.2f, %.2f, %.2f)", d.VelAfterSlope.X, d.VelAfterSlope.Y, d.VelAfterSlope.Z)})
		Iris.Text({string.format("AfterClp: (%.2f, %.2f, %.2f)", d.VelAfterClip.X, d.VelAfterClip.Y, d.VelAfterClip.Z)})

		Controller._Debug = debugState.value
		Controller._ShowHitbox = hitboxState.value
		Controller._ShowWishDir = wishDirState.value
		Controller._ShowVelocity = velocityState.value
		Controller._ShowGroundCast = groundCastState.value
		Controller._ShowCollideSlide = collideSlideState.value
		Controller._ShowDrift = driftState.value
		Controller._LogFrame = logFrameState.value

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
	Controller.VelocityInstance.Enabled = false

	-- Resize hull to Source-style proportions.
	local oldSize = Controller.Collider.Size
	Controller.Collider.Size = HULL_SIZE
	Controller.Collider.Position += Vector3.new(0, (HULL_SIZE.Y - oldSize.Y) / 2, 0)

	-- Zero friction/elasticity so contact doesn't drag velocity.
	local existing = Controller.Collider.CustomPhysicalProperties
	Controller.Collider.CustomPhysicalProperties = PhysicalProperties.new(
		existing and existing.Density or 1,
		0,
		0,
		100,
		100
	)

	-- Cancel solver gravity. We apply Source's exact gravity ourselves.
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

-- Source: Accelerate (ground).
local function Accelerate(v: Vector3, wishdir: Vector3, wishspeed: number, accel: number, dt: number): Vector3
	if wishdir.Magnitude < 0.001 then return v end
	local currentspeed = v:Dot(wishdir)
	local addspeed = wishspeed - currentspeed
	if addspeed <= 0 then return v end
	local accelspeed = math.min(accel * dt * wishspeed, addspeed)
	return v + wishdir * accelspeed
end

-- Source: AirAccelerate. wishspd clamped to AIR_SPEED_CAP for the addspeed cap,
-- but accelspeed uses unclamped wishspeed — that asymmetry enables air-strafing.
local function AirAccelerate(v: Vector3, wishdir: Vector3, wishspeed: number, accel: number, dt: number): Vector3
	if wishdir.Magnitude < 0.001 then return v end
	local wishspd = math.min(wishspeed, AIR_SPEED_CAP)
	local currentspeed = v:Dot(wishdir)
	local addspeed = wishspd - currentspeed
	if addspeed <= 0 then return v end
	local accelspeed = math.min(accel * dt * wishspeed, addspeed)
	return v + wishdir * accelspeed
end

-- Project a vector onto the plane defined by `normal`.
local function ProjectOnPlane(v: Vector3, normal: Vector3): Vector3
	return v - normal * v:Dot(normal)
end

-- Snap velocity onto the slope plane while preserving horizontal velocity
-- exactly. Y is solved from the slope plane equation (normal · vel = 0) given
-- the input X and Z, so input direction maps 1:1 to motion direction regardless
-- of slope angle. Friction therefore drives the perpendicular-to-wishdir
-- component to zero, and steady-state horizontal velocity converges to
-- `wishdir * MAX_GROUND_SPEED`.
--
-- Tradeoff: 3D speed grows by 1/cos(angle) on slopes (the Y component is "free"
-- on top of horizontal MAX_GROUND_SPEED). Two earlier attempts kept 3D speed
-- capped instead, but both shifted the horizontal direction on diagonal input
-- and produced persistent sideways drift: the original `projected.Unit * mag`
-- form amplified drift exponentially (~10%/frame at 30°); the along/perp
-- decomposition stopped the amplification but left a stable wrong direction
-- because Z kept getting absorbed into Y so Accelerate's currentspeed never
-- reached MAX_GROUND_SPEED, pinning the perpendicular component at a non-zero
-- equilibrium.
local function ClipVelocityToSlope(v: Vector3, normal: Vector3): Vector3
	if normal.Y > 0.999 then
		return Vector3.new(v.X, 0, v.Z)
	end
	local y = -(normal.X * v.X + normal.Z * v.Z) / normal.Y
	return Vector3.new(v.X, y, v.Z)
end

-- Recursive Collide and Slide. Takes a displacement vector and returns the
-- collision-clipped displacement (how far we actually move this frame). Each
-- recursion uses a shape sweep to find the next surface contact, snaps up to
-- just before it (minus SKIN_WIDTH), projects the leftover motion onto that
-- surface, and recurses.
--
-- `debugSteps` (optional) collects per-bounce metadata for visualization.
local function CollideAndSlide(displacement: Vector3, origin: CFrame, size: Vector3, params: RaycastParams, depth: number, debugSteps): Vector3
	if depth >= MAX_BOUNCES then return Vector3.zero end

	local distance = displacement.Magnitude
	if distance < 0.0001 then return Vector3.zero end

	local direction = displacement.Unit
	local castDistance = distance + SKIN_WIDTH
	local hit = workspace:Blockcast(origin, size, direction * castDistance, params)

	local step
	if debugSteps then
		step = {
			depth = depth,
			startCFrame = origin,
			endCFrame = origin + displacement, -- where the hull lands if no hit
			hit = hit,
		}
		table.insert(debugSteps, step)
	end

	if not hit then
		return displacement
	end

	local snapDistance = math.max(hit.Distance - SKIN_WIDTH, 0)
	local snap = direction * snapDistance
	local leftover = displacement - snap
	leftover = ProjectOnPlane(leftover, hit.Normal)

	if step then
		step.snapCFrame = origin + snap
		step.leftover = leftover
	end

	return snap + CollideAndSlide(leftover, origin + snap, size, params, depth + 1, debugSteps)
end

function Controller.Signals.Update(DeltaTime: number)
	if not Controller.Collider then return end

	Controller.WishJump = Controller.Controls.activeController.isJumping
	Controller.WishVector = Controller.Controls:GetMoveVector()
	Controller.MoveVector = CalculateRawMoveVector(Controller.WishVector)
	Controller.MoveVector = Controller.MoveVector.Magnitude > 0 and Controller.MoveVector.Unit or Vector3.zero

	Controller:DoGroundCast()

	local velocity = Controller.Collider.AssemblyLinearVelocity
	Controller.Diag.VelIn = velocity
	velocity = Controller:DoJump(velocity)
	velocity = Controller:DoMove(velocity, DeltaTime)
	velocity = Controller:DoStairStep(velocity, DeltaTime)
	velocity = Controller:DoGravity(velocity, DeltaTime)
	velocity = Controller:ClipMotion(velocity, DeltaTime)
	Controller.Diag.VelAfterClip = velocity

	Controller.Collider.AssemblyLinearVelocity = velocity
	Controller.ForceInstance.Force = Vector3.new(0, workspace.Gravity * Controller.Collider.AssemblyMass, 0)

	-- Compute drift = horizontal velocity component perpendicular to wishdir.
	-- Sign uses (yAxis x wishdir), so positive = right of input, negative = left.
	-- This is the number that should stay near zero on a slope when input is
	-- aligned with motion — if it grows, we're surfing.
	do
		local d = Controller.Diag
		local hv = Vector3.new(velocity.X, 0, velocity.Z)
		d.HorizSpeed = hv.Magnitude
		local wd = Controller.MoveVector
		if wd.Magnitude > 0.001 and hv.Magnitude > 0.001 then
			local forwardSpeed = hv:Dot(wd)
			local perp = hv - wd * forwardSpeed
			d.DriftSpeed = perp.Magnitude
			-- wd × yAxis points to wd's right (Roblox: +X is right when facing -Z).
			local rightAxis = wd:Cross(Vector3.yAxis)
			d.DriftSign = perp:Dot(rightAxis) >= 0 and 1 or -1
		else
			d.DriftSpeed = 0
			d.DriftSign = 0
		end

		if Controller._LogFrame then
			local normal = Controller.GroundCastResult and Controller.GroundCastResult.Normal or Vector3.yAxis
			local slopeAngle = math.deg(math.acos(math.clamp(Controller.NormalDotProduct or 1, -1, 1)))
			print(string.format(
				"[Move] grnd=%s slope=%.1f norm=(%.2f,%.2f,%.2f) wish=(%.2f,%.2f) hSpd=%.2f drift=%.2f(%s) | in=(%.2f,%.2f,%.2f) acc=(%.2f,%.2f,%.2f) slp=(%.2f,%.2f,%.2f) clp=(%.2f,%.2f,%.2f)",
				Controller.Grounded and "Y" or "N", slopeAngle,
				normal.X, normal.Y, normal.Z,
				wd.X, wd.Z,
				d.HorizSpeed, d.DriftSpeed, d.DriftSign > 0 and "R" or "L",
				d.VelIn.X, d.VelIn.Y, d.VelIn.Z,
				d.VelAfterAccel.X, d.VelAfterAccel.Y, d.VelAfterAccel.Z,
				d.VelAfterSlope.X, d.VelAfterSlope.Y, d.VelAfterSlope.Z,
				d.VelAfterClip.X, d.VelAfterClip.Y, d.VelAfterClip.Z
			))
		end
	end

	if Controller._Debug then
		local origin = Controller.Collider.Position + Vector3.yAxis * (Controller.Collider.Size.Y / 2)

		if Controller._ShowHitbox then
			ImGizmo.PushProperty("Color3", Color3.new(1, 1, 0))
			ImGizmo.Box:Draw(Controller.Collider.CFrame, Controller.Collider.Size, false)
		end

		if Controller._ShowWishDir and Controller.MoveVector.Magnitude > 0.001 then
			ImGizmo.PushProperty("Color3", Color3.new(0, 1, 1))
			ImGizmo.Arrow:Draw(origin, origin + Controller.MoveVector * 3, 0.12, 0.3, 10)
		end

		if Controller._ShowVelocity then
			local hv = Vector3.new(velocity.X, 0, velocity.Z)
			if hv.Magnitude > 0.1 then
				ImGizmo.PushProperty("Color3", Color3.new(0.2, 1, 0.2))
				ImGizmo.Arrow:Draw(origin, origin + hv * 0.1, 0.1, 0.3, 10)
			end

			if math.abs(velocity.Y) > 0.5 then
				local color = velocity.Y > 0 and Color3.new(1, 1, 0.2) or Color3.new(1, 0.5, 0)
				ImGizmo.PushProperty("Color3", color)
				ImGizmo.Arrow:Draw(origin, origin + Vector3.new(0, velocity.Y * 0.1, 0), 0.1, 0.3, 10)
			end
		end

		if Controller._ShowDrift and Controller.MoveVector.Magnitude > 0.001 then
			local hv = Vector3.new(velocity.X, 0, velocity.Z)
			local wd = Controller.MoveVector
			local perp = hv - wd * hv:Dot(wd)
			if perp.Magnitude > 0.05 then
				-- Magenta: how much horizontal velocity is sideways relative to
				-- input. On a clean slope walk this should be tiny — a long arm
				-- here is the "surfing" the user is feeling.
				ImGizmo.PushProperty("Color3", Color3.new(1, 0.2, 1))
				ImGizmo.Arrow:Draw(origin, origin + perp * 0.2, 0.1, 0.3, 10)
			end
		end
	end
end

-- CategorizePosition + StayOnGround. Short trace → on-ground-right-now;
-- long trace (up to stepsize) → snap down to ground while walking off ledges.
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

	if Controller.WasGrounded then
		local longHit = workspace:Blockcast(castOrigin, castSize, Vector3.new(0, -(CAST_LIFT + STEP_HEIGHT), 0), Params)
		if longHit then
			local dot = longHit.Normal:Dot(Vector3.yAxis)
			if dot >= MIN_GROUND_NORMAL_Y then
				local surfaceY = castOrigin.Position.Y - 0.025 - longHit.Distance
				local newCenterY = surfaceY + colliderSize.Y / 2 + 0.01
				Controller.Collider.CFrame = Controller.Collider.CFrame + Vector3.new(0, newCenterY - Controller.Collider.Position.Y, 0)

				local v = Controller.Collider.AssemblyLinearVelocity
				Controller.Collider.AssemblyLinearVelocity = Vector3.new(v.X, 0, v.Z)

				Controller.Grounded = true
				Controller.GroundCastResult = longHit
				Controller.NormalDotProduct = dot
				return
			end
		end
	end

	if Controller._Debug and Controller._ShowGroundCast then
		local castStart = castOrigin.Position
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

			-- Slope down-hill direction (gravity projected onto slope plane).
			-- Light blue arrow shows where you'd slide if airborne on this surface.
			local normal = Controller.GroundCastResult.Normal
			local downhill = ProjectOnPlane(Vector3.new(0, -1, 0), normal)
			if downhill.Magnitude > 0.001 then
				local dh = downhill.Unit
				ImGizmo.PushProperty("Color3", Color3.new(0.4, 0.7, 1))
				ImGizmo.Arrow:Draw(normalOrigin, normalOrigin + dh * 1.5, 0.06, 0.2, 10)
			end

			-- Slope angle in degrees. White text above the contact point. The
			-- walkable threshold is at acos(MIN_GROUND_NORMAL_Y) ≈ 45.57°.
			local angle = math.deg(math.acos(math.clamp(clampedDot, -1, 1)))
			ImGizmo.PushProperty("Color3", Color3.new(1, 1, 1))
			ImGizmo.Text:Draw(normalOrigin + Vector3.new(0, 0.4, 0), string.format("%.1f°", angle), 14)
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
		-- Friction + accelerate on the horizontal component (Source order), then
		-- rotate the velocity onto the slope plane (preserving horizontal magnitude
		-- so walking up doesn't lose cos(angle) of speed). This is the projection
		-- the old MovementController used in `ProjectForceOntoGround`, ported to
		-- velocity-based movement with the magnitude-preservation fix.
		velocity = Vector3.new(velocity.X, 0, velocity.Z)
		velocity = ApplyFriction(velocity, dt)
		velocity = Accelerate(velocity, wishdir, MAX_GROUND_SPEED, SV_ACCELERATE, dt)
		velocity = Vector3.new(velocity.X, 0, velocity.Z)
		Controller.Diag.VelAfterAccel = velocity
		if Controller.GroundCastResult then
			velocity = ClipVelocityToSlope(velocity, Controller.GroundCastResult.Normal)
		end
		Controller.Diag.VelAfterSlope = velocity
	else
		velocity = AirAccelerate(velocity, wishdir, MAX_GROUND_SPEED, SV_AIRACCELERATE, dt)
		Controller.Diag.VelAfterAccel = velocity
		Controller.Diag.VelAfterSlope = velocity
	end

	return velocity
end

function Controller:DoGravity(velocity, dt)
	if Controller.Grounded then return velocity end
	return velocity - Vector3.new(0, SOURCE_GRAVITY * dt, 0)
end

-- Take a desired velocity, run Collide and Slide on its frame displacement, and
-- return the clipped velocity. The solver then integrates this — but since we've
-- already clipped against expected contacts, the solver has nothing to fight.
--
-- In debug mode, runs 5 frames forward (applying gravity for airborne segments)
-- so the visualization shows future bounces fading out into the distance.
function Controller:ClipMotion(velocity: Vector3, dt: number): Vector3
	local Params = RaycastParams.new()
	Params.FilterType = Enum.RaycastFilterType.Exclude
	Params.IgnoreWater = true
	Params.FilterDescendantsInstances = {Controller.Character}

	local size = Controller.Collider.Size

	-- Always compute the actual frame's clipped motion using real dt.
	local actualClipped = CollideAndSlide(velocity * dt, Controller.Collider.CFrame, size, Params, 0, nil)

	if Controller._Debug and Controller._ShowCollideSlide then
		-- Predict PREDICTION_DURATION seconds into the future in equal slices.
		-- Slice time is fixed (not real dt) so the visualization covers the same
		-- amount of simulated time at any framerate.
		local stepDt = PREDICTION_DURATION / PREDICTION_STEPS
		local simOrigin = Controller.Collider.CFrame
		local simVelocity = velocity

		for s = 1, PREDICTION_STEPS do
			local steps = {}
			local clipped = CollideAndSlide(simVelocity * stepDt, simOrigin, size, Params, 0, steps)

			-- Brightness fades with distance into the future.
			local progress = (s - 1) / PREDICTION_STEPS
			local alpha = math.max(0.18, 1 - progress * 0.82)
			Controller:_DrawCollideAndSlideSteps(steps, alpha)

			simOrigin = simOrigin + clipped
			simVelocity = clipped / stepDt - Vector3.new(0, SOURCE_GRAVITY * stepDt, 0)

			if clipped.Magnitude < 0.01 then break end
		end
	end

	return actualClipped / dt
end

-- Visualize each bounce of one Collide and Slide pass.
-- Cast box (cyan): hull at the start of a bounce.
-- Snap-to box (orange): hull at where the bounce stopped after a hit.
-- Free-end box (green): hull at where a non-hit bounce moved to.
-- Hit normal (red): arrow at the contact point along the surface normal.
-- Slide arrow (magenta): the leftover motion projected onto the surface.
function Controller:_DrawCollideAndSlideSteps(steps, alpha: number)
	local size = Controller.Collider.Size
	for _, step in steps do
		ImGizmo.PushProperty("Color3", Color3.new(0.3 * alpha, 0.7 * alpha, alpha))
		ImGizmo.Box:Draw(step.startCFrame, size, false)

		if step.hit then
			ImGizmo.PushProperty("Color3", Color3.new(alpha, 0.5 * alpha, 0))
			ImGizmo.Box:Draw(step.snapCFrame, size, false)

			ImGizmo.PushProperty("Color3", Color3.new(alpha, 0.1 * alpha, 0.1 * alpha))
			ImGizmo.Arrow:Draw(
				step.hit.Position,
				step.hit.Position + step.hit.Normal * 1.5,
				0.08, 0.2, 10
			)

			if step.leftover and step.leftover.Magnitude > 0.001 then
				local from = step.snapCFrame.Position
				ImGizmo.PushProperty("Color3", Color3.new(alpha, 0.2 * alpha, alpha))
				ImGizmo.Arrow:Draw(from, from + step.leftover.Unit * 1.5, 0.08, 0.2, 10)
			end
		else
			ImGizmo.PushProperty("Color3", Color3.new(0.2 * alpha, alpha, 0.2 * alpha))
			ImGizmo.Box:Draw(step.endCFrame, size, false)
		end
	end
end

-- Source's StepMove. Try forward, try lift→forward→drop, take the path that
-- went further horizontally.
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
	local moveLen = moveDelta.Magnitude

	local forwardHit = workspace:Blockcast(origin, size, moveDelta, Params)
	if not forwardHit then return velocity end
	-- Don't try to step on walkable slopes — DoMove projects velocity onto the
	-- slope and walks us up smoothly. Stepping only helps for risers/walls.
	if forwardHit.Normal:Dot(Vector3.yAxis) >= MIN_GROUND_NORMAL_Y then return velocity end
	local forwardDistance = forwardHit.Distance

	local clearanceHit = workspace:Blockcast(origin, size, Vector3.new(0, STEP_HEIGHT, 0), Params)
	if clearanceHit then return velocity end

	local liftedOrigin = origin + Vector3.new(0, STEP_HEIGHT, 0)
	local liftedHit = workspace:Blockcast(liftedOrigin, size, moveDelta, Params)
	local liftedDistance = liftedHit and liftedHit.Distance or moveLen

	if liftedDistance <= forwardDistance + 0.01 then return velocity end

	local liftedEnd = liftedOrigin + moveDelta.Unit * liftedDistance
	local landHit = workspace:Blockcast(liftedEnd, size, Vector3.new(0, -(STEP_HEIGHT + 0.1), 0), Params)
	if not landHit then return velocity end
	if landHit.Normal:Dot(Vector3.yAxis) < MIN_GROUND_NORMAL_Y then return velocity end

	local liftAmount = STEP_HEIGHT - landHit.Distance + 0.05
	if liftAmount > 0 and liftAmount <= STEP_HEIGHT then
		Controller.Collider.CFrame = origin + Vector3.new(0, liftAmount, 0)
	end

	return velocity
end

return Controller
