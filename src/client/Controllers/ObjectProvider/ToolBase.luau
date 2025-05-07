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
local CharacterUtil = shared.Import("CharacterUtil")

function ToolBase.new( ToolFolder: Folder )
    assert(ToolFolder, "ToolBase.New - ToolFolder is nil")
    assert(typeof(ToolFolder) == "Instance", "ToolBase.New - ToolFolder is not an Instance")
    assert(ToolFolder:IsA("Folder"), "ToolBase.New - ToolFolder is not a Folder")
    
    local self = setmetatable({}, ToolBase)

    self.Data = require(ToolFolder:FindFirstChildOfClass("ModuleScript"))

    -- 
    self.Trove = Trove.new()
    self.UpdateTasks = {}
    self.SortedUpdateTasks = {}

    -- 
    local ToolModel = ToolFolder:FindFirstChildOfClass("Model")
    assert(ToolModel, "ToolBase.New - ToolModel not found")

    self.Viewmodel = self.Data.IsRigged and ToolModel or ReplicatedStorage.Assets.Viewmodel
    self.Viewmodel = self.Trove:Clone(self.Viewmodel)
    self.Viewmodel:ScaleTo(Constants.ToolScale)
    self.Viewmodel.Parent = workspace.CurrentCamera

    self.Animator = self.Viewmodel:FindFirstChild("Animator", true)
    assert(self.Animator, "ToolBase.New - Animator not found")

    if not self.Data.IsRigged then
        self.Tool = self.Trove:Clone(ToolModel)
        self.Tool:ScaleTo(Constants.ToolScale)
        self.Tool.Parent = self.Viewmodel

        local Joint = Instance.new "Motor6D"
        Joint.Parent = self.Tool.PrimaryPart
        Joint.Part0 = self.Tool.PrimaryPart
        Joint.Part1 = self.Viewmodel.PrimaryPart
        Joint.Name = "Tool"
    end

    if self.Data.Crosshair then
        self.Crosshair = self.Trove:Clone(ReplicatedStorage.Assets.Crosshair)
        self.Crosshair.Parent = workspace.CurrentCamera
    end
    
    -- 
    self.Animations = {}

    self.Offset = {
        Base = self.Data.Offsets.Base or CFrame.new(),
    }

    self.Springs = {
        Idle = Spring.new(),
        Sway = Spring.new(),
        Walk = Spring.new(),
        Run = Spring.new(),
        Air = Spring.new(),
        Impact = Spring.new(),
    }

    self.Equipped = false
    self.Swapping = false
    self.ViewmodelCFrame = CFrame.new()
    self.CameraCFrame = workspace.CurrentCamera.CFrame
    self.PreviousCameraCFrame = workspace.CurrentCamera.CFrame

    -- Load animations
    for AnimationName, AnimationId in pairs(self.Data.Animations) do
        self:LoadAnimation(AnimationName, AnimationId)
    end

    if self.Animations.Idle then
        self.Animations.Idle:Play()
    end

    -- Update Tasks
    self:AddUpdateTask("UpdateState", 100, function(DeltaTime: number)
        self.State = {
            MoveDirection = CharacterUtil.GetMoveDirection(),
            WasGrounded = CharacterUtil.WasGrounded(),
            Grounded = CharacterUtil.IsGrounded(),
            MouseDelta = UserInputService:GetMouseDelta(),
            Velocity = CharacterUtil.GetVelocity(),
        }
    end)

    -- Shove Springs
    self:AddUpdateTask("ShoveSprings", 101, function(DeltaTime: number)
        -- Walk Spring
        if self.State.MoveDirection.Magnitude > 0.1 and self.State.Grounded then
            local Magnitude = .0007
            local Speed = 15
            local Time = tick() * Speed

            self.Springs.Walk:Shove(Vector3.new(
                math.cos(Time/2) * Magnitude * .7,
                math.sin(Time) * Magnitude,
                0
            ))
        end

        -- in Air
        if not self.State.Grounded then
            self.Springs.Air:Shove(Vector3.new(
                0,
                .001,
                0
            ))
        end

        -- Jump
        if not self.State.Grounded and self.State.WasGrounded then
            self.Springs.Air:Shove(Vector3.new(
                0,
                .005,
                0
            ))
        end

        -- Impact
        if self.State.Grounded and not self.State.WasGrounded and self.State.Velocity.Y < -2 then
            self.Springs.Impact:Shove(Vector3.new(
                0,
                -.015,
                0
            ))
        end

        -- Sway Spring
        local Magnitude = .0001

        self.Springs.Sway:Shove(Vector3.new(self.State.MouseDelta.X * Magnitude, -self.State.MouseDelta.Y * Magnitude, 0))
    end)

    -- Update Springs
    self:AddUpdateTask("UpdateSprings", 102, function(DeltaTime: number)
        self.UpdatedSprings = {}
        for SpringName, Spring in pairs(self.Springs) do
            self.UpdatedSprings[SpringName] = Spring:Update(DeltaTime)
        end
    end)

    -- Update viewmodel cframe
    self:AddUpdateTask("UpdateViewmodelCFrame", 103, function(DeltaTime: number)
        self.ViewmodelCFrame = CFrame.new()
        self.ViewmodelCFrame *= workspace.CurrentCamera.CFrame
        self.ViewmodelCFrame *= self.Offset.Base
        self.ViewmodelCFrame *= CFrame.new(self.UpdatedSprings.Walk * self.Viewmodel:GetScale())
        self.ViewmodelCFrame *= CFrame.new(self.UpdatedSprings.Sway * self.Viewmodel:GetScale() * .5) * CFrame.Angles(math.rad(self.UpdatedSprings.Sway.X *-5), math.rad(self.UpdatedSprings.Sway.Y *-5), 0)
        self.ViewmodelCFrame *= CFrame.new(self.UpdatedSprings.Air * self.Viewmodel:GetScale())
        self.ViewmodelCFrame *= CFrame.new(self.UpdatedSprings.Impact * self.Viewmodel:GetScale())
    end)

    -- Set Viewmodel
    self:AddUpdateTask("SetViewmodelCFrame", 104, function(DeltaTime: number)
        self.Viewmodel.PrimaryPart.CFrame = self.ViewmodelCFrame
    end)

    -- Update camera cframe, seperated so children may add  
    self:AddUpdateTask("UpdateCameraCFrame", 105, function(DeltaTime: number)
        self.CameraCFrame = self.ViewmodelCFrame:ToObjectSpace(self.Viewmodel:FindFirstChild("CameraPart").CFrame)
    end)

    -- Set Camera
    self:AddUpdateTask("Update", 106, function(DeltaTime: number)
        workspace.Camera.CFrame *= self.PreviousCameraCFrame:Inverse()
        
        if self.Crosshair then
            self.Crosshair.Position = workspace.Camera.CFrame.Position + workspace.Camera.CFrame.LookVector * 100
        end

        workspace.Camera.CFrame *= self.CameraCFrame 
        self.PreviousCameraCFrame = self.CameraCFrame
    end)

    -- DEBUG
    print(" New Tool: " .. self.Data.Name)  
    self:PrintTasks()
    
    return self
end

-- MAIN METHODS

function ToolBase:Activate() end
function ToolBase:AltActivate() end

function ToolBase:Equip() end
function ToolBase:Unequip() end

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
