local Controller = {
	Priority = 5,
	Signals = {}
}

local MIN_SLIDE_SPEED = 5

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VectorLib = require(ReplicatedStorage.Shared.Libraries.VectorLib)
local CalculateRawMoveVector = shared.Import "CalculateRawMoveVector"
local ImGizmo = shared.Import "ImGizmo"

local Camera = workspace.CurrentCamera
local LocalPlayer = game.Players.LocalPlayer

local PlayerModule, InputUtil, Iris
function Controller:Init()
	PlayerModule = require(LocalPlayer.PlayerScripts:WaitForChild("PlayerModule"))
	InputUtil = require(ReplicatedStorage.Shared.Libraries.InputUtil)
	Iris = shared.Import("Iris")

	Controller.Force = Vector3.new()
	Controller.Controls = PlayerModule:GetControls()
	Controller._Debug = false
	
	-- crouch input
	InputUtil:BindAction("Slide", function(_, State)
		Controller.WishSlide = State == Enum.UserInputState.Begin
	end, true, Enum.KeyCode.C)
	
	Controller.LastJump = tick()

	Controller.Signals.CharacterAdded(LocalPlayer.Character)

	-- IRIS
	Iris:Connect(function()
        local windowSize = Iris.State(Vector2.new(120, 60))
        local windowPos = Iris.State(Vector2.new(300, 0))
        -- Tool manager window
        Iris.Window({"Movement Manager"}, {size = windowSize, position = windowPos})

        if Iris.Button("Toggle Debug").clicked() then
            Controller._Debug = not Controller._Debug
        end

	    Iris.End()
    end)
end

function Controller.Signals.CharacterAdded( Character:Model )
	if not Character then
		LocalPlayer.CharacterAdded:Wait()
		Character = LocalPlayer.Character
		assert(Character, "No Character")
	end
	Controller.Force = Vector3.new()
	Controller.Character = Character
	Controller.Collider = Character:WaitForChild("Collider")
	Controller.ForceInstance = Character:WaitForChild("Force")
	
	-- set camera
	task.spawn(function()
		Camera.CameraType = Enum.CameraType.Custom
		Camera:GetPropertyChangedSignal("CameraType"):Wait()
		Camera.CameraType = Enum.CameraType.Custom
	end)
	
	-- TODO: refactor this hack
	Camera.CameraSubject = Character.Head
end

function Controller.Signals.Update( DeltaTime )
	Controller.Force = Vector3.new()
	Controller.WishJump = Controller.Controls.activeController.isJumping
	Controller.WishVector = Controller.Controls:GetMoveVector()
	Controller.MoveVector = CalculateRawMoveVector(Controller.WishVector)
	Controller.MoveVector = Controller.MoveVector.Magnitude > 0 and Controller.MoveVector.Unit or Vector3.zero
	Controller.PreviousVelocity = Controller.Collider.AssemblyLinearVelocity * Vector3.new(1,0,1)
	Controller.Jumped = false
	
	--
	Controller:DoJump(DeltaTime)
	Controller:DoGroundCast(55)
	Controller:DoMove()
	Controller:DoSlide()
	Controller:DoSlopeCompensation(55)
	
	--
	Controller.ForceInstance.Force = Controller.Force
	
	Controller.WasWishSlide = Controller.WishSlide
	
	-- debug
	if Controller._Debug then
		local Origin = Controller.Collider.Position + Vector3.yAxis * Controller.Collider.Size.Y/2
		ImGizmo.PushProperty("Color3", Color3.new(0, 0.615686, 1))
		ImGizmo.Arrow:Draw(Origin, Origin+Controller.ForceInstance.Force*0.001, 0.2, 0.5, 10)
	end
end


-- main features

