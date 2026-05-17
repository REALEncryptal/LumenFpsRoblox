--[[
    ProjectileDebugController

    Iris/ImGizmo debug overlay for Hindsight casts. Mirrors MovementController's
    debug-panel pattern: an Iris window with master + per-feature toggles, plus
    a per-frame ImGizmo render of recorded shots that fades with age.

    The hook is ProjectileController:Cast() / :Throw() — they call
    `:RecordShot(...)` after dispatching to Hindsight. The controller then
    forward-simulates the shot itself (same projectile def, same world raycast
    filter, plus a parallel Characters-folder raycast for intersections) so the
    visualization shows the path Hindsight will take without needing to plumb
    callbacks back across actor VMs.

    Forward-sim faithfulness:
      - Step size matches Hindsight's tick (one PostSimulation per slice).
      - Kinematics uses x = x0 + v*t + 0.5*g*t^2 like the library.
      - World raycast uses the same raycastFilter the client world is wired with.
      - Ricochet decision copies Penetration.tryRicochet's comparison verbatim.
      - Penetration cost = configured surface hardness (compound is approximated
        as a single part — good enough for thin walls; doesn't merge touching
        parts the way Hindsight does).
      - Character intersection uses a separate Include-only raycast against the
        Characters folder so we can show "this shot would have hit X" before
        the server's authoritative rollback query confirms.
]]

local Controller = {
    Priority = 5,
    Signals = {},
}

local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer

-- Forward-sim tuning
local SIM_DT = 1 / 60                       -- step matches Hindsight's default PostSimulation cadence
local MAX_SIM_STEPS = 600                   -- hard cap so a misconfigured projectile can't lock the panel
local PENETRATION_PROBE_EPSILON = 1e-3      -- nudge past the entry surface before tracing for the exit
local PENETRATION_PROBE_MAX = 8             -- max consecutive penetrations recorded per shot

-- Visualization
local SHOT_LIFETIME = 5                     -- seconds before a shot is pruned from the history
local MAX_SHOTS = 32                        -- hard cap on simultaneously rendered shots
local IMPACT_SPHERE_RADIUS = 0.12
local HIT_SPHERE_RADIUS = 0.18
local EXIT_SPHERE_RADIUS = 0.1
local SPHERE_SUBDIVISIONS = 8
local PATH_RADIUS = 0.04                    -- arrow radius for path segments
local PATH_ARROW_HEAD = 0.16

local FULL_CIRCLE = math.pi * 2

local ImGizmo, Iris, Hindsight, Projectiles

-- Ring-style list of recorded shots. New shots append; expired shots removed in Update.
local Shots: { Shot } = {}

type ImpactRecord = {
    Position: Vector3,
    Normal: Vector3,
    Ricochet: boolean,
    PenetrationExit: Vector3?, -- nil if the projectile stopped at this impact
}

type HitRecord = {
    Position: Vector3,
    Character: Model,
    Part: string,
}

type Shot = {
    Type: string,
    Origin: Vector3,
    Direction: Vector3,
    RecordedAt: number,         -- os.clock() at record time, used for fade
    Segments: { Vector3 },      -- polyline points; pairs (i, i+1) are drawn as a segment
    Impacts: { ImpactRecord },
    Hits: { HitRecord },
    EndPosition: Vector3,       -- where the projectile stopped (out of power, hit char, lifetime, etc.)
}

