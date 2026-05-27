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
local MIN_GROUND_NORMAL_Y = 0.8 -- Source's walkable threshold (≈45.57°)

local SV_ACCELERATE = 10
local SV_AIRACCELERATE = 10
local SV_FRICTION = 6
local SV_STOPSPEED = 10
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
		VelIn = Vector3.zero,         -- intrinsic velocity at start of Update (BaseVelocity already subtracted)
		VelAfterAccel = Vector3.zero, -- after friction + Accelerate (horizontal only)
		VelAfterSlope = Vector3.zero, -- after ClipVelocityToSlope rotates onto slope plane
		VelAfterClip = Vector3.zero,  -- after CollideAndSlide; equals AssemblyLinearVelocity write
		BaseVel = Vector3.zero,       -- this frame's platform velocity contribution
		HorizSpeed = 0,
		DriftSpeed = 0,               -- |component of horiz velocity perpendicular to wishdir|
		DriftSign = 0,                -- +1 right of wishdir, -1 left of wishdir, 0 if no input
	}

	-- Source-style moving platform support. The platform's velocity is folded
	-- into displacement integration only — friction/accel/gravity operate on
	-- intrinsic velocity (AssemblyLinearVelocity minus BaseVelocity) so the
	-- player's input math is unaffected by the ride. Anchored platforms have
	-- their position cached so we can derive velocity from the per-frame delta;
	-- unanchored parts use AssemblyLinearVelocity directly.
	Controller.BaseVelocity = Vector3.zero
	Controller._PlatformPositions = setmetatable({}, {__mode = "k"}) :: any

	Controller.Signals.CharacterAdded(LocalPlayer.Character)

	Iris:Connect(function()
		local WindowSize = Iris.State(Vector2.new(260, 460))
		local WindowPos = Iris.State(Vector2.new(300, 0))
		local DebugState = Iris.State(false)
		local HitboxState = Iris.State(true)
		local WishDirState = Iris.State(true)
		local VelocityState = Iris.State(true)
		local GroundCastState = Iris.State(true)
		local CollideSlideState = Iris.State(true)
		local DriftState = Iris.State(true)
		local LogFrameState = Iris.State(false)

		Iris.Window({"Movement Manager"}, {size = WindowSize, position = WindowPos})

		Iris.Checkbox({"Debug Enabled"}, {isChecked = DebugState})
		Iris.Checkbox({"Hitbox"}, {isChecked = HitboxState})
		Iris.Checkbox({"Wish Dir"}, {isChecked = WishDirState})
		Iris.Checkbox({"Velocity"}, {isChecked = VelocityState})
		Iris.Checkbox({"Ground Cast"}, {isChecked = GroundCastState})
		Iris.Checkbox({"Collide & Slide"}, {isChecked = CollideSlideState})
		Iris.Checkbox({"Drift Arrow"}, {isChecked = DriftState})

		Iris.SeparatorText({"Slope Diagnostics"})
		Iris.Checkbox({"Log Frame to Output"}, {isChecked = LogFrameState})

		local D = Controller.Diag
		local Normal = Controller.GroundCastResult and Controller.GroundCastResult.Normal or Vector3.yAxis
		local Angle = math.deg(math.acos(math.clamp(Controller.NormalDotProduct or 1, -1, 1)))
		local GroundedText = Controller.Grounded and "yes" or "no"
		local Wd = Controller.MoveVector or Vector3.zero
		local DriftDir = D.DriftSign > 0 and "->R" or (D.DriftSign < 0 and "<-L" or "--")

		Iris.Text({string.format("Grounded: %s | Slope: %.1f deg", GroundedText, Angle)})
		Iris.Text({string.format("Normal:   (%.2f, %.2f, %.2f)", Normal.X, Normal.Y, Normal.Z)})
		Iris.Text({string.format("WishDir:  (%.2f, %.2f)", Wd.X, Wd.Z)})
		Iris.Text({string.format("HorizSpd: %.2f  Drift: %.2f %s", D.HorizSpeed, D.DriftSpeed, DriftDir)})
		Iris.Text({string.format("VelIn:    (%.2f, %.2f, %.2f)", D.VelIn.X, D.VelIn.Y, D.VelIn.Z)})
		Iris.Text({string.format("AfterAcc: (%.2f, %.2f, %.2f)", D.VelAfterAccel.X, D.VelAfterAccel.Y, D.VelAfterAccel.Z)})
		Iris.Text({string.format("AfterSlp: (%.2f, %.2f, %.2f)", D.VelAfterSlope.X, D.VelAfterSlope.Y, D.VelAfterSlope.Z)})
		Iris.Text({string.format("AfterClp: (%.2f, %.2f, %.2f)", D.VelAfterClip.X, D.VelAfterClip.Y, D.VelAfterClip.Z)})
		Iris.Text({string.format("BaseVel:  (%.2f, %.2f, %.2f)", D.BaseVel.X, D.BaseVel.Y, D.BaseVel.Z)})

		Controller._Debug = DebugState.value
		Controller._ShowHitbox = HitboxState.value
		Controller._ShowWishDir = WishDirState.value
		Controller._ShowVelocity = VelocityState.value
		Controller._ShowGroundCast = GroundCastState.value
		Controller._ShowCollideSlide = CollideSlideState.value
		Controller._ShowDrift = DriftState.value
		Controller._LogFrame = LogFrameState.value

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
	local OldSize = Controller.Collider.Size
	Controller.Collider.Size = HULL_SIZE
	Controller.Collider.Position += Vector3.new(0, (HULL_SIZE.Y - OldSize.Y) / 2, 0)

	-- Zero friction/elasticity so contact doesn't drag velocity.
	local Existing = Controller.Collider.CustomPhysicalProperties
	Controller.Collider.CustomPhysicalProperties = PhysicalProperties.new(
		Existing and Existing.Density or 1,
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
		local Size = Controller.Collider.Size
		Camera.CFrame = Camera.CFrame + Vector3.new(0, Size.Y / 2 - EYE_OFFSET_FROM_TOP, 0)
	end)
end

-- Source: ApplyFriction. Acts only on the horizontal component.
local function ApplyFriction(V: Vector3, Dt: number): Vector3
	local Horizontal = Vector3.new(V.X, 0, V.Z)
	local Speed = Horizontal.Magnitude
	if Speed < 0.1 then
		return Vector3.new(0, V.Y, 0)
	end
	local Control = math.max(Speed, SV_STOPSPEED)
	local Drop = Control * SV_FRICTION * Dt
	local NewSpeed = math.max(Speed - Drop, 0)
	local Scale = NewSpeed / Speed
	return Vector3.new(V.X * Scale, V.Y, V.Z * Scale)
end

-- Source: Accelerate (ground).
local function Accelerate(V: Vector3, Wishdir: Vector3, Wishspeed: number, Accel: number, Dt: number): Vector3
	if Wishdir.Magnitude < 0.001 then return V end
	local CurrentSpeed = V:Dot(Wishdir)
	local AddSpeed = Wishspeed - CurrentSpeed
	if AddSpeed <= 0 then return V end
	local AccelSpeed = math.min(Accel * Dt * Wishspeed, AddSpeed)
	return V + Wishdir * AccelSpeed
end

-- Source: AirAccelerate. Wishspd clamped to AIR_SPEED_CAP for the AddSpeed cap,
-- but AccelSpeed uses unclamped Wishspeed — that asymmetry enables air-strafing.
local function AirAccelerate(V: Vector3, Wishdir: Vector3, Wishspeed: number, Accel: number, Dt: number): Vector3
	if Wishdir.Magnitude < 0.001 then return V end
	local Wishspd = math.min(Wishspeed, AIR_SPEED_CAP)
	local CurrentSpeed = V:Dot(Wishdir)
	local AddSpeed = Wishspd - CurrentSpeed
	if AddSpeed <= 0 then return V end
	local AccelSpeed = math.min(Accel * Dt * Wishspeed, AddSpeed)
	return V + Wishdir * AccelSpeed
end

-- Project a vector onto the plane defined by `Normal`.
local function ProjectOnPlane(V: Vector3, Normal: Vector3): Vector3
	return V - Normal * V:Dot(Normal)
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
local function ClipVelocityToSlope(V: Vector3, Normal: Vector3): Vector3
	if Normal.Y > 0.999 then
		return Vector3.new(V.X, 0, V.Z)
	end
	local Y = -(Normal.X * V.X + Normal.Z * V.Z) / Normal.Y
	return Vector3.new(V.X, Y, V.Z)
end

-- Recursive Collide and Slide. Takes a displacement vector and returns the
-- collision-clipped displacement (how far we actually move this frame). Each
-- recursion uses a shape sweep to find the next surface contact, snaps up to
-- just before it (minus SKIN_WIDTH), projects the leftover motion onto that
-- surface, and recurses.
--
-- `DebugSteps` (optional) collects per-bounce metadata for visualization.
local function CollideAndSlide(Displacement: Vector3, Origin: CFrame, Size: Vector3, Params: RaycastParams, Depth: number, DebugSteps): Vector3
	if Depth >= MAX_BOUNCES then return Vector3.zero end

	local Distance = Displacement.Magnitude
	if Distance < 0.0001 then return Vector3.zero end

	local Direction = Displacement.Unit
	local CastDistance = Distance + SKIN_WIDTH
	local Hit = workspace:Blockcast(Origin, Size, Direction * CastDistance, Params)

	local Step
	if DebugSteps then
		Step = {
			Depth = Depth,
			StartCFrame = Origin,
			EndCFrame = Origin + Displacement, -- where the hull lands if no hit
			Hit = Hit,
		}
		table.insert(DebugSteps, Step)
	end

	if not Hit then
		return Displacement
	end

	local SnapDistance = math.max(Hit.Distance - SKIN_WIDTH, 0)
	local Snap = Direction * SnapDistance
	local Leftover = Displacement - Snap
	Leftover = ProjectOnPlane(Leftover, Hit.Normal)

	if Step then
		Step.SnapCFrame = Origin + Snap
		Step.Leftover = Leftover
	end

	return Snap + CollideAndSlide(Leftover, Origin + Snap, Size, Params, Depth + 1, DebugSteps)
end

-- Source's BaseVelocity for moving platforms. For unanchored platforms the
-- physics solver maintains AssemblyLinearVelocity; for anchored (tween-driven)
-- platforms we cache the part's position per Update and derive velocity from
-- the delta. The first contact with an anchored part lags by one frame because
-- the cache is empty — friction absorbs this quickly.
function Controller:GetPlatformVelocity(Part: BasePart?, Dt: number): Vector3
	if not Part or Dt <= 0 then return Vector3.zero end
	if not Part.Anchored then
		return Part.AssemblyLinearVelocity
	end
	local Last = Controller._PlatformPositions[Part]
	Controller._PlatformPositions[Part] = Part.Position
	if not Last then return Vector3.zero end
	return (Part.Position - Last) / Dt
end

function Controller.Signals.Update(DeltaTime: number)
	if not Controller.Collider then return end

	Controller.WishJump = Controller.Controls.activeController.isJumping
	Controller.WishVector = Controller.Controls:GetMoveVector()
	Controller.MoveVector = CalculateRawMoveVector(Controller.WishVector)
	Controller.MoveVector = Controller.MoveVector.Magnitude > 0 and Controller.MoveVector.Unit or Vector3.zero

	Controller:DoGroundCast()

	-- Recover intrinsic velocity by stripping last frame's platform contribution.
	-- Friction/accel/gravity below operate on intrinsic — the platform's motion
	-- is reinserted only for the displacement integration pass.
	local Velocity = Controller.Collider.AssemblyLinearVelocity - Controller.BaseVelocity
	Controller.Diag.VelIn = Velocity
	Velocity = Controller:DoJump(Velocity)
	Velocity = Controller:DoMove(Velocity, DeltaTime)
	Velocity = Controller:DoStairStep(Velocity, DeltaTime)
	Velocity = Controller:DoGravity(Velocity, DeltaTime)

	-- Resolve this frame's platform velocity (zero if airborne or no ground entity).
	local Ground = Controller.Grounded and Controller.GroundCastResult and Controller.GroundCastResult.Instance or nil
	local NewBase = Controller:GetPlatformVelocity(Ground, DeltaTime)

	-- Source's SetGroundEntity transitions: fire only at air↔ground boundaries,
	-- never continuously. While grounded on a platform that changes speed,
	-- intrinsic stays put and friction lets world velocity = base velocity
	-- (the player rides cleanly). Doing this every frame instead bled platform
	-- momentum into intrinsic during decel — that was the "still sliding after
	-- the platform stops" symptom.
	if Controller.Grounded and not Controller.WasGrounded then
		-- Landed: subtract new ground's velocity so we don't double-count it
		-- (the carry already happens via NewBase below).
		Velocity = Velocity - NewBase
	elseif not Controller.Grounded and Controller.WasGrounded then
		-- Left ground (jumped or walked off): bake last frame's platform
		-- velocity into intrinsic so the jump arc keeps that momentum.
		Velocity = Velocity + Controller.BaseVelocity
	end

	-- Collision-clip the combined motion, then split intrinsic back out.
	Velocity = Controller:ClipMotion(Velocity + NewBase, DeltaTime) - NewBase
	Controller.Diag.VelAfterClip = Velocity + NewBase
	Controller.Diag.BaseVel = NewBase

	Controller.Collider.AssemblyLinearVelocity = Velocity + NewBase
	Controller.BaseVelocity = NewBase
	Controller.ForceInstance.Force = Vector3.new(0, workspace.Gravity * Controller.Collider.AssemblyMass, 0)

	-- Compute drift = horizontal velocity component perpendicular to wishdir.
	-- Sign uses (yAxis x wishdir), so positive = right of input, negative = left.
	-- This is the number that should stay near zero on a slope when input is
	-- aligned with motion — if it grows, we're surfing.
	do
		local D = Controller.Diag
		local Hv = Vector3.new(Velocity.X, 0, Velocity.Z)
		D.HorizSpeed = Hv.Magnitude
		local Wd = Controller.MoveVector
		if Wd.Magnitude > 0.001 and Hv.Magnitude > 0.001 then
			local ForwardSpeed = Hv:Dot(Wd)
			local Perp = Hv - Wd * ForwardSpeed
			D.DriftSpeed = Perp.Magnitude
			-- Wd × yAxis points to Wd's right (Roblox: +X is right when facing -Z).
			local RightAxis = Wd:Cross(Vector3.yAxis)
			D.DriftSign = Perp:Dot(RightAxis) >= 0 and 1 or -1
		else
			D.DriftSpeed = 0
			D.DriftSign = 0
		end

		if Controller._LogFrame then
			local Normal = Controller.GroundCastResult and Controller.GroundCastResult.Normal or Vector3.yAxis
			local SlopeAngle = math.deg(math.acos(math.clamp(Controller.NormalDotProduct or 1, -1, 1)))
			print(string.format(
				"[Move] grnd=%s slope=%.1f norm=(%.2f,%.2f,%.2f) wish=(%.2f,%.2f) hSpd=%.2f drift=%.2f(%s) | in=(%.2f,%.2f,%.2f) acc=(%.2f,%.2f,%.2f) slp=(%.2f,%.2f,%.2f) clp=(%.2f,%.2f,%.2f)",
				Controller.Grounded and "Y" or "N", SlopeAngle,
				Normal.X, Normal.Y, Normal.Z,
				Wd.X, Wd.Z,
				D.HorizSpeed, D.DriftSpeed, D.DriftSign > 0 and "R" or "L",
				D.VelIn.X, D.VelIn.Y, D.VelIn.Z,
				D.VelAfterAccel.X, D.VelAfterAccel.Y, D.VelAfterAccel.Z,
				D.VelAfterSlope.X, D.VelAfterSlope.Y, D.VelAfterSlope.Z,
				D.VelAfterClip.X, D.VelAfterClip.Y, D.VelAfterClip.Z
			))
		end
	end

	if Controller._Debug then
		local Origin = Controller.Collider.Position + Vector3.yAxis * (Controller.Collider.Size.Y / 2)

		if Controller._ShowHitbox then
			ImGizmo.PushProperty("Color3", Color3.new(1, 1, 0))
			ImGizmo.Box:Draw(Controller.Collider.CFrame, Controller.Collider.Size, false)
		end

		if Controller._ShowWishDir and Controller.MoveVector.Magnitude > 0.001 then
			ImGizmo.PushProperty("Color3", Color3.new(0, 1, 1))
			ImGizmo.Arrow:Draw(Origin, Origin + Controller.MoveVector * 3, 0.12, 0.3, 10)
		end

		if Controller._ShowVelocity then
			local Hv = Vector3.new(Velocity.X, 0, Velocity.Z)
			if Hv.Magnitude > 0.1 then
				ImGizmo.PushProperty("Color3", Color3.new(0.2, 1, 0.2))
				ImGizmo.Arrow:Draw(Origin, Origin + Hv * 0.1, 0.1, 0.3, 10)
			end

			if math.abs(Velocity.Y) > 0.5 then
				local Color = Velocity.Y > 0 and Color3.new(1, 1, 0.2) or Color3.new(1, 0.5, 0)
				ImGizmo.PushProperty("Color3", Color)
				ImGizmo.Arrow:Draw(Origin, Origin + Vector3.new(0, Velocity.Y * 0.1, 0), 0.1, 0.3, 10)
			end
		end

		if Controller._ShowDrift and Controller.MoveVector.Magnitude > 0.001 then
			local Hv = Vector3.new(Velocity.X, 0, Velocity.Z)
			local Wd = Controller.MoveVector
			local Perp = Hv - Wd * Hv:Dot(Wd)
			if Perp.Magnitude > 0.05 then
				-- Magenta: how much horizontal velocity is sideways relative to
				-- input. On a clean slope walk this should be tiny — a long arm
				-- here is the "surfing" the user is feeling.
				ImGizmo.PushProperty("Color3", Color3.new(1, 0.2, 1))
				ImGizmo.Arrow:Draw(Origin, Origin + Perp * 0.2, 0.1, 0.3, 10)
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

	local ColliderSize = Controller.Collider.Size
	local CastSize = Vector3.new(ColliderSize.X * 0.99, 0.05, ColliderSize.Z * 0.99)
	local CAST_LIFT = 0.15
	local CastOrigin = CFrame.new(Controller.Collider.Position - Vector3.new(0, ColliderSize.Y / 2 - CAST_LIFT - 0.025, 0))

	Controller.WasGrounded = Controller.Grounded
	Controller.Grounded = false
	Controller.GroundCastResult = nil
	Controller.NormalDotProduct = 1

	local ShortHit = workspace:Blockcast(CastOrigin, CastSize, Vector3.new(0, -(CAST_LIFT + GROUND_SNAP_DISTANCE), 0), Params)
	if ShortHit then
		local Dot = ShortHit.Normal:Dot(Vector3.yAxis)
		if Dot >= MIN_GROUND_NORMAL_Y then
			Controller.Grounded = true
			Controller.GroundCastResult = ShortHit
			Controller.NormalDotProduct = Dot
			return
		end
	end

	if Controller.WasGrounded then
		local LongHit = workspace:Blockcast(CastOrigin, CastSize, Vector3.new(0, -(CAST_LIFT + STEP_HEIGHT), 0), Params)
		if LongHit then
			local Dot = LongHit.Normal:Dot(Vector3.yAxis)
			if Dot >= MIN_GROUND_NORMAL_Y then
				local SurfaceY = CastOrigin.Position.Y - 0.025 - LongHit.Distance
				local NewCenterY = SurfaceY + ColliderSize.Y / 2 + 0.01
				Controller.Collider.CFrame = Controller.Collider.CFrame + Vector3.new(0, NewCenterY - Controller.Collider.Position.Y, 0)

				local V = Controller.Collider.AssemblyLinearVelocity
				Controller.Collider.AssemblyLinearVelocity = Vector3.new(V.X, 0, V.Z)

				Controller.Grounded = true
				Controller.GroundCastResult = LongHit
				Controller.NormalDotProduct = Dot
				return
			end
		end
	end

	if Controller._Debug and Controller._ShowGroundCast then
		local CastStart = CastOrigin.Position
		local CastEnd = CastStart + Vector3.new(0, -(CAST_LIFT + STEP_HEIGHT), 0)
		ImGizmo.PushProperty("Color3", Controller.Grounded and Color3.new(0.1, 1, 0.1) or Color3.new(1, 0.1, 0.1))
		ImGizmo.Arrow:Draw(CastStart, CastEnd, 0.08, 0.2, 10)

		ImGizmo.PushProperty("Color3", Controller.Grounded and Color3.new(0.1, 1, 0.1) or Color3.new(1, 0.1, 0.1))
		ImGizmo.Box:Draw(CFrame.new(CastEnd), CastSize, false)

		if Controller.GroundCastResult then
			local NormalOrigin = Controller.Collider.Position - Vector3.yAxis * (ColliderSize.Y / 2)
			local ClampedDot = math.clamp(Controller.NormalDotProduct, 0, 1)
			ImGizmo.PushProperty("Color3", Color3.new(1, ClampedDot, 0))
			ImGizmo.Arrow:Draw(
				NormalOrigin,
				NormalOrigin + Controller.GroundCastResult.Normal * 1.5,
				0.06, 0.2, 10
			)

			-- Slope down-hill direction (gravity projected onto slope plane).
			-- Light blue arrow shows where you'd slide if airborne on this surface.
			local Normal = Controller.GroundCastResult.Normal
			local Downhill = ProjectOnPlane(Vector3.new(0, -1, 0), Normal)
			if Downhill.Magnitude > 0.001 then
				local Dh = Downhill.Unit
				ImGizmo.PushProperty("Color3", Color3.new(0.4, 0.7, 1))
				ImGizmo.Arrow:Draw(NormalOrigin, NormalOrigin + Dh * 1.5, 0.06, 0.2, 10)
			end

			-- Slope angle in degrees. White text above the contact point. The
			-- walkable threshold is at acos(MIN_GROUND_NORMAL_Y) ≈ 45.57°.
			local Angle = math.deg(math.acos(math.clamp(ClampedDot, -1, 1)))
			ImGizmo.PushProperty("Color3", Color3.new(1, 1, 1))
			ImGizmo.Text:Draw(NormalOrigin + Vector3.new(0, 0.4, 0), string.format("%.1f°", Angle), 14)
		end
	end
end

function Controller:DoJump(Velocity)
	Controller.Jump = false
	if not Controller.Grounded then return Velocity end
	if not Controller.WishJump then return Velocity end

	Controller.Jump = true
	Controller.Grounded = false

	return Vector3.new(Velocity.X, JUMP_SPEED, Velocity.Z)
end

function Controller:DoMove(Velocity, Dt)
	local Wishdir = Controller.MoveVector

	if Controller.Grounded then
		-- Friction + accelerate on the horizontal component (Source order), then
		-- rotate the velocity onto the slope plane (preserving horizontal magnitude
		-- so walking up doesn't lose cos(angle) of speed). This is the projection
		-- the old MovementController used in `ProjectForceOntoGround`, ported to
		-- velocity-based movement with the magnitude-preservation fix.
		Velocity = Vector3.new(Velocity.X, 0, Velocity.Z)
		Velocity = ApplyFriction(Velocity, Dt)
		Velocity = Accelerate(Velocity, Wishdir, MAX_GROUND_SPEED, SV_ACCELERATE, Dt)
		Velocity = Vector3.new(Velocity.X, 0, Velocity.Z)
		Controller.Diag.VelAfterAccel = Velocity
		if Controller.GroundCastResult then
			Velocity = ClipVelocityToSlope(Velocity, Controller.GroundCastResult.Normal)
		end
		Controller.Diag.VelAfterSlope = Velocity
	else
		Velocity = AirAccelerate(Velocity, Wishdir, MAX_GROUND_SPEED, SV_AIRACCELERATE, Dt)
		Controller.Diag.VelAfterAccel = Velocity
		Controller.Diag.VelAfterSlope = Velocity
	end

	return Velocity
end

function Controller:DoGravity(Velocity, Dt)
	if Controller.Grounded then return Velocity end
	return Velocity - Vector3.new(0, SOURCE_GRAVITY * Dt, 0)
end

-- Take a desired velocity, run Collide and Slide on its frame displacement, and
-- return the clipped velocity. The solver then integrates this — but since we've
-- already clipped against expected contacts, the solver has nothing to fight.
--
-- In debug mode, runs 5 frames forward (applying gravity for airborne segments)
-- so the visualization shows future bounces fading out into the distance.
function Controller:ClipMotion(Velocity: Vector3, Dt: number): Vector3
	local Params = RaycastParams.new()
	Params.FilterType = Enum.RaycastFilterType.Exclude
	Params.IgnoreWater = true
	Params.FilterDescendantsInstances = {Controller.Character}

	local Size = Controller.Collider.Size

	-- Always compute the actual frame's clipped motion using real Dt.
	local ActualClipped = CollideAndSlide(Velocity * Dt, Controller.Collider.CFrame, Size, Params, 0, nil)

	if Controller._Debug and Controller._ShowCollideSlide then
		-- Predict PREDICTION_DURATION seconds into the future in equal slices.
		-- Slice time is fixed (not real Dt) so the visualization covers the same
		-- amount of simulated time at any framerate.
		local StepDt = PREDICTION_DURATION / PREDICTION_STEPS
		local SimOrigin = Controller.Collider.CFrame
		local SimVelocity = Velocity

		for S = 1, PREDICTION_STEPS do
			local Steps = {}
			local Clipped = CollideAndSlide(SimVelocity * StepDt, SimOrigin, Size, Params, 0, Steps)

			-- Brightness fades with distance into the future.
			local Progress = (S - 1) / PREDICTION_STEPS
			local Alpha = math.max(0.18, 1 - Progress * 0.82)
			Controller:_DrawCollideAndSlideSteps(Steps, Alpha)

			SimOrigin = SimOrigin + Clipped
			SimVelocity = Clipped / StepDt - Vector3.new(0, SOURCE_GRAVITY * StepDt, 0)

			if Clipped.Magnitude < 0.01 then break end
		end
	end

	return ActualClipped / Dt
end

-- Visualize each bounce of one Collide and Slide pass.
-- Cast box (cyan): hull at the start of a bounce.
-- Snap-to box (orange): hull at where the bounce stopped after a hit.
-- Free-end box (green): hull at where a non-hit bounce moved to.
-- Hit normal (red): arrow at the contact point along the surface normal.
-- Slide arrow (magenta): the leftover motion projected onto the surface.
function Controller:_DrawCollideAndSlideSteps(Steps, Alpha: number)
	local Size = Controller.Collider.Size
	for _, Step in Steps do
		ImGizmo.PushProperty("Color3", Color3.new(0.3 * Alpha, 0.7 * Alpha, Alpha))
		ImGizmo.Box:Draw(Step.StartCFrame, Size, false)

		if Step.Hit then
			ImGizmo.PushProperty("Color3", Color3.new(Alpha, 0.5 * Alpha, 0))
			ImGizmo.Box:Draw(Step.SnapCFrame, Size, false)

			ImGizmo.PushProperty("Color3", Color3.new(Alpha, 0.1 * Alpha, 0.1 * Alpha))
			ImGizmo.Arrow:Draw(
				Step.Hit.Position,
				Step.Hit.Position + Step.Hit.Normal * 1.5,
				0.08, 0.2, 10
			)

			if Step.Leftover and Step.Leftover.Magnitude > 0.001 then
				local From = Step.SnapCFrame.Position
				ImGizmo.PushProperty("Color3", Color3.new(Alpha, 0.2 * Alpha, Alpha))
				ImGizmo.Arrow:Draw(From, From + Step.Leftover.Unit * 1.5, 0.08, 0.2, 10)
			end
		else
			ImGizmo.PushProperty("Color3", Color3.new(0.2 * Alpha, Alpha, 0.2 * Alpha))
			ImGizmo.Box:Draw(Step.EndCFrame, Size, false)
		end
	end
end

-- Source's StepMove. Try forward, try lift→forward→drop, take the path that
-- went further horizontally.
function Controller:DoStairStep(Velocity, Dt)
	if not Controller.Grounded then return Velocity end

	local Horizontal = Vector3.new(Velocity.X, 0, Velocity.Z)
	if Horizontal.Magnitude < 0.5 then return Velocity end

	local Params = RaycastParams.new()
	Params.FilterType = Enum.RaycastFilterType.Exclude
	Params.IgnoreWater = true
	Params.FilterDescendantsInstances = {Controller.Character}

	local Size = Controller.Collider.Size
	local Origin = Controller.Collider.CFrame
	local MoveDelta = Horizontal.Unit * math.max(Horizontal.Magnitude * Dt, 0.3)
	local MoveLen = MoveDelta.Magnitude

	local ForwardHit = workspace:Blockcast(Origin, Size, MoveDelta, Params)
	if not ForwardHit then return Velocity end
	-- Don't try to step on walkable slopes — DoMove projects velocity onto the
	-- slope and walks us up smoothly. Stepping only helps for risers/walls.
	if ForwardHit.Normal:Dot(Vector3.yAxis) >= MIN_GROUND_NORMAL_Y then return Velocity end
	local ForwardDistance = ForwardHit.Distance

	local ClearanceHit = workspace:Blockcast(Origin, Size, Vector3.new(0, STEP_HEIGHT, 0), Params)
	if ClearanceHit then return Velocity end

	local LiftedOrigin = Origin + Vector3.new(0, STEP_HEIGHT, 0)
	local LiftedHit = workspace:Blockcast(LiftedOrigin, Size, MoveDelta, Params)
	local LiftedDistance = LiftedHit and LiftedHit.Distance or MoveLen

	if LiftedDistance <= ForwardDistance + 0.01 then return Velocity end

	local LiftedEnd = LiftedOrigin + MoveDelta.Unit * LiftedDistance
	local LandHit = workspace:Blockcast(LiftedEnd, Size, Vector3.new(0, -(STEP_HEIGHT + 0.1), 0), Params)
	if not LandHit then return Velocity end
	if LandHit.Normal:Dot(Vector3.yAxis) < MIN_GROUND_NORMAL_Y then return Velocity end

	local LiftAmount = STEP_HEIGHT - LandHit.Distance + 0.05
	if LiftAmount > 0 and LiftAmount <= STEP_HEIGHT then
		Controller.Collider.CFrame = Origin + Vector3.new(0, LiftAmount, 0)
	end

	return Velocity
end

return Controller
