--[[
    ProjectileController (server)

    Server-authoritative shot resolution via Hindsight. Owns the simulation
    World, auto-captures character poses for rollback, validates client
    cast/throw requests, and broadcasts shots to other clients for visuals.

    Replaces the SecureCast-stubbed FirearmController.
]]

local Controller = {
    Signals = {},
}

Controller.Priority = 50 -- CORE — up before tools try to send fire events

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

-- Tunables. Mirror the Hindsight server example defaults; revisit if cheaters
-- start padding their timestamps or characters teleport on spawn.
local MAXIMUM_LATENCY = 0.8
local INTERPOLATION = 0.048
local MAX_HORIZONTAL_ORIGIN_DRIFT = 5
local MAX_VERTICAL_ORIGIN_DRIFT = 20
local GRENADE_FUSE = 5

-- Defensive caps on client-supplied per-cast overrides. The Punch definition's
-- defaults still apply when the client doesn't send these; these only bound
-- how far a tampered client can crank them.
local MAX_HITSCAN_RANGE = 64
local MAX_HITSCAN_DAMAGE = 200

local function EnsureFolder(Name: string): Folder
    local Existing = workspace:FindFirstChild(Name)
    if Existing and Existing:IsA("Folder") then return Existing end
    local Folder = Instance.new("Folder")
    Folder.Name = Name
    Folder.Parent = workspace
    return Folder
end

local Hindsight, Event
local World
local CharactersFolder: Folder
local BulletsFolder: Folder
local KnownTypes: { [string]: boolean }

function Controller:Init()
    Hindsight = shared.Import("Hindsight")
    Event = shared.Import("Event")

    CharactersFolder = EnsureFolder("Characters")
    BulletsFolder = EnsureFolder("Bullets")

    local DefinitionsModule = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Projectiles")
    KnownTypes = {}
    for ProjectileType in pairs(require(DefinitionsModule)) do
        KnownTypes[ProjectileType] = true
    end

    local RaycastFilter = RaycastParams.new()
    RaycastFilter.FilterType = Enum.RaycastFilterType.Exclude
    RaycastFilter.FilterDescendantsInstances = { CharactersFolder, BulletsFolder }

    World = Hindsight.createWorld({
        actorContainer = ServerScriptService,
        definitionsModule = DefinitionsModule,
        visualsContainer = BulletsFolder,
        excludeContainers = { BulletsFolder, CharactersFolder },
        defaultRaycastFilter = RaycastFilter,
    })

    World.rollback:autoCaptureCharacters(CharactersFolder)

    Event:Listen("FireProjectile", function(Player, Payload)
        Controller:HandleFire(Player, Payload)
    end)

    Event:Listen("ThrowProjectile", function(Player, Payload)
        Controller:HandleThrow(Player, Payload)
    end)

    Event:Listen("HitscanProjectile", function(Player, Payload)
        Controller:HandleHitscan(Player, Payload)
    end)
end

-- Validate that the supplied origin sits within reasonable bounds of the
-- player's character — the bullet origin a legit client would have used. The
-- project's custom rig has no standard "Head" part; the canonical anchor is
-- the `Collider` BasePart owned by MovementController. Fall back to Head /
-- PrimaryPart so this still works on stock Roblox rigs.
local function GetCharacterAnchor(Character: Model): BasePart?
    local Collider = Character:FindFirstChild("Collider")
    if Collider and Collider:IsA("BasePart") then return Collider end
    local Head = Character:FindFirstChild("Head")
    if Head and Head:IsA("BasePart") then return Head end
    if Character.PrimaryPart then return Character.PrimaryPart end
    return nil
end

local function ValidateOrigin(Player: Player, Origin: Vector3): boolean
    local Character = Player.Character
    local Anchor = Character and GetCharacterAnchor(Character)
    if not Anchor then return false end

    local Offset = Origin - Anchor.Position
    local Horizontal = Vector3.new(Offset.X, 0, Offset.Z).Magnitude
    local Vertical = math.abs(Offset.Y)
    return Horizontal <= MAX_HORIZONTAL_ORIGIN_DRIFT and Vertical <= MAX_VERTICAL_ORIGIN_DRIFT
end

