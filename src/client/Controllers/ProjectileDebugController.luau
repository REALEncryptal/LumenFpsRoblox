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
    Segments: { Vector3 },      -- polyline points; pairs (I, I+1) are drawn as a segment
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
        local WindowSize = Iris.State(Vector2.new(220, 240))
        local WindowPos = Iris.State(Vector2.new(500, 0))
        local DebugState = Iris.State(false)
        local PathState = Iris.State(true)
        local ImpactState = Iris.State(true)
        local PenetrationState = Iris.State(true)
        local HitState = Iris.State(true)

        Iris.Window({"Hindsight Debug"}, {size = WindowSize, position = WindowPos})

        Iris.Checkbox({"Debug Enabled"}, {isChecked = DebugState})
        Iris.Checkbox({"Path"}, {isChecked = PathState})
        Iris.Checkbox({"Impacts"}, {isChecked = ImpactState})
        Iris.Checkbox({"Penetrations + Exits"}, {isChecked = PenetrationState})
        Iris.Checkbox({"Hits"}, {isChecked = HitState})

        Iris.SeparatorText({"Live"})
        Iris.Text({string.format("Recorded shots: %d", #Shots)})

        Controller._Debug = DebugState.value
        Controller._ShowPath = PathState.value
        Controller._ShowImpacts = ImpactState.value
        Controller._ShowPenetrations = PenetrationState.value
        Controller._ShowHits = HitState.value

        Iris.End()
    end)
end

-- Hindsight's `state.angle >= surfaceAngle` ricochet test, lifted verbatim so
-- the debug sim matches what the real projectile does. `AngleRad` is the
-- definition's angle field already in radians.
local function TryRicochet(AngleRad: number, UnitDirection: Vector3, Normal: Vector3, Hardness: number, RicochetHardness: number): boolean
    local AlwaysBounces = AngleRad == FULL_CIRCLE
    local SurfaceAngle = math.acos(math.clamp(UnitDirection:Dot(Normal.Unit), -1, 1))
    local SteepEnoughHardEnough = AngleRad >= SurfaceAngle and Hardness >= RicochetHardness
    return AlwaysBounces or SteepEnoughHardEnough
end

-- Find the back-face of `EntryPart` along `Direction` starting from `EntryPosition`.
-- Returns the exit position, or nil if no back-face is found within a reasonable
-- distance (e.g. terrain or a part bigger than the probe).
local function FindPenetrationExit(EntryPart: BasePart, EntryPosition: Vector3, Direction: Vector3): Vector3?
    local ProbeOrigin = EntryPosition + Direction * PENETRATION_PROBE_EPSILON
    local ProbeLength = math.max(EntryPart.Size.Magnitude * 2, 4)
    local Include = RaycastParams.new()
    Include.FilterType = Enum.RaycastFilterType.Include
    Include.FilterDescendantsInstances = { EntryPart }
    -- Cast from BEYOND the part backwards. Same trick as Hindsight's
    -- Penetration.computeCompound — guarantees we hit the back face even if
    -- the original entry raycast started inside the part's AABB.
    local ReverseOrigin = ProbeOrigin + Direction * ProbeLength
    local ReverseResult = workspace:Raycast(ReverseOrigin, -Direction * ProbeLength, Include)
    if ReverseResult then
        return ReverseResult.Position
    end
    return nil
end

-- Walks the projectile through the world tick-by-tick, recording every world
-- impact (with ricochet/penetration outcome) and every character intersection
-- along the way. Returns a populated Shot record.
local function SimulateShot(ProjectileType: string, Origin: Vector3, Direction: Vector3): Shot?
    local Definitions = Projectiles
    local Definition = Definitions and Definitions[ProjectileType]
    if not Definition then
        return nil
    end

    local PenetrationConfig = Hindsight.Defaults.penetration

    -- Resolved lazily — the Characters and Bullets folders are created by the
    -- server's ProjectileController and may not exist when this controller
    -- inits at priority 5.
    local CharactersFolder = workspace:FindFirstChild("Characters")
    local BulletsFolder = workspace:FindFirstChild("Bullets")

    local Shot: Shot = {
        Type = ProjectileType,
        Origin = Origin,
        Direction = Direction,
        RecordedAt = os.clock(),
        Segments = { Origin },
        Impacts = {},
        Hits = {},
        EndPosition = Origin,
    }

    local AngleRad = math.rad(Definition.angle)
    local Speed = Definition.velocity
    local Gravity = Definition.gravity
    local Lifetime = Definition.lifetime
    local Power = Definition.power
    local Loss = Definition.loss
    local Collaterals = Definition.collaterals == true

    local Position = Origin
    local Velocity = Direction.Unit * Speed
    local Elapsed = 0
    local PenetrationCount = 0

    -- Mutable copy of the raycast filter so penetrations can add the entry
    -- part to it (mirroring how Hindsight's `raycastFilter:AddToFilter` keeps
    -- the next forward raycast from re-hitting the part we just punched).
    -- Mirrors the client ProjectileController's filter — characters and
    -- bullets folders excluded.
    local RaycastFilter = RaycastParams.new()
    RaycastFilter.FilterType = Enum.RaycastFilterType.Exclude
    RaycastFilter.IgnoreWater = true
    local Excludes = {}
    if CharactersFolder then table.insert(Excludes, CharactersFolder) end
    if BulletsFolder then table.insert(Excludes, BulletsFolder) end
    RaycastFilter.FilterDescendantsInstances = Excludes

    -- Include filter for character intersections — Characters folder only.
    local CharactersFilter: RaycastParams? = nil
    if CharactersFolder then
        CharactersFilter = RaycastParams.new()
        CharactersFilter.FilterType = Enum.RaycastFilterType.Include
        CharactersFilter.FilterDescendantsInstances = { CharactersFolder }
    end

    for _ = 1, MAX_SIM_STEPS do
        if Elapsed >= Lifetime then break end

        local Dt = math.min(SIM_DT, Lifetime - Elapsed)
        Elapsed += Dt

        local NewPosition = Position + Velocity * Dt + 0.5 * Gravity * Dt * Dt
        local Segment = NewPosition - Position
        if Segment.Magnitude < 1e-6 then break end

        local WorldResult = workspace:Raycast(Position, Segment, RaycastFilter)

        -- Character intersection — separate Include cast against Characters
        -- folder. Filter out the caster's character to match defaultFilter in
        -- Projectiles.luau.
        local CharHit: HitRecord? = nil
        local CharDistance = math.huge
        if CharactersFilter then
            local CharResult = workspace:Raycast(Position, Segment, CharactersFilter)
            if CharResult then
                local Character = CharResult.Instance:FindFirstAncestorOfClass("Model")
                local CasterCharacter = LocalPlayer.Character
                if Character and Character ~= CasterCharacter then
                    CharHit = {
                        Position = CharResult.Position,
                        Character = Character,
                        Part = CharResult.Instance.Name,
                    }
                    CharDistance = CharResult.Distance
                end
            end
        end

        local WorldDistance = WorldResult and WorldResult.Distance or math.huge

        -- Resolve whichever came first along the segment.
        if CharHit and CharDistance <= WorldDistance then
            table.insert(Shot.Segments, CharHit.Position)
            table.insert(Shot.Hits, CharHit)
            Shot.EndPosition = CharHit.Position
            if not Collaterals then return Shot end
            Position = CharHit.Position
            Velocity = Velocity + Gravity * Dt
            continue
        end

        if not WorldResult then
            Position = NewPosition
            Velocity = Velocity + Gravity * Dt
            continue
        end

        local ImpactPos = WorldResult.Position
        local Normal = WorldResult.Normal
        local UnitDir = Segment.Unit
        local Hardness = PenetrationConfig.surfaceHardness[WorldResult.Material] or PenetrationConfig.defaultHardness

        if TryRicochet(AngleRad, UnitDir, Normal, Hardness, PenetrationConfig.ricochetHardness) then
            -- Mutate speed + velocity per Hindsight's Penetration.tryRicochet.
            Speed = math.max(0, Speed - Loss)
            local Reflected = (UnitDir - 2 * UnitDir:Dot(Normal) * Normal).Unit * Speed
            Velocity = Reflected
            table.insert(Shot.Segments, ImpactPos)
            table.insert(Shot.Impacts, {
                Position = ImpactPos,
                Normal = Normal,
                Ricochet = true,
                PenetrationExit = nil,
            })
            Shot.EndPosition = ImpactPos
            Position = ImpactPos
            continue
        end

        -- Try to penetrate. Compound cost = single-part hardness (simplification).
        if Power >= Hardness and PenetrationCount < PENETRATION_PROBE_MAX then
            local EntryPart = WorldResult.Instance
            local Exit = FindPenetrationExit(EntryPart, ImpactPos, UnitDir)
            if Exit then
                Power -= Hardness
                PenetrationCount += 1
                table.insert(Shot.Segments, ImpactPos)
                table.insert(Shot.Segments, Exit)
                table.insert(Shot.Impacts, {
                    Position = ImpactPos,
                    Normal = Normal,
                    Ricochet = false,
                    PenetrationExit = Exit,
                })
                -- Add the punched part to the filter so the next tick's
                -- forward raycast doesn't re-hit it (it would, since the
                -- projectile is now mid-part and continuing).
                RaycastFilter:AddToFilter(EntryPart)
                Shot.EndPosition = Exit
                Position = Exit + UnitDir * PENETRATION_PROBE_EPSILON
                Velocity = Velocity + Gravity * Dt
                continue
            end
        end

        -- Power exhausted or no exit found — projectile stops here.
        table.insert(Shot.Segments, ImpactPos)
        table.insert(Shot.Impacts, {
            Position = ImpactPos,
            Normal = Normal,
            Ricochet = false,
            PenetrationExit = nil,
        })
        Shot.EndPosition = ImpactPos
        return Shot
    end

    -- Lifetime expired or step cap hit — close the polyline at the last position.
    if #Shot.Segments == 0 or Shot.Segments[#Shot.Segments] ~= Position then
        table.insert(Shot.Segments, Position)
    end
    Shot.EndPosition = Position
    return Shot
end

-- Public hook for ProjectileController. Called after every successful local
-- cast/throw. No-op when the debug master toggle is off so the forward-sim
-- cost doesn't run in normal play.
function Controller:RecordShot(ProjectileType: string, Origin: Vector3, Direction: Vector3)
    if not Controller._Debug then return end
    if not Projectiles then return end

    local Shot = SimulateShot(ProjectileType, Origin, Direction)
    if not Shot then return end

    table.insert(Shots, Shot)
    while #Shots > MAX_SHOTS do
        table.remove(Shots, 1)
    end
end

function Controller.Signals.Update(_Dt: number)
    if not Controller._Debug or #Shots == 0 then return end

    local Now = os.clock()
    -- Prune in place from the front (shots are appended in time order).
    while #Shots > 0 and (Now - Shots[1].RecordedAt) > SHOT_LIFETIME do
        table.remove(Shots, 1)
    end

    for _, Shot in Shots do
        local Age = Now - Shot.RecordedAt
        local Alpha = math.clamp(1 - Age / SHOT_LIFETIME, 0.05, 1)

        if Controller._ShowPath and #Shot.Segments >= 2 then
            ImGizmo.PushProperty("Color3", Color3.new(1 * Alpha, 1 * Alpha, 0.3 * Alpha))
            for I = 1, #Shot.Segments - 1 do
                local A, B = Shot.Segments[I], Shot.Segments[I + 1]
                if (B - A).Magnitude > 1e-3 then
                    ImGizmo.Arrow:Draw(A, B, PATH_RADIUS, PATH_ARROW_HEAD, 8)
                end
            end
        end

        if Controller._ShowImpacts then
            for _, Impact in Shot.Impacts do
                if Impact.Ricochet then
                    -- Ricochet: cyan sphere + normal arrow.
                    ImGizmo.PushProperty("Color3", Color3.new(0.3 * Alpha, Alpha, Alpha))
                    ImGizmo.Sphere:Draw(CFrame.new(Impact.Position), IMPACT_SPHERE_RADIUS, SPHERE_SUBDIVISIONS, 360)
                else
                    -- Non-penetrating world impact: white sphere.
                    ImGizmo.PushProperty("Color3", Color3.new(Alpha, Alpha, Alpha))
                    ImGizmo.Sphere:Draw(CFrame.new(Impact.Position), IMPACT_SPHERE_RADIUS, SPHERE_SUBDIVISIONS, 360)
                end
                ImGizmo.PushProperty("Color3", Color3.new(Alpha, 0.4 * Alpha, 0.1 * Alpha))
                ImGizmo.Arrow:Draw(Impact.Position, Impact.Position + Impact.Normal * 0.6, 0.04, 0.14, 8)
            end
        end

        if Controller._ShowPenetrations then
            for _, Impact in Shot.Impacts do
                if Impact.PenetrationExit then
                    -- Entry: orange sphere. Exit: bright orange sphere.
                    ImGizmo.PushProperty("Color3", Color3.new(Alpha, 0.5 * Alpha, 0.1 * Alpha))
                    ImGizmo.Sphere:Draw(CFrame.new(Impact.Position), IMPACT_SPHERE_RADIUS, SPHERE_SUBDIVISIONS, 360)
                    ImGizmo.PushProperty("Color3", Color3.new(Alpha, 0.8 * Alpha, 0.2 * Alpha))
                    ImGizmo.Sphere:Draw(CFrame.new(Impact.PenetrationExit), EXIT_SPHERE_RADIUS, SPHERE_SUBDIVISIONS, 360)
                end
            end
        end

        if Controller._ShowHits then
            for _, Hit in Shot.Hits do
                ImGizmo.PushProperty("Color3", Color3.new(Alpha, 0.1 * Alpha, 0.1 * Alpha))
                ImGizmo.Sphere:Draw(CFrame.new(Hit.Position), HIT_SPHERE_RADIUS, SPHERE_SUBDIVISIONS, 360)
            end
        end
    end
end

return Controller
