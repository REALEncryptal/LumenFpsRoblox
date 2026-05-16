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

local function ensureFolder(name: string): Folder
    local existing = workspace:FindFirstChild(name)
    if existing and existing:IsA("Folder") then return existing end
    local folder = Instance.new("Folder")
    folder.Name = name
    folder.Parent = workspace
    return folder
end

local Hindsight, Event
local World
local CharactersFolder: Folder
local BulletsFolder: Folder
local KnownTypes: { [string]: boolean }

function Controller:Init()
    Hindsight = shared.Import("Hindsight")
    Event = shared.Import("Event")

    CharactersFolder = ensureFolder("Characters")
    BulletsFolder = ensureFolder("Bullets")

    local definitionsModule = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Projectiles")
    KnownTypes = {}
    for projectileType in pairs(require(definitionsModule)) do
        KnownTypes[projectileType] = true
    end

    local raycastFilter = RaycastParams.new()
    raycastFilter.FilterType = Enum.RaycastFilterType.Exclude
    raycastFilter.FilterDescendantsInstances = { CharactersFolder, BulletsFolder }

    World = Hindsight.createWorld({
        actorContainer = ServerScriptService,
        definitionsModule = definitionsModule,
        visualsContainer = BulletsFolder,
        excludeContainers = { BulletsFolder, CharactersFolder },
        defaultRaycastFilter = raycastFilter,
    })

    World.rollback:autoCaptureCharacters(CharactersFolder)

    Event:Listen("FireProjectile", function(player, payload)
        Controller:HandleFire(player, payload)
    end)

    Event:Listen("ThrowProjectile", function(player, payload)
        Controller:HandleThrow(player, payload)
    end)
end

-- Validate that the supplied origin sits within reasonable bounds of the
-- player's head — the bullet origin a legit client would have used.
local function validateOrigin(player: Player, origin: Vector3): boolean
    local character = player.Character
    local head = character and character:FindFirstChild("Head")
    if not head or not head:IsA("BasePart") then return false end

    local offset = origin - head.Position
    local horizontal = Vector3.new(offset.X, 0, offset.Z).Magnitude
    local vertical = math.abs(offset.Y)
    return horizontal <= MAX_HORIZONTAL_ORIGIN_DRIFT and vertical <= MAX_VERTICAL_ORIGIN_DRIFT
end

local function validatePayload(player: Player, payload): boolean
    if typeof(payload) ~= "table" then return false end
    if typeof(payload.type) ~= "string" or not KnownTypes[payload.type] then return false end
    if typeof(payload.origin) ~= "Vector3" then return false end
    if typeof(payload.direction) ~= "Vector3" then return false end
    if typeof(payload.timestamp) ~= "number" then return false end

    local latency = workspace:GetServerTimeNow() - payload.timestamp
    if latency < 0 or latency > MAXIMUM_LATENCY then return false end

    if not validateOrigin(player, payload.origin) then return false end

    return true
end

function Controller:HandleFire(player: Player, payload)
    if not validatePayload(player, payload) then return end

    local rewindOffset = player:GetNetworkPing() + INTERPOLATION
    local rewindTime = payload.timestamp - rewindOffset

    -- Broadcast to other clients before casting so their visuals start in
    -- parallel with the server's authoritative resolution.
    Event:FireAllClients("ProjectileFired", player, payload.type, payload.origin, payload.direction)

    World:cast({
        caster = player,
        type = payload.type,
        origin = payload.origin,
        direction = payload.direction,
        timestamp = rewindTime,
    })
end

function Controller:HandleThrow(player: Player, payload)
    if not validatePayload(player, payload) then return end

    -- Cooked-grenade fuse: clamp client-reported cook elapsed and use what's
    -- left of the fuse as the projectile's lifetime. A grenade cooked past
    -- the fuse explodes immediately on cast.
    local cookElapsed = typeof(payload.cookElapsed) == "number" and payload.cookElapsed or 0
    local remainingFuse = math.clamp(GRENADE_FUSE - cookElapsed, 0, GRENADE_FUSE)

    local rewindOffset = player:GetNetworkPing() + INTERPOLATION
    local rewindTime = payload.timestamp - rewindOffset

    Event:FireAllClients(
        "ProjectileThrown",
        player,
        payload.type,
        payload.origin,
        payload.direction,
        remainingFuse
    )

    World:cast({
        caster = player,
        type = payload.type,
        origin = payload.origin,
        direction = payload.direction,
        timestamp = rewindTime,
        modifier = { lifetime = remainingFuse },
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
