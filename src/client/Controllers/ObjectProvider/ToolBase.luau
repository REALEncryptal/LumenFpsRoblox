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
local Trove = shared.Import("Trove")
local Spring = shared.Import("Spring3")
local Constants = shared.Import("Constants")
local CharacterController = shared.Import("CharacterController")
local InterfaceController = shared.Import("InterfaceController")
local CFrameUtil = shared.Import("CFrameUtil")
local InteractionController = shared.Import("InteractionController")
local InputUtil = shared.Import("InputUtil")

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

    -- Crosshair, ammo, reload, etc. now live in Components (see :AddComponent
    -- below). The legacy Data.Crosshair = true flag still works — see the
    -- Data.Components loop near the end of this constructor.

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
    self.CameraCFrame = nil
    self.PreviousCameraCFrame = nil

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

    -- Update camera cframe, seperated so children may add.
    -- Impact spring is intentionally NOT folded into the camera CFrame here —
    -- the spring is damped/oscillating, so feeding it into the camera produces
    -- the exact smooth chase that fights CameraController's Source-style snap.
    -- Impact stays on the viewmodel (gun-jolt) only; camera kick goes through
    -- CameraController:ApplyRecoil.
    self:AddUpdateTask("UpdateCameraCFrame", 102.5, function(DeltaTime: number)
        self.CameraCFrame = self.Viewmodel:FindFirstChild("CameraPart").CFrame:ToObjectSpace(self.Viewmodel.PrimaryPart.CFrame)

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

        workspace.CurrentCamera.CFrame *= self.PreviousCameraCFrame and self.PreviousCameraCFrame:Inverse() or CFrame.new()

        -- Crosshair sits between the camera invert and re-apply so it lives in
        -- raw-camera space (no spring jitter). The Crosshair component owns
        -- the Instance; ToolBase just positions it here to stay inside the
        -- camera surgery window.
        local CrosshairComponent = self:GetComponent("Crosshair")
        if CrosshairComponent then
            local CrosshairInstance = CrosshairComponent.Instance
            local CrosshairDistance = CrosshairComponent:GetPositionDistance()
            CrosshairInstance.Position = workspace.CurrentCamera.CFrame.Position + workspace.CurrentCamera.CFrame.LookVector * CrosshairDistance
            CrosshairInstance.CFrame = CFrame.lookAt(CrosshairInstance.Position, workspace.CurrentCamera.CFrame.Position)
        end

        workspace.CurrentCamera.CFrame *= self.CameraCFrame
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

    -- Component runtime: tools host a list of Components that own discrete
    -- concerns (ammo, reload, ADS, fire, cook, throw, etc.). Components are
    -- added via :AddComponent, destroyed with the tool via Trove.
    self.Components = {}
    self.ComponentList = {}
    self._BoundActions = {}

    -- Bindings live only while the tool is equipped; destroying a tool mid-equip
    -- must still tear down its InputUtil registrations.
    self.Trove:Add(function()
        self:_DeactivateBindings()
    end)

    -- Data-driven Components:
    --   Data.Components = { {Name = "Crosshair", Config = {}}, ... }
    -- Each entry's Name resolves through Librarian so a component file at
    -- src/client/Tool/Components/<Name>.luau is enough — no manual registration.
    if self.Data.Components then
        for _, Entry in ipairs(self.Data.Components) do
            local ComponentClass = shared.Import(Entry.Name)
            self:AddComponent(Entry.Name, ComponentClass, Entry.Config or {})
        end
    elseif self.Data.Crosshair then
        -- Legacy fallback for tool data that hasn't migrated to Components yet
        -- (e.g. an M4A1 module from before Phase 6).
        self:AddComponent("Crosshair", shared.Import("Crosshair"), {})
    end

    return self
end

-- DEBUG
function ToolBase:CreateDebug(Iris)
    for _, Component in ipairs(self.ComponentList) do
        if Component.CreateDebug then
            Component:CreateDebug(Iris)
            Iris.Separator()
        end
    end
end

-- MAIN METHODS

function ToolBase:Hide(Hide: boolean)
    self.Offsets._Hidden = Hide and CFrame.new(-100, 0, 0) or CFrame.new()
    self.Enabled = not Hide

    local Crosshair = self:GetComponent("Crosshair")
    if Crosshair then
        Crosshair:SetEnabled(not Hide)
    end
end

-- Crosshair facade: nil-safe wrappers so callers don't need to GetComponent +
-- nil-check at every show/hide site. Tools without a Crosshair component
-- (Fists) get silent no-ops.
function ToolBase:ShowCrosshair()
    local Crosshair = self:GetComponent("Crosshair")
    if Crosshair then Crosshair:Show() end
end

function ToolBase:HideCrosshair()
    local Crosshair = self:GetComponent("Crosshair")
    if Crosshair then Crosshair:Hide() end
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

    self:ShowCrosshair()
    self:StartEquip()
    
    self.SwapCoroutine = task.delay(self.Data.SwapTime or 0, function()
        self.Swapping = false
        self.Equipped = true
        self.Equipping = false

        InteractionController.Enabled = true

        InterfaceController.WeaponUI.ToolObject = self

        for _, Component in ipairs(self.ComponentList) do
            if Component.Equip then Component:Equip() end
        end

        self:_ActivateBindings()

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

    self:HideCrosshair()

    self:_DeactivateBindings()

    for _, Component in ipairs(self.ComponentList) do
        if Component.Unequip then Component:Unequip() end
    end

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
    
    table.sort(self.SortedUpdateTasks, function(A, B)
        return A.Data.Priority < B.Data.Priority
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

-- COMPONENT API

function ToolBase:AddComponent(Name: string, ComponentClass, Config)
    assert(Name, "AddComponent: Name is nil")
    assert(ComponentClass, "AddComponent: ComponentClass is nil for " .. Name)
    assert(not self.Components[Name], "AddComponent: component already exists: " .. Name)

    local Component = ComponentClass.new(self, Config or {})
    self.Components[Name] = Component
    table.insert(self.ComponentList, Component)

    self.Trove:Add(function()
        if Component.Destroy then Component:Destroy() end
    end)

    if Component.Init then Component:Init() end

    return Component
end

function ToolBase:GetComponent(Name: string)
    return self.Components[Name]
end

-- HUD CONTRACT
--
-- Returns a flat table describing what this tool wants the WeaponUI to render.
-- Shape:
--   Icon       string?           -- HudImage assetId for the tool's portrait
--   Primary    (number|string)?  -- main readout (ammo count, grenade count)
--   Secondary  (number|string)?  -- secondary readout (stored ammo, fuse time)
--   Mode       string?           -- "ammo" | "count" | "timer" | nil; nil hides ammo block
--
-- ToolBase merges contributions from every Component that implements
-- :GetHudContribution(). Components later in ComponentList override earlier
-- ones for the same field — order matches AddComponent registration order.
function ToolBase:GetHudState()
    local State = {
        Icon = self.Data.HudImage,
        Primary = nil,
        Secondary = nil,
        Mode = nil,
    }

    for _, Component in ipairs(self.ComponentList) do
        if not Component.GetHudContribution then continue end
        local Contribution = Component:GetHudContribution()
        if not Contribution then continue end

        if Contribution.Icon ~= nil then State.Icon = Contribution.Icon end
        if Contribution.Primary ~= nil then State.Primary = Contribution.Primary end
        if Contribution.Secondary ~= nil then State.Secondary = Contribution.Secondary end
        if Contribution.Mode ~= nil then State.Mode = Contribution.Mode end
    end

    return State
end

-- BINDINGS

-- Walks every Component's declared `Bindings` table and registers each action
-- with InputUtil. Called from the equip SwapCoroutine; mirrored by
-- _DeactivateBindings on unequip. Action names must be unique across all
-- components on a single tool — InputUtil rejects double-binds.
function ToolBase:_ActivateBindings()
    for ActionName in pairs(self._BoundActions) do
        InputUtil:UnbindAction(ActionName)
    end
    table.clear(self._BoundActions)

    for _, Component in ipairs(self.ComponentList) do
        local Bindings = Component.Bindings
        if not Bindings then continue end

        for ActionName, Binding in pairs(Bindings) do
            assert(not self._BoundActions[ActionName],
                "ToolBase: binding action collision across components: " .. ActionName)

            local Handler = Binding.OnState
            InputUtil:BindAction(ActionName, function(_, State, InputObject)
                if Handler then
                    Handler(Component, State, InputObject)
                end
            end, false, table.unpack(Binding.Inputs))

            self._BoundActions[ActionName] = true
        end
    end
end

function ToolBase:_DeactivateBindings()
    if not self._BoundActions then return end
    for ActionName in pairs(self._BoundActions) do
        InputUtil:UnbindAction(ActionName)
    end
    table.clear(self._BoundActions)
end

function ToolBase:Destroy()
    self.Trove:Destroy()
end

return ToolBase
