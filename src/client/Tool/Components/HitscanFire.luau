--[[
    HitscanFire Component

    Per-frame fire input → ammo decrement, fire animation, recoil spring shove,
    and a ProjectileController:Cast() through Hindsight. Auto-reloads on empty
    click via MagReload.

    Config:
        RPM                 number   — rounds per minute (rate-of-fire gate)
        Automatic           boolean? — hold-to-fire when true; click-only otherwise
        ProjectileType      string?  — Hindsight definition key, defaults to "Bullet"
        FireAnimationName   string?  — defaults to "Fire"
        RecoilImpulse       number?  — Y impulse fed into Tool.Springs.Impact on each shot.
                                     Falls back to Tool.Data.RecoilImpulse, then 0.02.
                                     Drives the *viewmodel* kick only (visual feedback);
                                     Spring3 ×100s the shove and ToolBase multiplies the
                                     result by 25 for viewmodel rotation.
        CameraRecoil        number | {n,n}?
                                     Multiplier on per-shot camera kick. Pass a single
                                     number for a fixed multiplier, or {Min, Max} to
                                     roll uniformly in that range every shot. Falls
                                     back to Tool.Data.CameraRecoil, then 1.0.
        VerticalRecoil      {n,n}?   — {Min, Max} degrees of upward camera pitch per shot.
                                     Rolled uniformly in [Min, Max] every shot, then
                                     multiplied by CameraRecoil and fed into
                                     CameraController:ApplyRecoil. Falls back to
                                     Tool.Data.VerticalRecoil, then {0.8, 1.2}.
        HorizontalRecoil    {n,n}?   — {Min, Max} degrees of horizontal yaw per shot.
                                     Magnitude is rolled uniformly in [Min, Max]; sign is
                                     randomized so bursts spray instead of drifting one
                                     direction. Falls back to Tool.Data.HorizontalRecoil,
                                     then {0.4, 0.8}.

    Depends on:
        AmmoStore       (required — consumes a round per shot)
        ProjectileController (controller — calls :Cast)
        MagReload       (optional — empty-click auto-reload + reload-interrupt)
        ADS             (optional — reload-interrupt-during-ADS crossfade behavior)
]]

local CameraController = shared.Import("CameraController")
local ProjectileController = shared.Import("ProjectileController")

local HitscanFire = {}
HitscanFire.__index = HitscanFire

HitscanFire.Bindings = {
    Fire = {
        Inputs = {Enum.UserInputType.MouseButton1},
        OnState = function(self, State)
            self.WishFire = State == Enum.UserInputState.Begin
        end,
    },
}

function HitscanFire.new(Tool, Config)
    local self = setmetatable({}, HitscanFire)
    self.Tool = Tool
    self.Config = Config

    self.RPM = Config.RPM or Tool.Data.RPM
    self.Automatic = if Config.Automatic ~= nil then Config.Automatic else Tool.Data.Automatic
    self.ProjectileType = Config.ProjectileType or "Bullet"
    self.FireAnimationName = Config.FireAnimationName or "Fire"
    self.RecoilImpulse = Config.RecoilImpulse or Tool.Data.RecoilImpulse or 0.02
    self.CameraRecoil = Config.CameraRecoil or Tool.Data.CameraRecoil or 1.0
    self.VerticalRecoil = Config.VerticalRecoil or Tool.Data.VerticalRecoil or {0.8, 1.2}
    self.HorizontalRecoil = Config.HorizontalRecoil or Tool.Data.HorizontalRecoil or {0.4, 0.8}

    self.WishFire = false
    self.WasWishFire = false
    self.LastShot = 0

    return self
end

function HitscanFire:Init()
    -- Priority 104 matches the legacy Firearm.UpdateFire — same place in the
    -- pipeline so spring shoves on fire reflect this frame's recoil.
    self.Tool:AddUpdateTask("UpdateFire", 104, function(_Dt)
        if self.WishFire then
            self:_AttemptFire(not self.WasWishFire)
        end
        self.WasWishFire = self.WishFire
    end)
end

function HitscanFire:Unequip()
    -- Drop the held-fire flag so re-equipping doesn't auto-fire next frame.
    self.WishFire = false
    self.WasWishFire = false
end