function Controller:DoGroundCast(MaxAngle)
	local Params = RaycastParams.new()
	Params.FilterType = Enum.RaycastFilterType.Exclude
	Params.IgnoreWater = true
	Params.FilterDescendantsInstances = {Controller.Character}

	local Origin = Controller.Collider.Position
	local Direction = -Vector3.yAxis * (Controller.Collider.Size.Y/2 + 0.15)

	
	Controller.GroundCastResult = workspace:Spherecast(Origin, Controller.Collider.Size.X/2, Direction, Params) 
	Controller.WasGrounded = Controller.Grounded
	Controller.Grounded = Controller.GroundCastResult ~= nil
	
	-- only grounded if within angle
	Controller.Slipping	 = false
	if Controller.GroundCastResult then
		local SlopeAngle = math.deg(math.acos(Controller.GroundCastResult.Normal:Dot(Vector3.yAxis)))
		if SlopeAngle > MaxAngle then
			Controller.Slipping = true	
		end
	end
	
	Controller.NormalDotProduct = 1
	
	if Controller.GroundCastResult  then
		Controller.NormalDotProduct = Controller.GroundCastResult.Normal:Dot(Vector3.yAxis)
	end
	
	-- debug
	if Controller._Debug then
		ImGizmo.PushProperty("Color3", Controller.GroundCastResult and Color3.new(0.1, 1, 0.1) or Color3.new(1, 0.1, 0.1))
		ImGizmo.Arrow:Draw(Origin, Controller.GroundCastResult and Controller.GroundCastResult.Position or Origin + Direction, 0.2, 0.5, 10)
		
		if Controller.NormalDotProduct ~= 1 then
			ImGizmo.PushProperty("Color3", Color3.new(1, Controller.NormalDotProduct, 0))
			ImGizmo.Arrow:Draw(Controller.GroundCastResult.Position, Controller.GroundCastResult.Position + Controller.GroundCastResult.Normal*1.5, 0.06, 0.2, 10)
		end
	end
end

function Controller:DoJump(DeltaTime)
	if not Controller.Grounded then return end
	if not Controller.WishJump then return end
	if Controller.Slipping then return end
	if tick()-Controller.LastJump < .3 then return end
	Controller.LastJump = tick()
	Controller.Jumped = true

	local Velocity = Controller.Collider.AssemblyLinearVelocity
	
	Controller:VelocityImpulse(Vector3.new(
		Velocity.X,
		50,
		Velocity.Z
	))
end


function Controller:DoMove(AccelForce, MaxSped)
	if Controller.Sliding then return end
	
	local MaxSpeed, AccelForce, DragCoeff

	if Controller.Grounded then
		MaxSpeed = 20
		AccelForce = 100
		DragCoeff = AccelForce / MaxSpeed
	else
		local Alignment = 1 - Controller.MoveVector:Dot(Controller.PreviousVelocity)
		Alignment = math.clamp(Alignment, 0, 1)

		MaxSpeed = 50
		AccelForce = 0 + Alignment * (300 + Controller.PreviousVelocity.Magnitude*10)
		DragCoeff = 0
	end
	
	-- apply movement force
	local MoveForce = Controller.MoveVector * (AccelForce)

	Controller:Push(MoveForce, DragCoeff)
end

function Controller:Drag(DragCoeff)
	-- compute drag
	local Velocity = Controller.Collider.AssemblyLinearVelocity
	Velocity *= Vector3.new(1, 0, 1) -- isolate horizontal velocity

	local Direction = VectorLib.SafeUnit(Velocity)
	local Speed = Velocity.Magnitude
	local DragForce = -Direction * (Speed * DragCoeff)

	-- project drag along slope too, so it feels natural on inclines
	if Controller.Grounded and Controller.GroundCastResult then
		DragForce = Controller:ProjectForceOntoGround(DragForce, Controller.GroundCastResult.Normal)
	end

	Controller.Force += DragForce
end

-- Cancels out gravity along the slope to prevent sliding
function Controller:DoSlopeCompensation(MaxAngle: number)
	if not Controller.Grounded or not Controller.GroundCastResult then return end

	local Normal = Controller.GroundCastResult.Normal
	local SlopeAngle = math.deg(math.acos(Normal:Dot(Vector3.yAxis)))
	if SlopeAngle > MaxAngle then return end
	if SlopeAngle <= 3 then return end -- no compensation needed

	-- Ensure gravity points downward
	local Gravity = Vector3.new(0, -workspace.Gravity, 0)

	-- Tangent component of gravity along slope
	local GravityAlongSurface = Gravity - Normal * (Gravity:Dot(Normal))

	-- Apply opposite force to cancel sliding
	local CompensationForce = -GravityAlongSurface * Controller.Collider.AssemblyMass
	Controller.Force += CompensationForce

	-- Debug
	if Controller._Debug then
		local Origin = Controller.Collider.Position + Vector3.yAxis * (Controller.Collider.Size.Y / 2)
		local Direction = VectorLib.SafeUnit(CompensationForce)
		ImGizmo.PushProperty("Color3", Color3.new(1, 0, 0))
		ImGizmo.Arrow:Draw(Origin, Origin + Direction * 3, 0.1, 0.3, 10)
	end
