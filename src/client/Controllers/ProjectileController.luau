--[[
    ProjectileController (client)

    Owns the client-side Hindsight World — purely for rendering projectile
    visuals. The server does the authoritative hit resolution. Tool Components
    talk to this controller via :Cast() / :Throw() rather than calling Hindsight
    directly, so the network protocol stays in one place.
]]

local Controller = {
    Signals = {},
}

Controller.Priority = 50 -- CORE — up before tools try to cast

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

local GRENADE_FUSE = 5

local Hindsight, Event, ProjectileDebugController
local World
local BulletsFolder: Instance
local CharactersFolder: Instance

-- Per-projectile-type visual templates. Hindsight clones whichever one is
-- passed as `visual` on each cast into BulletsFolder. Add entries here as
-- more projectile types get visual assets under ReplicatedStorage.Assets.
local Visuals: { [string]: PVInstance } = {}

function Controller:Init()
    Hindsight = shared.Import("Hindsight")
    Event = shared.Import("Event")
    ProjectileDebugController = shared.Import("ProjectileDebugController")

    BulletsFolder = workspace:WaitForChild("Bullets")
    CharactersFolder = workspace:WaitForChild("Characters")

    local Assets = ReplicatedStorage:WaitForChild("Assets")
    local ProjectileAssets = Assets:WaitForChild("Projectiles")
    Visuals.Bullet = ProjectileAssets:WaitForChild("Tracer") :: PVInstance

    local DefinitionsModule = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Projectiles")

    local RaycastFilter = RaycastParams.new()
    RaycastFilter.FilterType = Enum.RaycastFilterType.Exclude
    RaycastFilter.FilterDescendantsInstances = { CharactersFolder, BulletsFolder }

    World = Hindsight.createWorld({
        actorContainer = LocalPlayer:WaitForChild("PlayerScripts"),
        definitionsModule = DefinitionsModule,
        visualsContainer = BulletsFolder,
        excludeContainers = { BulletsFolder, CharactersFolder },
        defaultRaycastFilter = RaycastFilter,
    })

    -- Render other players' shots locally. The caster runs its own visual cast
    -- before sending to the server, so it skips its own broadcasted echo.
    Event:Listen("ProjectileFired", function(Caster, ProjectileType, Origin, Direction)
        if Caster == LocalPlayer then return end
        World:cast({
            caster = Caster,
            type = ProjectileType,
            origin = Origin,
            direction = Direction,
            timestamp = workspace:GetServerTimeNow(),
            visual = Visuals[ProjectileType],
        })
    end)

    Event:Listen("ProjectileThrown", function(Caster, ProjectileType, Origin, Direction, RemainingFuse)
        if Caster == LocalPlayer then return end
        World:cast({
            caster = Caster,
            type = ProjectileType,
            origin = Origin,
            direction = Direction,
            timestamp = workspace:GetServerTimeNow(),
            modifier = { lifetime = RemainingFuse },
            visual = Visuals[ProjectileType],
        })
    end)
end

-- Hitscan/projectile fire — used by HitscanFire-style components.
function Controller:Cast(ProjectileType: string, Origin: Vector3, Direction: Vector3)
    local Timestamp = workspace:GetServerTimeNow()

    Event:FireServer("FireProjectile", {
        Type = ProjectileType,
        Origin = Origin,
        Direction = Direction,
        Timestamp = Timestamp,
    })

    if World then
        World:cast({
            caster = LocalPlayer,
            type = ProjectileType,
            origin = Origin,
            direction = Direction,
            timestamp = Timestamp,
            visual = Visuals[ProjectileType],
        })
    end

    if ProjectileDebugController then
        ProjectileDebugController:RecordShot(ProjectileType, Origin, Direction)
    end
end

-- Cooked-fuse throw — used by ThrowableSpawn for grenades. CookElapsed is the
-- time the player held the pin out; the fuse on the server gets reduced to
-- (GRENADE_FUSE - CookElapsed).
function Controller:Throw(ProjectileType: string, Origin: Vector3, Direction: Vector3, CookElapsed: number)
    local Timestamp = workspace:GetServerTimeNow()
    local RemainingFuse = math.clamp(GRENADE_FUSE - CookElapsed, 0, GRENADE_FUSE)

    Event:FireServer("ThrowProjectile", {
        Type = ProjectileType,
        Origin = Origin,
        Direction = Direction,
        Timestamp = Timestamp,
        CookElapsed = CookElapsed,
    })

    if World then
        World:cast({
            caster = LocalPlayer,
            type = ProjectileType,
            origin = Origin,
            direction = Direction,
            timestamp = Timestamp,
            modifier = { lifetime = RemainingFuse },
            visual = Visuals[ProjectileType],
        })
    end

    if ProjectileDebugController then
        ProjectileDebugController:RecordShot(ProjectileType, Origin, Direction)
    end
end

return Controller
