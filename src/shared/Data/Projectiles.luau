--!strict

-- Hindsight projectile definitions. Both the main thread and every simulation
-- actor require this module independently, which is why callbacks live here
-- (functions cannot cross actor VM boundaries via the per-cast Modifier).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Hindsight = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Hindsight"))

local IS_SERVER = RunService:IsServer()

local CharactersFolderName = "Characters"

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

return {
    Bullet = Bullet,
    Grenade = Grenade,
}
