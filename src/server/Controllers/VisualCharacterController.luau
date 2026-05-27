--[[
    VisualCharacterController (server)

    Builds the player's actual Roblox avatar on top of the invisible Collider
    StarterCharacter and Motor6D-welds it as a child of the Character. The rig's
    Humanoid is fully neutralised — no movement, no rotation, no collision, no
    mass — so it adds zero physical behaviour. Movement stays driven by the
    Collider's AssemblyLinearVelocity in MovementController, and the existing
    Orient AlignOrientation keeps the Collider's rotation locked.

    Replication happens for free: the rig is parented to Player.Character, which
    ProjectileController.PlayerAdded already moves to workspace.Characters.
]]

local Controller = {
    Signals = {},
}

Controller.Priority = 500 -- NORMAL

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local function NeutraliseHumanoid(Humanoid: Humanoid)
    Humanoid.WalkSpeed = 0
    Humanoid.JumpPower = 0
    Humanoid.JumpHeight = 0
    Humanoid.AutoRotate = false
    Humanoid.BreakJointsOnDeath = false
    Humanoid.RequiresNeck = false
    Humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None

    pcall(function() (Humanoid :: any).EvaluateStateMachine = false end)

    for _, State in Enum.HumanoidStateType:GetEnumItems() do
        if State ~= Enum.HumanoidStateType.None then
            pcall(Humanoid.SetStateEnabled, Humanoid, State, false)
        end
    end
    Humanoid:ChangeState(Enum.HumanoidStateType.Physics)
end

local function NeutraliseParts(Rig: Model)
    for _, D in Rig:GetDescendants() do
        if D:IsA("BasePart") then
            D.CanCollide = false
            D.CanQuery = false
            D.CanTouch = false
            D.Massless = true
        end
    end
end

local function AttachVisualRig(Player: Player, Character: Model)
    RunService.PostSimulation:Wait()

    if not Character.Parent then return end

    local Collider = Character:FindFirstChild("Collider") :: BasePart?
    if not Collider then return end

    -- Force R6 regardless of the player's avatar setting. Fetching the
    -- HumanoidDescription preserves their actual appearance (clothing, body
    -- colors, accessories) while CreateHumanoidModelFromDescription's second
    -- arg pins the rig type. Both calls yield and can fail (offline avatar,
    -- web throttle) — fall back to silent no-visual on failure.
    local DescOk, Description = pcall(Players.GetHumanoidDescriptionFromUserId, Players, Player.UserId)
    if not DescOk or not Description then return end

    local Ok, Rig = pcall(Players.CreateHumanoidModelFromDescription, Players, Description, Enum.HumanoidRigType.R6)
    if not Ok or not Rig then return end
    if not Character.Parent or not Collider.Parent then
        Rig:Destroy()
        return
    end

    Rig.Name = "VisualRig"

    local Humanoid = Rig:FindFirstChildOfClass("Humanoid")
    if Humanoid then NeutraliseHumanoid(Humanoid) end

    NeutraliseParts(Rig)

    local Root = Rig.PrimaryPart or Rig:FindFirstChild("HumanoidRootPart") :: BasePart?
    if not Root then
        Rig:Destroy()
        return
    end
    Root.Anchored = false

    local Joint = Instance.new("Motor6D")
    Joint.Name = "VisualWeld"
    Joint.Part0 = Collider
    Joint.Part1 = Root
    Joint.C0 = CFrame.new(0, 2, 0)
    Joint.Parent = Collider

    Rig.Parent = Character
end

function Controller.Signals.PlayerAdded(Player: Player)
    if Player.Character then
        task.spawn(AttachVisualRig, Player, Player.Character)
    end

    Player.CharacterAdded:Connect(function(Character)
        AttachVisualRig(Player, Character)
    end)
end

return Controller