local function ValidatePayload(Player: Player, Payload): boolean
    if typeof(Payload) ~= "table" then return false end
    if typeof(Payload.Type) ~= "string" or not KnownTypes[Payload.Type] then return false end
    if typeof(Payload.Origin) ~= "Vector3" then return false end
    if typeof(Payload.Direction) ~= "Vector3" then return false end
    if typeof(Payload.Timestamp) ~= "number" then return false end

    local Latency = workspace:GetServerTimeNow() - Payload.Timestamp
    if Latency < 0 or Latency > MAXIMUM_LATENCY then return false end

    if not ValidateOrigin(Player, Payload.Origin) then return false end

    -- Optional two-ray visual fields. Visual origin must also pass the
    -- head-proximity check so a tampered client can't broadcast tracers that
    -- visually originate from across the map.
    if Payload.VisualOrigin ~= nil then
        if typeof(Payload.VisualOrigin) ~= "Vector3" then return false end
        if not ValidateOrigin(Player, Payload.VisualOrigin) then return false end
    end
    if Payload.VisualDirection ~= nil and typeof(Payload.VisualDirection) ~= "Vector3" then
        return false
    end

    return true
end

function Controller:HandleFire(Player: Player, Payload)
    if not ValidatePayload(Player, Payload) then return end

    local RewindOffset = Player:GetNetworkPing() + INTERPOLATION
    local RewindTime = Payload.Timestamp - RewindOffset

    -- Broadcast to other clients before casting so their visuals start in
    -- parallel with the server's authoritative resolution. Visual origin/dir
    -- are forwarded so remote tracers also leave the caster's muzzle (two-ray
    -- dual origin); they're nil when the caster didn't supply them.
    Event:FireAllClients(
        "ProjectileFired",
        Player,
        Payload.Type,
        Payload.Origin,
        Payload.Direction,
        Payload.VisualOrigin,
        Payload.VisualDirection
    )

    World:cast({
        caster = Player,
        type = Payload.Type,
        origin = Payload.Origin,
        direction = Payload.Direction,
        timestamp = RewindTime,
    })
end

function Controller:HandleThrow(Player: Player, Payload)
    if not ValidatePayload(Player, Payload) then return end

    -- Cooked-grenade fuse: clamp client-reported cook elapsed and use what's
    -- left of the fuse as the projectile's lifetime. A grenade cooked past
    -- the fuse explodes immediately on cast.
    local CookElapsed = typeof(Payload.CookElapsed) == "number" and Payload.CookElapsed or 0
    local RemainingFuse = math.clamp(GRENADE_FUSE - CookElapsed, 0, GRENADE_FUSE)

    local RewindOffset = Player:GetNetworkPing() + INTERPOLATION
    local RewindTime = Payload.Timestamp - RewindOffset

    Event:FireAllClients(
        "ProjectileThrown",
        Player,
        Payload.Type,
        Payload.Origin,
        Payload.Direction,
        RemainingFuse
    )

    World:cast({
        caster = Player,
        type = Payload.Type,
        origin = Payload.Origin,
        direction = Payload.Direction,
        timestamp = RewindTime,
        modifier = { lifetime = RemainingFuse },
    })
end

-- Hindsight 0.2.0 hitscan path. Reuses the same payload validation as the
-- projectile path — origin within head-proximity, timestamp inside the rewind
-- window — then resolves the ray on the main thread via World:hitscan instead
-- of dispatching a stepped projectile. No client broadcast for hitscans yet;
-- punches don't need a visible tracer on remote screens.
--
-- Optional Payload.Range / Payload.Damage are per-cast overrides clamped to
-- defensive caps and forwarded as a Hindsight modifier — Range overrides the
-- definition's `range`; Damage rides on `extra` for the projectile's
-- onIntersection callback to read.
function Controller:HandleHitscan(Player: Player, Payload)
    if not ValidatePayload(Player, Payload) then return end

    local RewindOffset = Player:GetNetworkPing() + INTERPOLATION
    local RewindTime = Payload.Timestamp - RewindOffset

    local Modifier = nil
    local Range = if typeof(Payload.Range) == "number" then math.clamp(Payload.Range, 0, MAX_HITSCAN_RANGE) else nil
    local Damage = if typeof(Payload.Damage) == "number" then math.clamp(Payload.Damage, 0, MAX_HITSCAN_DAMAGE) else nil
    if Range or Damage then
        Modifier = {
            range = Range,
            extra = if Damage then { Damage = Damage } else nil,
        }
    end

    World:hitscan({
        caster = Player,
        type = Payload.Type,
        origin = Payload.Origin,
        direction = Payload.Direction,
        timestamp = RewindTime,
        modifier = Modifier,
    })
end

function Controller.Signals.PlayerAdded(Player: Player)
    if Player.Character then
        Player.Character.Parent = CharactersFolder
    end

    Player.CharacterAdded:Connect(function(Character)
        -- One frame of settling so HumanoidRootPart etc. are wired before the
        -- snapshot loop tries to read the rig.
        RunService.PostSimulation:Wait()
        Character.Parent = CharactersFolder
    end)
end

return Controller
