--[[
    
ToolBase
Base for all tools with viewmodels

- Viewmodel
- Animations
- Events
- Springs
- Cycles

Created Sunday, May 4th 2025, 1:06:53 pm
RealEncryptal

--]]


local ToolBase = {}
ToolBase.__index = ToolBase

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Trove = shared.Import("trove")
local Spring = shared.Import("Spring3")
local Constants = shared.Import("Constants")
local CharacterController = shared.Import("CharacterController")
local TweenUtil = shared.Import("TweenUtil")
local InterfaceController = shared.Import("InterfaceController")
local CFrameUtil = shared.Import("CFrameUtil")
local InteractionController = shared.Import("InteractionController")

function ToolBase.new( ToolFolder: Folder )
    assert(ToolFolder, "ToolBase.New - ToolFolder is nil")
    assert(typeof(ToolFolder) == "Instance", "ToolBase.New - ToolFolder is not an Instance")
    assert(ToolFolder:IsA("Folder"), "ToolBase.New - ToolFolder is not a Folder")
    
    local self = setmetatable({}, ToolBase)
    self.Type = "ToolBase"
    self.Data = require(ToolFolder:FindFirstChildOfClass("ModuleScript"))

    -- 
    self.Trove = Trove.new()
    self.UpdateTasks = {}
    self.SortedUpdateTasks = {}

    -- 
    local ToolModel = ToolFolder:FindFirstChildOfClass("Model")

    self.Viewmodel = self.Data.IsRigged and ToolModel or ReplicatedStorage.Assets.Viewmodel
    self.Viewmodel = self.Trove:Clone(self.Viewmodel)
    self.Viewmodel:ScaleTo(Constants.ToolScale)
    self.Viewmodel.Parent = workspace.CurrentCamera

    self.Animator = self.Viewmodel:FindFirstChild("Animator", true)
    assert(self.Animator, "ToolBase.New - Animator not found")

    if not self.Data.IsRigged and ToolModel then
        self.Tool = self.Trove:Clone(ToolModel)
        if not self.Tool then return end
        self.Tool:ScaleTo(Constants.ToolScale)
        self.Tool.Parent = self.Viewmodel

        local Joint = Instance.new "Motor6D"
        Joint.Parent = self.Tool.PrimaryPart
        Joint.Part0 = self.Tool.PrimaryPart
        Joint.Part1 = self.Viewmodel.PrimaryPart
        Joint.Name = "Tool"
    end

    -- crosshair
    if self.Data.Crosshair then
        self.Crosshair = ReplicatedStorage.Assets.Crosshair:Clone()
        self.Crosshair.Parent = workspace.CurrentCamera
    end

    local Fallback = {}

    function Fallback:Play() end
    function Fallback:Stop() end

    self.HideCrosshair = self.Crosshair 
        and TweenUtil.CreateTransparencyTween(self.Crosshair.Crosshair, 1, .2) 
        or Fallback
    self.ShowCrosshair = self.Crosshair 
        and TweenUtil.CreateTransparencyTween(self.Crosshair.Crosshair, nil, .2) 
        or Fallback
    
    -- 
    self.Animations = {}

    self.State = {} -- tool state
    self.CharacterState = {} -- character state

    self.Offsets = {
        Base = CFrameUtil.Scale(self.Data.Offsets.Base or CFrame.new(), Constants.ToolScale),
        Hidden = CFrameUtil.Scale(CFrame.new(0, -10, 0), Constants.ToolScale),
        _Hidden = CFrame.new(),
    }

    self.Springs = {
        Idle = Spring.new(),
        Sway = Spring.new(5, 50, 5, 4), -- mass, force, damping, speed
        Walk = Spring.new(),
        Run = Spring.new(),
        Air = Spring.new(),
        Impact = Spring.new(),
    }

    self.Enabled = true
    self.Equipped = false
    self.Swapping = false
    self.Equipping = false
    self.Unequipping = false
    
    self.ViewmodelCFrame = CFrame.new()
    self.CameraCFrame = workspace.CurrentCamera.CFrame
    self.PreviousCameraCFrame = workspace.CurrentCamera.CFrame

    -- Load animations
    for AnimationName, AnimationId in pairs(self.Data.Animations) do
        self:LoadAnimation(AnimationName, AnimationId)
    end

    self:LoadAnimation("Hover", 95762835448575)

    if self.Animations.Idle then
        self.Animations.Idle:Play()
    end

    -- Update Tasks
    self:AddUpdateTask("UpdateState", 100, function(DeltaTime: number)
        self.CharacterState = {
            MoveDirection = CharacterController.GetMoveDirection(),
            WasGrounded = CharacterController.WasGrounded(),
            Grounded = CharacterController.IsGrounded(),
            MouseDelta = UserInputService:GetMouseDelta(),
            Velocity = CharacterController.GetVelocity(),
        }
    end)

    -- Shove Springs

    CharacterController.OnImpact:Connect(function()
        self.Springs.Impact:Shove(Vector3.new(0, -0.03, 0))
    end)

    self:AddUpdateTask("ShoveSprings", 101, function(DeltaTime: number)
        -- Walk Spring
        if self.CharacterState.MoveDirection.Magnitude > 0.1 and self.CharacterState.Grounded then
            local Magnitude = .05
            local Speed = 15
            local Time = tick() * Speed

            self.Springs.Walk:Shove(Vector3.new(
                math.cos(Time/2) * Magnitude * .7,
                math.sin(Time) * Magnitude,
                0
            )*DeltaTime)
        end

        -- in Air
        if not self.CharacterState.Grounded then
            self.Springs.Air:Shove(Vector3.new(
                0,
                .1,
                0
            )*DeltaTime)
        end

        -- Jump
        if not self.CharacterState.Grounded and self.CharacterState.WasGrounded then
            self.Springs.Air:Shove(Vector3.new(
                0,
                .5,
                0
            )*DeltaTime)
        end

        -- Sway Spring
        local Magnitude = .05

        self.Springs.Sway:Shove(Vector3.new(self.CharacterState.MouseDelta.X * Magnitude, self.CharacterState.MouseDelta.Y * -Magnitude, self.CharacterState.MouseDelta.X * Magnitude*.1)*DeltaTime)
    end)

    -- Update Springs
    self:AddUpdateTask("UpdateSprings", 102, function(DeltaTime: number)
        self.UpdatedSprings = {}
        for SpringName, Spring in pairs(self.Springs) do
            self.UpdatedSprings[SpringName] = Spring:Update(DeltaTime) 
        end
    end)

    -- Update viewmodel cframe
    -- Update viewmodel cframe
    self:AddUpdateTask("UpdateViewmodelCFrame", 103, function(DeltaTime: number)
        self.ViewmodelCFrame = CFrame.new()
        self.ViewmodelCFrame *= workspace.CurrentCamera.CFrame
        self.ViewmodelCFrame *= (workspace:GetAttribute("BaseOffset") or self.Offsets.Base)
        self.ViewmodelCFrame *= self.Offsets.Hidden
        self.ViewmodelCFrame *= self.Offsets._Hidden
        self.ViewmodelCFrame *= CFrame.new(self.UpdatedSprings.Walk * self.Viewmodel:GetScale() * .2)
        self.ViewmodelCFrame *= CFrame.Angles(
            math.rad(self.UpdatedSprings.Walk.Y * 15),
            math.rad(-self.UpdatedSprings.Walk.X * 15),
            0
        )
        self.ViewmodelCFrame *= CFrame.new(-self.UpdatedSprings.Sway * self.Viewmodel:GetScale() * .5) * CFrame.Angles(math.rad(self.UpdatedSprings.Sway.Y *5), math.rad(-self.UpdatedSprings.Sway.X *5), 0)
        self.ViewmodelCFrame *= CFrame.new(self.UpdatedSprings.Air * self.Viewmodel:GetScale())
        self.ViewmodelCFrame *= CFrame.new(self.UpdatedSprings.Impact * self.Viewmodel:GetScale() * .3)
        self.ViewmodelCFrame *= CFrame.Angles(
            math.rad(self.UpdatedSprings.Impact.Y * 25),
            0,
            0
        )
    end)

    -- Set Viewmodel
    self:AddUpdateTask("SetViewmodelCFrame", 104, function(DeltaTime: number)
        self.Viewmodel.PrimaryPart.CFrame = self.ViewmodelCFrame
    end)

    -- Update camera cframe, seperated so children may add  
    self:AddUpdateTask("UpdateCameraCFrame", 102.5, function(DeltaTime: number)
        self.CameraCFrame = self.Viewmodel:FindFirstChild("CameraPart").CFrame:ToObjectSpace(self.Viewmodel.PrimaryPart.CFrame)
        self.CameraCFrame *= CFrame.Angles(
            math.rad(self.UpdatedSprings.Impact.Y * 2),
            0,
            0
        ) 

        self.CameraCFrame *= CFrame.Angles(
            math.rad(self.UpdatedSprings.Walk.Y * -2),
            math.rad(-self.UpdatedSprings.Walk.X * -2),
            0
        )
    end)

    -- Set Camera
    self:AddUpdateTask("Update", 106, function(DeltaTime: number)
        if not self.Enabled then return end
        if not self.Equipped and not self.Swapping then return end
        workspace.Camera.CFrame *= self.PreviousCameraCFrame:Inverse()
        
        if self.Crosshair then
            self.Crosshair.Position = workspace.Camera.CFrame.Position + workspace.Camera.CFrame.LookVector * 5
            self.Crosshair.CFrame = CFrame.lookAt(
                self.Crosshair.Position,
                workspace.Camera.CFrame.Position
            )
        end

        workspace.Camera.CFrame *= self.CameraCFrame
        self.PreviousCameraCFrame = self.CameraCFrame
    end)

    -- Trove cleanup
    self.Trove:Add(function()
        if self.SwapCoroutine then
            task.cancel(self.SwapCoroutine)
        end
    end)

    -- DEBUG
    --self:PrintTasks()
    InteractionController.OnHover:Connect(function(Model)
        if Model then
            self.Animations.Hover:Play()
        else
            self.Animations.Hover:Stop()
        end
    end)
    
    return self
