--[[

    CHARACTER CONTROLLER (SERVER)

    Assembles the player's physics rig on top of Roblox's default R6 spawn so
    other players see a real visible body instead of nothing. The visible
    body follows the Collider (which the client-side MovementController drives
    with Source-style physics). Locally, the body is hidden via
    LocalTransparencyModifier in MovementController so the player keeps the
    pure first-person viewmodel.

    Per-spawn the server adds, parented to Character:
        Collider            Part        zero-friction physics hull, network-owned by player
        Force               VectorForce cancels solver gravity (client writes per-frame)
        Velocity            LinearVelocity disabled by default; reserved for impulses

    HumanoidRootPart is welded to the Collider via a Motor6D so the visible
    R6 rig follows the physics hull. The Humanoid is kept alive (so
    LoadoutController's Humanoid.Died still works) but all locomotive states
    are disabled so its built-in physics doesn't fight the custom movement.

    ONE-TIME STUDIO SETUP (not tracked by Rojo):
        1. Delete StarterPlayer.StarterCharacter (if present).
        2. Game Settings -> Avatar -> Avatar Type = R6.
        3. Animation = Standard. Collision = Inner Box (or default).

--]]

local Players = game:GetService("Players")
local StarterPlayer = game:GetService("StarterPlayer")

print("[CharacterController] module loaded")

local Controller = {Signals = {}}
local Constants

Controller.Priority = 50

local HULL_SIZE = Vector3.new(2, 4.5, 2)

local DISABLED_HUMANOID_STATES = {
    Enum.HumanoidStateType.Running,
    Enum.HumanoidStateType.Climbing,
    Enum.HumanoidStateType.Jumping,
    Enum.HumanoidStateType.GettingUp,
    Enum.HumanoidStateType.Freefall,
    Enum.HumanoidStateType.FallingDown,
    Enum.HumanoidStateType.Landed,
    Enum.HumanoidStateType.Ragdoll,
    Enum.HumanoidStateType.PlatformStanding,
    Enum.HumanoidStateType.Swimming,
    Enum.HumanoidStateType.Seated,
    Enum.HumanoidStateType.StrafingNoPhysics,
    Enum.HumanoidStateType.RunningNoPhysics,
}

local function BuildCollider(Character: Model, Origin: Vector3): (Part, Attachment)
    local Collider = Instance.new("Part")
    Collider.Name = "Collider"
    Collider.Shape = Enum.PartType.Block
    Collider.Size = HULL_SIZE
    Collider.Transparency = 1
    Collider.CanCollide = true
    Collider.CanQuery = false
    Collider.CanTouch = false
    Collider.Massless = false
    Collider.TopSurface = Enum.SurfaceType.Smooth
    Collider.BottomSurface = Enum.SurfaceType.Smooth
    Collider.CustomPhysicalProperties = PhysicalProperties.new(1, 0, 0, 100, 100)
    Collider.CFrame = CFrame.new(Origin)

    local RootAttachment = Instance.new("Attachment")
    RootAttachment.Name = "RootAttachment"
    RootAttachment.Parent = Collider

    Collider.Parent = Character
    return Collider, RootAttachment
end

local function BuildConstraints(Character: Model, RootAttachment: Attachment)
    local Force = Instance.new("VectorForce")
    Force.Name = "Force"
    Force.Attachment0 = RootAttachment
    Force.ApplyAtCenterOfMass = true
    Force.RelativeTo = Enum.ActuatorRelativeTo.World
    Force.Force = Vector3.zero
    Force.Parent = Character

    local Velocity = Instance.new("LinearVelocity")
    Velocity.Name = "Velocity"
    Velocity.Attachment0 = RootAttachment
    Velocity.RelativeTo = Enum.ActuatorRelativeTo.World
    Velocity.MaxForce = math.huge
    Velocity.VectorVelocity = Vector3.zero
    Velocity.Enabled = false
    Velocity.Parent = Character
end

local function WeldRootToCollider(Collider: Part, HumanoidRootPart: BasePart)
    HumanoidRootPart.Massless = true
    HumanoidRootPart.CanCollide = false

    local Joint = Instance.new("Motor6D")
    Joint.Name = "ColliderRoot"
    Joint.Part0 = Collider
    Joint.Part1 = HumanoidRootPart
    Joint.C0 = CFrame.new()
    Joint.C1 = CFrame.new()
    Joint.Parent = Collider
end

local function NeutralizeBodyParts(Character: Model, Collider: Part, HumanoidRootPart: BasePart)
    for _, Descendant in ipairs(Character:GetDescendants()) do
        if not Descendant:IsA("BasePart") then continue end
        if Descendant == Collider or Descendant == HumanoidRootPart then continue end
        Descendant.CanCollide = false
        Descendant.Massless = true
    end
end

local function NeutralizeHumanoid(Humanoid: Humanoid)
    for _, State in ipairs(DISABLED_HUMANOID_STATES) do
        Humanoid:SetStateEnabled(State, false)
    end
    Humanoid:ChangeState(Enum.HumanoidStateType.Physics)
end

local function OnCharacterAdded(Player: Player, Character: Model)
    print("[CharacterController] OnCharacterAdded for", Player.Name, "parent:", Character.Parent and Character.Parent.Name)

    local HumanoidRootPart = Character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
    local Humanoid = Character:WaitForChild("Humanoid", 10) :: Humanoid?
    if not HumanoidRootPart or not Humanoid then
        warn(string.format("[CharacterController] %s spawned without HRP/Humanoid", Player.Name))
        return
    end

    local Collider, RootAttachment = BuildCollider(Character, HumanoidRootPart.Position)
    BuildConstraints(Character, RootAttachment)
    WeldRootToCollider(Collider, HumanoidRootPart)
    NeutralizeBodyParts(Character, Collider, HumanoidRootPart)
    NeutralizeHumanoid(Humanoid)

    pcall(function()
        Collider:SetNetworkOwner(Player)
    end)

    print("[CharacterController] rig assembled for", Player.Name)
end

local function HookPlayer(Player: Player)
    print("[CharacterController] HookPlayer", Player.Name, "Character?", Player.Character ~= nil)
    Player.CharacterAdded:Connect(function(Character)
        OnCharacterAdded(Player, Character)
    end)
    if Player.Character then
        OnCharacterAdded(Player, Player.Character)
    end
end

function Controller:Init()
    print("[CharacterController] Init running")
    Constants = shared.Import("Constants")

    local StoredStarter = StarterPlayer:FindFirstChild("StarterCharacter")
    if StoredStarter then
        StoredStarter:Destroy()
    end

    for _, Player in ipairs(Players:GetPlayers()) do
        HookPlayer(Player)
    end
end

function Controller.Signals.PlayerAdded(Player: Player)
    HookPlayer(Player)
end

return Controller
