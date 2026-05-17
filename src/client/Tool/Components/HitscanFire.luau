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
        CameraRecoil        number?  — scalar multiplier on per-shot camera kick. Lets a
                                     weapon dial aim-disturbance up or down without
                                     changing the per-shot range. Falls back to
                                     Tool.Data.CameraRecoil, then 1.0.
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

-- Probe distance for the "where is the player looking" raycast that anchors the
-- visual tracer's endpoint. Comfortably exceeds Bullet's max travel
-- (velocity 1000 × lifetime 3 = 3000 studs).
local AIM_PROBE_RANGE = 5000

-- Debug auto-fire cadence. Independent of RPM so the tester picks the rate.
local DEBUG_AUTO_FIRE_INTERVAL = 0.25

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

    -- Debug toggles surfaced by CreateDebug. Bypass ammo consumption and drive
    -- a fixed-cadence auto-trigger so a tester can profile fire without holding
    -- the mouse or reloading. Off by default; CreateDebug writes them every
    -- frame while the panel is open and Iris state persists across re-renders,
    -- so toggles stay where you left them (including with the panel closed).
    self.DebugInfAmmo = false
    self.DebugAutoFire = false
    self.DebugAutoFireLast = 0

    return self
end

function HitscanFire:Init()
    -- Priority 104 matches the legacy Firearm.UpdateFire — same place in the
    -- pipeline so spring shoves on fire reflect this frame's recoil.
    self.Tool:AddUpdateTask("UpdateFire", 104, function(_Dt)
        if self.DebugAutoFire then
            local Now = tick()
            if (Now - self.DebugAutoFireLast) >= DEBUG_AUTO_FIRE_INTERVAL then
                self.DebugAutoFireLast = Now
                self:_AttemptFire(true)
            end
        end

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

    if not self.DebugInfAmmo then
        local Ammo = self.Tool:GetComponent("AmmoStore")
        if not Ammo or Ammo:IsEmpty() then return false end
    end

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
    if not self.DebugInfAmmo then
        local Ammo = self.Tool:GetComponent("AmmoStore")
        if Ammo then Ammo:Consume(1) end
    end
    self.LastShot = tick()

    -- Two parallel recoil channels: the Impact spring drives the *viewmodel*
    -- kick (visual feedback only — fully recovers via spring damping), and
    -- CameraController:ApplyRecoil drives the *aim* kick (actually rotates the
    -- camera so the player has to compensate). Vertical and horizontal magnitudes
    -- are rolled uniformly inside their per-weapon ranges; YawSign is randomized
    -- so bursts spray instead of drifting one direction; a small lateral Impact-X
    -- shove lets the viewmodel slide with the yaw for visual coherence.
    local VR, HR = self.VerticalRecoil, self.HorizontalRecoil
    local Pitch = (VR[1] + math.random() * (VR[2] - VR[1])) * self.CameraRecoil
    local YawMag = (HR[1] + math.random() * (HR[2] - HR[1])) * self.CameraRecoil
    local YawSign = math.random() < 0.5 and -1 or 1

    local ImpactSpring = self.Tool.Springs.Impact
    if ImpactSpring then
        ImpactSpring:Shove(Vector3.new(YawSign * self.RecoilImpulse * 0.4, self.RecoilImpulse, 0))
    end

    CameraController:ApplyRecoil(Pitch, YawSign * YawMag)

    -- Hindsight resolves the shot. Camera-space origin/direction matches the
    -- server's origin-drift validation tolerance.
    local Camera = workspace.CurrentCamera
    local Origin = Camera.CFrame.Position
    local Direction = Camera.CFrame.LookVector

    -- Two-ray dual origin: the server still hit-resolves on the camera ray
    -- (so aim stays pixel-accurate to the crosshair), but the visible tracer is
    -- drawn from the muzzle attachment aimed at the camera ray's terminus.
    -- Players read tracer endpoint against the crosshair, not actual trajectory,
    -- so this hides the camera-vs-barrel offset without compromising hit-reg.
    local VisualOrigin, VisualDirection
    local Muzzle = self.Tool.Viewmodel:FindFirstChild("Muzzle", true)
    if Muzzle and Muzzle:IsA("Attachment") then
        local AimPoint = self:_ResolveAimPoint(Origin, Direction)
        VisualOrigin = Muzzle.WorldPosition
        VisualDirection = (AimPoint - VisualOrigin).Unit
    end

    ProjectileController:Cast(self.ProjectileType, Origin, Direction, VisualOrigin, VisualDirection)

    local Animation = self.Tool.Animations[self.FireAnimationName]
    if Animation then Animation:Play(0) end
end

-- Camera-aligned probe that finds whatever the player is "looking at" so the
-- muzzle tracer can be aimed at the same point. Excludes characters and bullets
-- to match the server's world filter; the viewmodel lives under CurrentCamera
-- so excluding the camera stops the probe from hitting the player's own gun.
function HitscanFire:_ResolveAimPoint(Origin: Vector3, Direction: Vector3): Vector3
    local Params = self._AimProbeParams
    if not Params then
        Params = RaycastParams.new()
        Params.FilterType = Enum.RaycastFilterType.Exclude
        Params.IgnoreWater = true
        self._AimProbeParams = Params
    end
    Params.FilterDescendantsInstances = {
        workspace.CurrentCamera,
        workspace:FindFirstChild("Characters"),
        workspace:FindFirstChild("Bullets"),
    }
    local Result = workspace:Raycast(Origin, Direction * AIM_PROBE_RANGE, Params)
    if Result then return Result.Position end
    return Origin + Direction * AIM_PROBE_RANGE
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

    -- Iris.State persists across re-renders only if the *same* state object is
    -- handed back each frame — cache on self so toggle values survive between
    -- panel updates.
    local InfAmmoState = self._DebugInfAmmoState
    if not InfAmmoState then
        InfAmmoState = Iris.State(false)
        self._DebugInfAmmoState = InfAmmoState
    end
    local AutoFireState = self._DebugAutoFireState
    if not AutoFireState then
        AutoFireState = Iris.State(false)
        self._DebugAutoFireState = AutoFireState
    end

    Iris.SeparatorText({"Debug"})
    Iris.Checkbox({"Infinite Ammo"}, {isChecked = InfAmmoState})
    Iris.Checkbox({string.format("Auto Fire (%.2fs)", DEBUG_AUTO_FIRE_INTERVAL)}, {isChecked = AutoFireState})

    self.DebugInfAmmo = InfAmmoState.value
    self.DebugAutoFire = AutoFireState.value
end

return HitscanFire