end

-- DEBUG
function ToolBase:CreateDebug(Iris) end

-- MAIN METHODS

function ToolBase:Hide(Hide: boolean)
    self.Offsets._Hidden = Hide and CFrame.new(-100, 0, 0) or CFrame.new()
    self.Enabled = not Hide

    if not self.Crosshair then return end
    
    self.Crosshair.Crosshair.Enabled = not Hide
end

function ToolBase:Activate() end
function ToolBase:AltActivate() end

function ToolBase:Equip() 
    if self.Equipping then return end
    
    if self.SwapCoroutine then
        task.cancel(self.SwapCoroutine)
    end

    self.Equipping = true
    self.Swapping = true
    task.spawn(function()
        self.Animations.Equip:AdjustWeight(0)
        self.Animations.Equip:Play(0)
        
        task.wait(.01)

        self.Offsets.Hidden = CFrame.new()
    end)

    InteractionController.Enabled = false

    self.ShowCrosshair:Play()
    self:StartEquip()
    
    self.SwapCoroutine = task.delay(self.Data.SwapTime or 0, function()
        self.Swapping = false
        self.Equipped = true
        self.Equipping = false
        
        InteractionController.Enabled = true
        
        InterfaceController.WeaponUI.ToolObject = self

        self:EndEquip()
    end)
