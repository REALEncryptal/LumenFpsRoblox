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
    -- VisualOrigin/VisualDirection are present when the caster used dual-origin
    -- (tracer from muzzle); fall back to the hit-resolution ray otherwise.
    Event:Listen("ProjectileFired", function(Caster, ProjectileType, Origin, Direction, VisualOrigin, VisualDirection)
        if Caster == LocalPlayer then return end
        World:cast({
            caster = Caster,
            type = ProjectileType,
            origin = VisualOrigin or Origin,
            direction = VisualDirection or Direction,
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
--
-- Origin/Direction is the hit-resolution ray (typically camera-space — must
-- pass the server's head-proximity validation). VisualOrigin/VisualDirection
-- are the optional tracer-only override used for the two-ray dual-origin
-- pattern: keep aim accurate to the crosshair, but render the bullet leaving
-- the gun muzzle. Server broadcasts these so other clients render the same.
function Controller:Cast(
    ProjectileType: string,
    Origin: Vector3,
    Direction: Vector3,
    VisualOrigin: Vector3?,
    VisualDirection: Vector3?
)
    local Timestamp = workspace:GetServerTimeNow()
    local VisOrigin = VisualOrigin or Origin
    local VisDirection = VisualDirection or Direction

    Event:FireServer("FireProjectile", {
        Type = ProjectileType,
        Origin = Origin,
        Direction = Direction,
        VisualOrigin = VisualOrigin,
        VisualDirection = VisualDirection,
        Timestamp = Timestamp,
    })

    if World then
        World:cast({
            caster = LocalPlayer,
            type = ProjectileType,
            origin = VisOrigin,
            direction = VisDirection,
            timestamp = Timestamp,
            visual = Visuals[ProjectileType],
        })
    end

    if ProjectileDebugController then
        -- Debug overlay forward-simulates the *server's* trajectory, so feed it
        -- the hit-resolution ray (camera), not the muzzle visual.
        ProjectileDebugController:RecordShot(ProjectileType, Origin, Direction)
    end
end

-- Hitscan dispatch — Hindsight 0.2.0's single-frame ray resolver. Mirrors
-- :Cast's wire format so the server-side validation (origin proximity +
-- timestamp latency) is shared. Local World:hitscan runs the same ray on the
-- client world; only `onImpact` fires there (the client world has no rollback
-- store, so `onIntersection` is server-only by design).
--
-- Optional `Modifier` carries per-cast overrides (Range, Damage). The server
-- clamps both to defensive bounds before forwarding to Hindsight — the values
-- are useful for melee tools that share one Punch definition but want
-- per-tool reach/damage tuning. Damage rides on Hindsight's `extra` table;
-- the Punch projectile reads `Ctx.extra.Damage` on intersection.
--
-- ProjectileDebugController:RecordShot is intentionally skipped here — its
-- forward-simulator is keyed on velocity/gravity/lifetime, which are ignored
-- on the hitscan path. A dedicated RecordHitscan can be added later if the
-- debug overlay needs to draw single-segment rays.
function Controller:Hitscan(
    ProjectileType: string,
    Origin: Vector3,
    Direction: Vector3,
    Modifier: { Range: number?, Damage: number? }?
)
    local Timestamp = workspace:GetServerTimeNow()
    local Range = Modifier and Modifier.Range
    local Damage = Modifier and Modifier.Damage

    Event:FireServer("HitscanProjectile", {
        Type = ProjectileType,
        Origin = Origin,
        Direction = Direction,
        Timestamp = Timestamp,
        Range = Range,
        Damage = Damage,
    })

    if World then
        local LocalModifier = nil
        if Range or Damage then
            LocalModifier = {
                range = Range,
                extra = if Damage then { Damage = Damage } else nil,
            }
        end
        World:hitscan({
            caster = LocalPlayer,
            type = ProjectileType,
            origin = Origin,
            direction = Direction,
            timestamp = Timestamp,
            modifier = LocalModifier,
        })
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
