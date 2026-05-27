--!strict

-- Hindsight projectile definitions. Both the main thread and every simulation
-- actor require this module independently, which is why callbacks live here
-- (functions cannot cross actor VM boundaries via the per-cast Modifier).

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Hindsight = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Hindsight"))

local IS_SERVER = RunService:IsServer()

local CharactersFolderName = "Characters"

-- Flip to false to silence the per-punch contact markers without otherwise
-- changing punch behavior. Replicated through normal FE replication so the
-- caster (and anyone else) can see where the swing landed.
local DEBUG_PUNCH_MARKERS = true

local function SpawnPunchMarker(Position: Vector3, Color: Color3)
    local Part = Instance.new("Part")
    Part.Name = "PunchDebug"
    Part.Size = Vector3.new(0.5, 0.5, 0.5)
    Part.Shape = Enum.PartType.Ball
    Part.Material = Enum.Material.Neon
    Part.Color = Color
    Part.Anchored = true
    Part.CanCollide = false
    Part.CanQuery = false
    Part.CanTouch = false
    Part.CastShadow = false
    Part.Position = Position
    Part.Parent = workspace
    Debris:AddItem(Part, 2)
end

-- Skip the caster and (later) teammates. Runs on a simulation actor in parallel
-- context — read-only access only, no Humanoid state inspection.
local function DefaultFilter(
    Caster: Hindsight.Caster,
    Victim: Player?,
    Character: Model,
    _Extra: Hindsight.Extra
): boolean
    if Victim == Caster or Character == Caster then
        return true
    end
    return false
end

local function ApplyDamage(Humanoid: Humanoid, Amount: number)
    if not Humanoid or Humanoid.Health <= 0 then return end
    Humanoid:TakeDamage(Amount)
end

local Bullet: Hindsight.ProjectileDefinition = {
    velocity = 1000,
    gravity = Vector3.zero,
    lifetime = 3,
    power = 50,
    angle = 20,
    loss = 0,
    collaterals = false,
    filter = DefaultFilter,
    onImpact = function(_Ctx) end,
    onIntersection = function(Ctx)
        if not IS_SERVER then return end
        local Humanoid = Ctx.character:FindFirstChildOfClass("Humanoid")
        if Humanoid then
            ApplyDamage(Humanoid, 25)
        end
    end,
    onDestroyed = function(_Ctx) end,
}

local GRENADE_RADIUS = 14
local GRENADE_MAX_DAMAGE = 90

local Grenade: Hindsight.ProjectileDefinition = {
    velocity = 50,
    gravity = Vector3.new(0, -50, 0),
    lifetime = 5, -- overridden per-cast via modifier.lifetime once cooking is wired up
    power = 9999, -- treat every surface as a ricochet, never absorbed
    angle = 89,
    loss = 0.55,
    collaterals = false,
    filter = DefaultFilter,
    onImpact = function(_Ctx)
        -- Bouncing handled by ricochet (angle/loss). No-op here so the projectile
        -- keeps living until its fuse runs out.
    end,
    onIntersection = function(_Ctx)
        -- Grenades don't damage on touch; only on fuse expiry via onDestroyed.
    end,
    onDestroyed = function(Ctx)
        -- Server applies the damage AoE and spawns the Explosion. The visual
        -- replicates to every client automatically; if the client cast its own
        -- visual world copy too, gating here prevents a double-blast for the
        -- caster.
        if not IS_SERVER then return end

        local CharactersFolder = workspace:FindFirstChild(CharactersFolderName)
        if CharactersFolder then
            for _, Character in ipairs(CharactersFolder:GetChildren()) do
                if not Character:IsA("Model") then continue end
                local Root = Character:FindFirstChild("HumanoidRootPart") or Character.PrimaryPart
                local Humanoid = Character:FindFirstChildOfClass("Humanoid")
                if not (Root and Root:IsA("BasePart") and Humanoid) then continue end

                local Distance = (Root.Position - Ctx.position).Magnitude
                if Distance > GRENADE_RADIUS then continue end

                local Falloff = 1 - (Distance / GRENADE_RADIUS)
                ApplyDamage(Humanoid, GRENADE_MAX_DAMAGE * Falloff)
            end
        end

        local Explosion = Instance.new("Explosion")
        Explosion.Position = Ctx.position
        Explosion.BlastRadius = GRENADE_RADIUS
        Explosion.BlastPressure = 0
        Explosion.DestroyJointRadiusPercent = 0
        Explosion.Parent = workspace
    end,
}

-- Punch hitscan. Resolved by Hindsight 0.2.0's World:hitscan (single-frame,
-- lag-compensated ray) — velocity/gravity/lifetime are present to satisfy the
-- ProjectileDefinition shape but are ignored on the hitscan path. `range`
-- caps the scan distance in studs. `angle = 0` disables ricochet so a missed
-- punch terminates at the first surface instead of bouncing through 16
-- iterations. `power = 0` disables penetration — every surface costs at
-- least `thickness × hardness > 0`, so the first hit always fires onImpact
-- and stops the scan (melee shouldn't punch through walls).
local Punch: Hindsight.ProjectileDefinition = {
    velocity = 0,
    gravity = Vector3.zero,
    lifetime = 0,
    power = 0,
    angle = 0,
    loss = 0,
    range = 8,
    collaterals = false,
    filter = DefaultFilter,
    onImpact = function(Ctx)
        if not IS_SERVER then return end
        if DEBUG_PUNCH_MARKERS then
            SpawnPunchMarker(Ctx.position, Color3.fromRGB(255, 120, 60))
        end
    end,
    onIntersection = function(Ctx)
        if not IS_SERVER then return end
        if DEBUG_PUNCH_MARKERS then
            SpawnPunchMarker(Ctx.position, Color3.fromRGB(80, 255, 120))
        end
        local Humanoid = Ctx.character:FindFirstChildOfClass("Humanoid")
        if Humanoid then
            local Damage = (Ctx.extra and Ctx.extra.Damage) or 20
            ApplyDamage(Humanoid, Damage)
        end
    end,
    onDestroyed = function(_Ctx) end,
}

return {
    Bullet = Bullet,
    Grenade = Grenade,
    Punch = Punch,
}
