--[[
    MeleePunch Component

    Alternating-hand melee for fist-style tools. Each press of MB1 plays
    PunchLeft or PunchRight (alternated per swing), gated by a per-swing
    cooldown. On the animation's `Hit` marker the component fires a "Punch"
    projectile through ProjectileController:Cast — the server resolves it
    against rewound character poses, the client's local Hindsight world casts
    in parallel for instant visuals, and ProjectileDebugController records the
    ray for the Iris overlay.

    Range and damage default to the Punch projectile definition in
    shared/Data/Projectiles, but each can be overridden per swing via
    Config.Range / Config.Damage (clamped server-side).

    Config:
        Cooldown            number?  — minimum seconds between swing starts (default 0.35)
        LeftAnimationName   string?  — defaults to "PunchLeft"
        RightAnimationName  string?  — defaults to "PunchRight"
        HitMarker           string?  — animation marker that fires the cast (default "Hit")
        ImpactImpulse       number?  — Y shove fed into Tool.Springs.Impact on every swing (default 0.04)
        Damage              number?  — per-swing damage override (forwarded via modifier.extra.Damage; Punch definition reads it on intersection)
        Range               number?  — per-swing range override in studs (forwarded as modifier.range to Hindsight hitscan)

    Depends on:
        Trove (lifecycle)
        ProjectileController (drives the client Hindsight world + debug overlay,
            and fires FireProjectile to the server — server resolves the Punch
            projectile against rewound character poses)
]]

local Trove = shared.Import("Trove")
local ProjectileController = shared.Import("ProjectileController")

local MeleePunch = {}
MeleePunch.__index = MeleePunch

MeleePunch.Bindings = {
    Punch = {
        Inputs = {Enum.UserInputType.MouseButton1},
        OnState = function(self, State)
            if State == Enum.UserInputState.Begin then
                self:WishPunch()
            end
        end,
    },
}

function MeleePunch.new(Tool, Config)
    local self = setmetatable({}, MeleePunch)
    self.Tool = Tool
    self.Config = Config

    self.Cooldown = Config.Cooldown or Tool.Data.Cooldown or 0.35
    self.LeftAnimationName = Config.LeftAnimationName or "PunchLeft"
    self.RightAnimationName = Config.RightAnimationName or "PunchRight"
    self.HitMarker = Config.HitMarker or "Hit"
    self.ImpactImpulse = Config.ImpactImpulse or 0.04
    self.Damage = Config.Damage
    self.Range = Config.Range

    self.NextHand = "Left"
    self.LastSwing = 0
    self.PendingHand = nil
    self.WatchdogToken = 0

    self.Trove = Trove.new()
    return self
end

function MeleePunch:Init()
    -- Wire each animation's Hit marker once. The marker handler reads
    -- self.PendingHand so the raycast knows which swing it's resolving — set
    -- when we play the animation, cleared after the marker fires.
    local LeftAnim = self.Tool.Animations[self.LeftAnimationName]
    local RightAnim = self.Tool.Animations[self.RightAnimationName]

    if not LeftAnim then
        warn(string.format(
            "[MeleePunch] Animation %q not found on tool %q. Add it to Data.Animations or set Config.LeftAnimationName.",
            self.LeftAnimationName, self.Tool.Data.Name or "?"))
    end
    if not RightAnim then
        warn(string.format(
            "[MeleePunch] Animation %q not found on tool %q. Add it to Data.Animations or set Config.RightAnimationName.",
            self.RightAnimationName, self.Tool.Data.Name or "?"))
    end

    if LeftAnim then
        self.Trove:Add(LeftAnim:GetMarkerReachedSignal(self.HitMarker):Connect(function()
            if self.PendingHand == "Left" then
                self:_ResolveHit("Left")
                self.PendingHand = nil
            end
        end))
    end
    if RightAnim then
        self.Trove:Add(RightAnim:GetMarkerReachedSignal(self.HitMarker):Connect(function()
            if self.PendingHand == "Right" then
                self:_ResolveHit("Right")
                self.PendingHand = nil
            end
        end))
    end
end