end

function Controller:DoSlide()
	local Force = 0
	
	if Controller.WishSlide and not Controller.WasWishSlide and Controller.Sliding then -- cancel slide
		Controller.Sliding = false
		return
	end
	
	-- slide start
	if not Controller.Sliding and Controller.WishSlide and not Controller.WasWishSlide and Controller.PreviousVelocity.Magnitude > MIN_SLIDE_SPEED then
		-- start slide
		Controller.Sliding = true
		
		if Controller.Grounded then
			-- slide boost
			local SlopeBoost = Controller.NormalDotProduct * 1000
			
			Force = 600
		end
	end
	
	if not Controller.Sliding then return end
	
	if Controller.Jumped then
		Force = 1000 -- slide jump cancel boost
		Controller.Sliding = false
		return
	end
	
	-- stop sliding if going too slow
	if Controller.PreviousVelocity.Magnitude < MIN_SLIDE_SPEED then
		Controller.Sliding = false
		return
	end
	
	-- move force
	Force += 20 * math.abs(1 - Controller.MoveVector:Dot(Controller.PreviousVelocity.Unit)) -- dont accelerate into it
	
	local MoveForce = Controller.MoveVector * Force
	Controller:Push(MoveForce, Controller.Grounded and .3 or 0)
end

--

-- move player with drag calculated
function Controller:Push(Force, DragCoeff)
	if Controller.Grounded then
		Force = Controller:ProjectForceOntoGround(Force, Controller.GroundCastResult.Normal)
	end

	Controller.Force += Force

	-- apply drag
	Controller:Drag(DragCoeff)

	-- Debug: visualize the rotated (projected) move direction
	if Controller._Debug then
		local Origin = Controller.Collider.Position + Vector3.yAxis * (Controller.Collider.Size.Y / 2)
		local RotatedDir = VectorLib.SafeUnit(Force)

		ImGizmo.PushProperty("Color3", Color3.new(1, 0.8, 0.2)) -- gold/yellow for visibility
		ImGizmo.Arrow:Draw(Origin, Origin + RotatedDir * 3, 0.1, 0.3, 10)

		ImGizmo.PushProperty("Color3", Color3.new(0.305882, 1, 0.254902))
		ImGizmo.Arrow:Draw(Origin, Origin + Controller.Force * Vector3.new(.1, 0, .1), 0.1, 0.3, 10)
	end
end

function Controller:VelocityImpulse(Velocity:Vector3)
	local DeltaVelocity = Velocity - Controller.Collider.AssemblyLinearVelocity
	local Impulse = Controller.Collider.AssemblyMass	 * DeltaVelocity

	Controller.Collider:ApplyImpulse(Impulse)
end

function Controller:CalculateForce(InitialVelocity:Vector3, FinalVelocity:Vector3, Mass:number, DeltaTime:number):Vector3
	-- Calculate the change in velocity
	local DeltaVelocity = FinalVelocity - InitialVelocity

	-- Calculate acceleration
	local Acceleration = DeltaVelocity / DeltaTime

	-- Calculate force
	local Force = Mass * Acceleration

	return Force
end

-- Projects a force vector so it follows the slope
function Controller:ProjectForceOntoGround(Force: Vector3, Normal: Vector3): Vector3
	-- If the normal is nil or perfectly vertical, return the original force
	if not Normal or Normal:FuzzyEq(Vector3.yAxis) then
		return Force
	end

	-- Remove the component of Force that goes into the surface
	-- Equivalent to projecting onto the tangent plane
	local Projected = Force - Normal * (Force:Dot(Normal))
	return Projected
end


return Controller