end
function ToolBase:Unequip(NextTool) 
    if self.Unequipping then return end

    if self.SwapCoroutine then
        task.cancel(self.SwapCoroutine) 
    end

    self.Animations.Unequip:Play()
    self.Unequipping = true
    self.Swapping = true
    InteractionController.Enabled = false

    self.HideCrosshair:Play()
    self:StartUnequip()
    
    self.SwapCoroutine = task.delay(self.Data.SwapTime or .2, function()
        self.Swapping = false
        self.Equipped = false
        self.Unequipping = false
        
        self.Offsets.Hidden = CFrame.new(0, -10, 0)
        
        InterfaceController.WeaponUI.ToolObject = NextTool 
        InteractionController.Enabled = true
        self:EndUnequip()
    end)
end

function ToolBase:StartUnequip() end
function ToolBase:EndUnequip() end
function ToolBase:StartEquip() end
function ToolBase:EndEquip() end

-- run update tasks
function ToolBase:Update(DeltaTime: number)
    for _, TaskData in pairs(self.SortedUpdateTasks) do
        TaskData.Data.Task(DeltaTime)
    end
end

-- UTIL METHODS

function ToolBase:PrintTasks()
    for _, TaskData in pairs(self.SortedUpdateTasks) do
        print("[ " .. TaskData.Data.Priority .. " ] " .. TaskData.Name)
    end
end

function ToolBase:SortUpdateTasks()
    self.SortedUpdateTasks = {}
    
    for TaskName, TaskData in pairs(self.UpdateTasks) do
        table.insert(self.SortedUpdateTasks, {
            Name = TaskName,
            Data = TaskData,
        })
    end
    
    table.sort(self.SortedUpdateTasks, function(a, b)
        return a.Data.Priority < b.Data.Priority
    end)
end

function ToolBase:AddUpdateTask(Name:string, Priority:number, Task: (Delta: number) -> any)
    self.UpdateTasks[Name] = {
        Priority = Priority,
        Task = Task,
    }
    
    self:SortUpdateTasks()
end

function ToolBase:RemoveUpdateTask(Name:string)
    self.UpdateTasks[Name] = nil    
    
    self:SortUpdateTasks()
end

function ToolBase:LoadAnimation(Name: string, AnimationId: string):AnimationTrack 
    local Animation = Instance.new("Animation")
    Animation.AnimationId = "rbxassetid://" .. AnimationId

    local AnimationTrack = self.Animator:LoadAnimation(Animation)
    self.Animations[Name] = AnimationTrack
end

function ToolBase:Destroy()
    self.Trove:Destroy()
end

return ToolBase
