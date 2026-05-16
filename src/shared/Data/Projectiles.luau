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
local function defaultFilter(
    caster: Hindsight.Caster,
    victim: Player?,
    character: Model,
    _extra: Hindsight.Extra
): boolean
    if victim == caster or character == caster then
        return true
    end
    return false
end

local function applyDamage(humanoid: Humanoid, amount: number)
    if not humanoid or humanoid.Health <= 0 then return end
    humanoid:TakeDamage(amount)
end

local Bullet: Hindsight.ProjectileDefinition = {
    velocity = 1000,
    gravity = Vector3.zero,
    lifetime = 3,
    power = 50,
    angle = 20,
    loss = 0,
    collaterals = false,
    filter = defaultFilter,
    onImpact = function(_ctx) end,
    onIntersection = function(ctx)
        if not IS_SERVER then return end
        local humanoid = ctx.character:FindFirstChildOfClass("Humanoid")
        if humanoid then
            applyDamage(humanoid, 25)
        end
    end,
    onDestroyed = function(_ctx) end,
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
    filter = defaultFilter,
    onImpact = function(_ctx)
        -- Bouncing handled by ricochet (angle/loss). No-op here so the projectile
        -- keeps living until its fuse runs out.
    end,
    onIntersection = function(_ctx)
        -- Grenades don't damage on touch; only on fuse expiry via onDestroyed.
    end,
    onDestroyed = function(ctx)
        -- Server applies the damage AoE and spawns the Explosion. The visual
        -- replicates to every client automatically; if the client cast its own
        -- visual world copy too, gating here prevents a double-blast for the
        -- caster.
        if not IS_SERVER then return end

        local charactersFolder = workspace:FindFirstChild(CharactersFolderName)
        if charactersFolder then
            for _, character in ipairs(charactersFolder:GetChildren()) do
                if not character:IsA("Model") then continue end
                local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
                local humanoid = character:FindFirstChildOfClass("Humanoid")
                if not (root and root:IsA("BasePart") and humanoid) then continue end

                local distance = (root.Position - ctx.position).Magnitude
                if distance > GRENADE_RADIUS then continue end

                local falloff = 1 - (distance / GRENADE_RADIUS)
                applyDamage(humanoid, GRENADE_MAX_DAMAGE * falloff)
            end
        end

        local explosion = Instance.new("Explosion")
        explosion.Position = ctx.position
        explosion.BlastRadius = GRENADE_RADIUS
        explosion.BlastPressure = 0
        explosion.DestroyJointRadiusPercent = 0
        explosion.Parent = workspace
    end,
}

return {
    Bullet = Bullet,
    Grenade = Grenade,
}