function HitscanFire:_CanFire(): boolean
    if not self.Tool.Equipped or self.Tool.Swapping then return false end

    local Ammo = self.Tool:GetComponent("AmmoStore")
    if not Ammo or Ammo:IsEmpty() then return false end

    local Now = tick()
    if (Now - self.LastShot) < 60 / self.RPM then return false end

    return true
end

-- Called from the per-frame poll. `IsClick` is true only on the rising edge of
-- WishFire, used to gate semi-auto and to trigger auto-reload on empty.
function HitscanFire:_AttemptFire(IsClick: boolean)
    if not IsClick and not self.Automatic then return end

    local Ammo = self.Tool:GetComponent("AmmoStore")
    local Reload = self.Tool:GetComponent("MagReload")

    -- Empty click while holding a magless gun → auto-reload, same as Firearm.
    if IsClick and Ammo and Ammo:IsEmpty() and Reload then
        Reload:WishReload()
    end

    if not self:_CanFire() then return end

    -- Interrupting an in-flight reload: stop the animation and put the
    -- crosshair/FOV back to where the user expects given current ADS state.
    if Reload and Reload.Reloading then
        Reload:Interrupt()

        local Ads = self.Tool:GetComponent("ADS")
        if not (Ads and Ads:IsAiming()) then
            self.Tool:ShowCrosshair()
        else
            local Crossfade = self.Tool.Data.ADSTime * 0.5
            CameraController:TweenFOV(self.Tool.Data.ADSFOV, Crossfade)
        end
    end

    self:_DoFire()
end

function HitscanFire:_DoFire()
    local Ammo = self.Tool:GetComponent("AmmoStore")
    if Ammo then Ammo:Consume(1) end
    self.LastShot = tick()

    -- Two parallel recoil channels: the Impact spring drives the *viewmodel*
    -- kick (visual feedback only — fully recovers via spring damping), and
    -- CameraController:ApplyRecoil drives the *aim* kick (Source-style snap —
    -- the offset persists until the player aims back, no auto-recovery).
    -- Vertical and horizontal magnitudes are rolled uniformly inside their
    -- per-weapon ranges; YawSign is randomized so bursts spray instead of
    -- drifting one direction; a small lateral Impact-X shove lets the
    -- viewmodel slide with the yaw for visual coherence.
    local VR, HR, CR = self.VerticalRecoil, self.HorizontalRecoil, self.CameraRecoil
    local CRMul = if type(CR) == "table" then CR[1] + math.random() * (CR[2] - CR[1]) else CR
    local Pitch = (VR[1] + math.random() * (VR[2] - VR[1])) * CRMul
    local YawMag = (HR[1] + math.random() * (HR[2] - HR[1])) * CRMul
    local YawSign = math.random() < 0.5 and -1 or 1

    local ImpactSpring = self.Tool.Springs.Impact
    if ImpactSpring then
        ImpactSpring:Shove(Vector3.new(YawSign * self.RecoilImpulse * 0.4, self.RecoilImpulse, 0))
    end

    CameraController:ApplyRecoil(Pitch, YawSign * YawMag)

    -- Hindsight resolves the shot. Camera-space origin/direction matches the
    -- server's origin-drift validation tolerance.
    local Camera = workspace.CurrentCamera
    ProjectileController:Cast(self.ProjectileType, Camera.CFrame.Position, Camera.CFrame.LookVector)

    local Animation = self.Tool.Animations[self.FireAnimationName]
    if Animation then Animation:Play(0) end
end

function HitscanFire:CreateDebug(Iris)
    local YesText = "<font color='rgb(0, 255, 0)'>Yes</font>"
    local NoText = "<font color='rgb(255, 0, 0)'>No</font>"

    local CanFire = self:_CanFire()
    local TimeSince = math.round((tick() - self.LastShot) * 10) / 10

    Iris.Text({"Can Fire: " .. (CanFire and YesText or NoText), nil, nil, true})
    Iris.Text({"Wish Fire: " .. (self.WishFire and YesText or NoText), nil, nil, true})
    Iris.Text({"Time Since Last Shot: " .. TimeSince})
    Iris.Text({"RPM: " .. tostring(self.RPM)})
    Iris.Text({"Automatic: " .. (self.Automatic and YesText or NoText), nil, nil, true})
end

return HitscanFire