function Controller:Init()
    ImGizmo = shared.Import("ImGizmo")
    Iris = shared.Import("Iris")
    Hindsight = shared.Import("Hindsight")
    Projectiles = shared.Import("Projectiles")

    Controller._Debug = false
    Controller._ShowPath = true
    Controller._ShowImpacts = true
    Controller._ShowPenetrations = true
    Controller._ShowHits = true

    Iris:Connect(function()
        local windowSize = Iris.State(Vector2.new(220, 240))
        local windowPos = Iris.State(Vector2.new(500, 0))
        local debugState = Iris.State(false)
        local pathState = Iris.State(true)
        local impactState = Iris.State(true)
        local penetrationState = Iris.State(true)
        local hitState = Iris.State(true)

        Iris.Window({"Hindsight Debug"}, {size = windowSize, position = windowPos})

        Iris.Checkbox({"Debug Enabled"}, {isChecked = debugState})
        Iris.Checkbox({"Path"}, {isChecked = pathState})
        Iris.Checkbox({"Impacts"}, {isChecked = impactState})
        Iris.Checkbox({"Penetrations + Exits"}, {isChecked = penetrationState})
        Iris.Checkbox({"Hits"}, {isChecked = hitState})

        Iris.SeparatorText({"Live"})
        Iris.Text({string.format("Recorded shots: %d", #Shots)})

        Controller._Debug = debugState.value
        Controller._ShowPath = pathState.value
        Controller._ShowImpacts = impactState.value
        Controller._ShowPenetrations = penetrationState.value
        Controller._ShowHits = hitState.value

        Iris.End()
    end)
end

-- Hindsight's `state.angle >= surfaceAngle` ricochet test, lifted verbatim so
-- the debug sim matches what the real projectile does. `angleRad` is the
-- definition's angle field already in radians.
local function tryRicochet(angleRad: number, unitDirection: Vector3, normal: Vector3, hardness: number, ricochetHardness: number): boolean
    local alwaysBounces = angleRad == FULL_CIRCLE
    local surfaceAngle = math.acos(math.clamp(unitDirection:Dot(normal.Unit), -1, 1))
    local steepEnoughHardEnough = angleRad >= surfaceAngle and hardness >= ricochetHardness
    return alwaysBounces or steepEnoughHardEnough
end

-- Find the back-face of `entryPart` along `direction` starting from `entryPosition`.
-- Returns the exit position, or nil if no back-face is found within a reasonable
-- distance (e.g. terrain or a part bigger than the probe).
local function findPenetrationExit(entryPart: BasePart, entryPosition: Vector3, direction: Vector3): Vector3?
    local probeOrigin = entryPosition + direction * PENETRATION_PROBE_EPSILON
    local probeLength = math.max(entryPart.Size.Magnitude * 2, 4)
    local include = RaycastParams.new()
    include.FilterType = Enum.RaycastFilterType.Include
    include.FilterDescendantsInstances = { entryPart }
    -- Cast from BEYOND the part backwards. Same trick as Hindsight's
    -- Penetration.computeCompound — guarantees we hit the back face even if
    -- the original entry raycast started inside the part's AABB.
    local reverseOrigin = probeOrigin + direction * probeLength
    local reverseResult = workspace:Raycast(reverseOrigin, -direction * probeLength, include)
    if reverseResult then
        return reverseResult.Position
    end
    return nil
end

-- Walks the projectile through the world tick-by-tick, recording every world
-- impact (with ricochet/penetration outcome) and every character intersection
-- along the way. Returns a populated Shot record.
local function simulateShot(projectileType: string, origin: Vector3, direction: Vector3): Shot?
    local definitions = Projectiles
    local definition = definitions and definitions[projectileType]
    if not definition then
        return nil
    end

    local penetrationConfig = Hindsight.Defaults.penetration

    -- Resolved lazily — the Characters and Bullets folders are created by the
    -- server's ProjectileController and may not exist when this controller
    -- inits at priority 5.
    local charactersFolder = workspace:FindFirstChild("Characters")
    local bulletsFolder = workspace:FindFirstChild("Bullets")

    local shot: Shot = {
        Type = projectileType,
        Origin = origin,
        Direction = direction,
        RecordedAt = os.clock(),
        Segments = { origin },
        Impacts = {},
        Hits = {},
        EndPosition = origin,
    }

    local angleRad = math.rad(definition.angle)
    local speed = definition.velocity
    local gravity = definition.gravity
    local lifetime = definition.lifetime
    local power = definition.power
    local loss = definition.loss
    local collaterals = definition.collaterals == true

    local position = origin
    local velocity = direction.Unit * speed
    local elapsed = 0
    local penetrationCount = 0

    -- Mutable copy of the raycast filter so penetrations can add the entry
    -- part to it (mirroring how Hindsight's `raycastFilter:AddToFilter` keeps
    -- the next forward raycast from re-hitting the part we just punched).
    -- Mirrors the client ProjectileController's filter — characters and
    -- bullets folders excluded.
    local raycastFilter = RaycastParams.new()
    raycastFilter.FilterType = Enum.RaycastFilterType.Exclude
    raycastFilter.IgnoreWater = true
    local excludes = {}
    if charactersFolder then table.insert(excludes, charactersFolder) end
    if bulletsFolder then table.insert(excludes, bulletsFolder) end
    raycastFilter.FilterDescendantsInstances = excludes

    -- Include filter for character intersections — Characters folder only.
    local charactersFilter: RaycastParams? = nil
    if charactersFolder then
        charactersFilter = RaycastParams.new()
        charactersFilter.FilterType = Enum.RaycastFilterType.Include
        charactersFilter.FilterDescendantsInstances = { charactersFolder }
    end

    for _ = 1, MAX_SIM_STEPS do
        if elapsed >= lifetime then break end

        local dt = math.min(SIM_DT, lifetime - elapsed)
        elapsed += dt

        local newPosition = position + velocity * dt + 0.5 * gravity * dt * dt
        local segment = newPosition - position
        if segment.Magnitude < 1e-6 then break end

        local worldResult = workspace:Raycast(position, segment, raycastFilter)

        -- Character intersection — separate Include cast against Characters
        -- folder. Filter out the caster's character to match defaultFilter in
        -- Projectiles.luau.
        local charHit: HitRecord? = nil
        local charDistance = math.huge
        if charactersFilter then
            local charResult = workspace:Raycast(position, segment, charactersFilter)
            if charResult then
                local character = charResult.Instance:FindFirstAncestorOfClass("Model")
                local casterCharacter = LocalPlayer.Character
                if character and character ~= casterCharacter then
                    charHit = {
                        Position = charResult.Position,
                        Character = character,
                        Part = charResult.Instance.Name,
                    }
                    charDistance = charResult.Distance
                end
            end
        end

        local worldDistance = worldResult and worldResult.Distance or math.huge

        -- Resolve whichever came first along the segment.
        if charHit and charDistance <= worldDistance then
            table.insert(shot.Segments, charHit.Position)
            table.insert(shot.Hits, charHit)
            shot.EndPosition = charHit.Position
            if not collaterals then return shot end
            position = charHit.Position
            velocity = velocity + gravity * dt
            continue
        end

        if not worldResult then
            position = newPosition
            velocity = velocity + gravity * dt
            continue
        end

        local impactPos = worldResult.Position
        local normal = worldResult.Normal
        local unitDir = segment.Unit
        local hardness = penetrationConfig.surfaceHardness[worldResult.Material] or penetrationConfig.defaultHardness

        if tryRicochet(angleRad, unitDir, normal, hardness, penetrationConfig.ricochetHardness) then
            -- Mutate speed + velocity per Hindsight's Penetration.tryRicochet.
            speed = math.max(0, speed - loss)
            local reflected = (unitDir - 2 * unitDir:Dot(normal) * normal).Unit * speed
            velocity = reflected
            table.insert(shot.Segments, impactPos)
            table.insert(shot.Impacts, {
                Position = impactPos,
                Normal = normal,
                Ricochet = true,
                PenetrationExit = nil,
            })
            shot.EndPosition = impactPos
            position = impactPos
            continue
        end

        -- Try to penetrate. Compound cost = single-part hardness (simplification).
        if power >= hardness and penetrationCount < PENETRATION_PROBE_MAX then
            local entryPart = worldResult.Instance
            local exit = findPenetrationExit(entryPart, impactPos, unitDir)
            if exit then
                power -= hardness
                penetrationCount += 1
                table.insert(shot.Segments, impactPos)
                table.insert(shot.Segments, exit)
                table.insert(shot.Impacts, {
                    Position = impactPos,
                    Normal = normal,
                    Ricochet = false,
                    PenetrationExit = exit,
                })
                -- Add the punched part to the filter so the next tick's
                -- forward raycast doesn't re-hit it (it would, since the
                -- projectile is now mid-part and continuing).
                raycastFilter:AddToFilter(entryPart)
                shot.EndPosition = exit
                position = exit + unitDir * PENETRATION_PROBE_EPSILON
                velocity = velocity + gravity * dt
                continue
            end
        end

        -- Power exhausted or no exit found — projectile stops here.
        table.insert(shot.Segments, impactPos)
        table.insert(shot.Impacts, {
            Position = impactPos,
            Normal = normal,
            Ricochet = false,
            PenetrationExit = nil,
        })
        shot.EndPosition = impactPos
        return shot
    end

    -- Lifetime expired or step cap hit — close the polyline at the last position.
    if #shot.Segments == 0 or shot.Segments[#shot.Segments] ~= position then
        table.insert(shot.Segments, position)
    end
    shot.EndPosition = position
    return shot
end

-- Public hook for ProjectileController. Called after every successful local
-- cast/throw. No-op when the debug master toggle is off so the forward-sim
-- cost doesn't run in normal play.
function Controller:RecordShot(projectileType: string, origin: Vector3, direction: Vector3)
    if not Controller._Debug then return end
    if not Projectiles then return end

    local shot = simulateShot(projectileType, origin, direction)
    if not shot then return end

    table.insert(Shots, shot)
    while #Shots > MAX_SHOTS do
        table.remove(Shots, 1)
    end
end

function Controller.Signals.Update(_dt: number)
    if not Controller._Debug or #Shots == 0 then return end

    local now = os.clock()
    -- Prune in place from the front (shots are appended in time order).
    while #Shots > 0 and (now - Shots[1].RecordedAt) > SHOT_LIFETIME do
        table.remove(Shots, 1)
    end

    for _, shot in Shots do
        local age = now - shot.RecordedAt
        local alpha = math.clamp(1 - age / SHOT_LIFETIME, 0.05, 1)

        if Controller._ShowPath and #shot.Segments >= 2 then
            ImGizmo.PushProperty("Color3", Color3.new(1 * alpha, 1 * alpha, 0.3 * alpha))
            for i = 1, #shot.Segments - 1 do
                local a, b = shot.Segments[i], shot.Segments[i + 1]
                if (b - a).Magnitude > 1e-3 then
                    ImGizmo.Arrow:Draw(a, b, PATH_RADIUS, PATH_ARROW_HEAD, 8)
                end
            end
        end

        if Controller._ShowImpacts then
            for _, impact in shot.Impacts do
                if impact.Ricochet then
                    -- Ricochet: cyan sphere + normal arrow.
                    ImGizmo.PushProperty("Color3", Color3.new(0.3 * alpha, alpha, alpha))
                    ImGizmo.Sphere:Draw(CFrame.new(impact.Position), IMPACT_SPHERE_RADIUS, SPHERE_SUBDIVISIONS, 360)
                else
                    -- Non-penetrating world impact: white sphere.
                    ImGizmo.PushProperty("Color3", Color3.new(alpha, alpha, alpha))
                    ImGizmo.Sphere:Draw(CFrame.new(impact.Position), IMPACT_SPHERE_RADIUS, SPHERE_SUBDIVISIONS, 360)
                end
                ImGizmo.PushProperty("Color3", Color3.new(alpha, 0.4 * alpha, 0.1 * alpha))
                ImGizmo.Arrow:Draw(impact.Position, impact.Position + impact.Normal * 0.6, 0.04, 0.14, 8)
            end
        end

        if Controller._ShowPenetrations then
            for _, impact in shot.Impacts do
                if impact.PenetrationExit then
                    -- Entry: orange sphere. Exit: bright orange sphere.
                    ImGizmo.PushProperty("Color3", Color3.new(alpha, 0.5 * alpha, 0.1 * alpha))
                    ImGizmo.Sphere:Draw(CFrame.new(impact.Position), IMPACT_SPHERE_RADIUS, SPHERE_SUBDIVISIONS, 360)
                    ImGizmo.PushProperty("Color3", Color3.new(alpha, 0.8 * alpha, 0.2 * alpha))
                    ImGizmo.Sphere:Draw(CFrame.new(impact.PenetrationExit), EXIT_SPHERE_RADIUS, SPHERE_SUBDIVISIONS, 360)
                end
            end
        end

        if Controller._ShowHits then
            for _, hit in shot.Hits do
                ImGizmo.PushProperty("Color3", Color3.new(alpha, 0.1 * alpha, 0.1 * alpha))
                ImGizmo.Sphere:Draw(CFrame.new(hit.Position), HIT_SPHERE_RADIUS, SPHERE_SUBDIVISIONS, 360)
            end
        end
    end
end

return Controller
