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

local Hindsight, Event
local World
local BulletsFolder: Instance
local CharactersFolder: Instance

function Controller:Init()
    Hindsight = shared.Import("Hindsight")
    Event = shared.Import("Event")

    BulletsFolder = workspace:WaitForChild("Bullets")
    CharactersFolder = workspace:WaitForChild("Characters")

    local definitionsModule = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Projectiles")

    local raycastFilter = RaycastParams.new()
    raycastFilter.FilterType = Enum.RaycastFilterType.Exclude
    raycastFilter.FilterDescendantsInstances = { CharactersFolder, BulletsFolder }

    World = Hindsight.createWorld({
        actorContainer = LocalPlayer:WaitForChild("PlayerScripts"),
        definitionsModule = definitionsModule,
        visualsContainer = BulletsFolder,
        excludeContainers = { BulletsFolder, CharactersFolder },
        defaultRaycastFilter = raycastFilter,
    })

    -- Render other players' shots locally. The caster runs its own visual cast
    -- before sending to the server, so it skips its own broadcasted echo.
    Event:Listen("ProjectileFired", function(caster, projectileType, origin, direction)
        if caster == LocalPlayer then return end
        World:cast({
            caster = caster,
            type = projectileType,
            origin = origin,
            direction = direction,
            timestamp = workspace:GetServerTimeNow(),
        })
    end)

    Event:Listen("ProjectileThrown", function(caster, projectileType, origin, direction, remainingFuse)
        if caster == LocalPlayer then return end
        World:cast({
            caster = caster,
            type = projectileType,
            origin = origin,
            direction = direction,
            timestamp = workspace:GetServerTimeNow(),
            modifier = { lifetime = remainingFuse },
        })
    end)
end

-- Hitscan/projectile fire — used by HitscanFire-style components.
function Controller:Cast(projectileType: string, origin: Vector3, direction: Vector3)
    local timestamp = workspace:GetServerTimeNow()

    Event:FireServer("FireProjectile", {
        type = projectileType,
        origin = origin,
        direction = direction,
        timestamp = timestamp,
    })

    if World then
        World:cast({
            caster = LocalPlayer,
            type = projectileType,
            origin = origin,
            direction = direction,
            timestamp = timestamp,
        })
    end
end

-- Cooked-fuse throw — used by ThrowableSpawn for grenades. cookElapsed is the
-- time the player held the pin out; the fuse on the server gets reduced to
-- (GRENADE_FUSE - cookElapsed).
function Controller:Throw(projectileType: string, origin: Vector3, direction: Vector3, cookElapsed: number)
    local timestamp = workspace:GetServerTimeNow()
    local remainingFuse = math.clamp(GRENADE_FUSE - cookElapsed, 0, GRENADE_FUSE)

    Event:FireServer("ThrowProjectile", {
        type = projectileType,
        origin = origin,
        direction = direction,
        timestamp = timestamp,
        cookElapsed = cookElapsed,
    })

    if World then
        World:cast({
            caster = LocalPlayer,
            type = projectileType,
            origin = origin,
            direction = direction,
            timestamp = timestamp,
            modifier = { lifetime = remainingFuse },
        })
    end
end

return Controller