function MeleePunch:_CanSwing(): boolean
    if not self.Tool.Equipped or self.Tool.Swapping then return false end
    if (tick() - self.LastSwing) < self.Cooldown then return false end
    return true
end

function MeleePunch:WishPunch()
    if not self:_CanSwing() then return end

    local Hand = self.NextHand
    self.NextHand = if Hand == "Left" then "Right" else "Left"
    self.LastSwing = tick()
    self.PendingHand = Hand

    local AnimationName = if Hand == "Left" then self.LeftAnimationName else self.RightAnimationName
    local Animation = self.Tool.Animations[AnimationName]
    if Animation then
        Animation:Play(0)
        self:_ArmMarkerWatchdog(Animation, Hand)
    else
        warn(string.format(
            "[MeleePunch] Tried to swing %s but animation %q is missing — no hitscan will fire.",
            Hand, AnimationName))
        self.PendingHand = nil
    end

    -- Cosmetic windup kick on every swing — separate from the contact kick in
    -- _ResolveHit. Sign alternates by hand so the viewmodel slides toward the
    -- swinging side rather than always the same way.
    local ImpactSpring = self.Tool.Springs.Impact
    if ImpactSpring then
        local Sign = if Hand == "Left" then -1 else 1
        ImpactSpring:Shove(Vector3.new(Sign * self.ImpactImpulse * 0.5, self.ImpactImpulse, 0))
    end
end

-- Catches the "swing played but Hit marker never fired" case — the most common
-- symptom of an animation that was uploaded without the event keyframe. Runs
-- once per swing keyed on WatchdogToken so re-clicking before the previous
-- watchdog fires invalidates the old one instead of spamming false warns.
function MeleePunch:_ArmMarkerWatchdog(Animation, Hand: string)
    self.WatchdogToken += 1
    local Token = self.WatchdogToken
    local Timeout = math.max(Animation.Length, 0.5) + 0.1

    task.delay(Timeout, function()
        if Token ~= self.WatchdogToken then return end
        if self.PendingHand ~= Hand then return end
        warn(string.format(
            "[MeleePunch] %s swing finished but the %q marker never fired on animation %q. " ..
            "Open the animation in the Editor and add an Event keyframe named %q at the contact frame.",
            Hand, self.HitMarker,
            Hand == "Left" and self.LeftAnimationName or self.RightAnimationName,
            self.HitMarker))
        self.PendingHand = nil
    end)
end

function MeleePunch:_ResolveHit(_Hand: string)
    local Camera = workspace.CurrentCamera
    local Origin = Camera.CFrame.Position
    local Direction = Camera.CFrame.LookVector

    -- Hindsight 0.2.0 hitscan: ProjectileController:Hitscan fires
    -- HitscanProjectile to the server (which World:hitscans against rewound
    -- character poses) and mirrors the ray on the local Hindsight world.
    -- Range/Damage from Config override the Punch definition's defaults per
    -- swing (Range → modifier.range, Damage → modifier.extra.Damage which the
    -- Punch projectile reads on intersection).
    local Modifier = nil
    if self.Range or self.Damage then
        Modifier = {
            Range = self.Range,
            Damage = self.Damage,
        }
    end
    ProjectileController:Hitscan("Punch", Origin, Direction, Modifier)
end

function MeleePunch:Unequip()
    self.PendingHand = nil
    self.WatchdogToken += 1 -- invalidate any in-flight watchdog
end

function MeleePunch:CreateDebug(Iris)
    local YesText = "<font color='rgb(0, 255, 0)'>Yes</font>"
    local NoText = "<font color='rgb(255, 0, 0)'>No</font>"

    local CanSwing = self:_CanSwing()
    local TimeSince = math.round((tick() - self.LastSwing) * 100) / 100

    Iris.Text({"Next Hand: " .. self.NextHand})
    Iris.Text({"Can Swing: " .. (CanSwing and YesText or NoText), nil, nil, true})
    Iris.Text({"Time Since Swing: " .. TimeSince .. " / " .. self.Cooldown})
end

function MeleePunch:Destroy()
    self.Trove:Destroy()
end

return MeleePunch
