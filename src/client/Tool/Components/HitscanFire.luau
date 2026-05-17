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
        RecoilImpulse       number?  — Y impulse fed into tool.Springs.Impact on each shot.
                                     Falls back to tool.Data.RecoilImpulse, then 0.05.
                                     Spring3 internally ×100s the shove, and ToolBase
                                     multiplies the resulting position by 25 for viewmodel
                                     rotation — values above ~0.1 read as violent.

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
        OnState = function(self, state)
            self.WishFire = state == Enum.UserInputState.Begin
        end,
    },
}

function HitscanFire.new(tool, config)
    local self = setmetatable({}, HitscanFire)
    self.Tool = tool
    self.Config = config

    self.RPM = config.RPM or tool.Data.RPM
    self.Automatic = if config.Automatic ~= nil then config.Automatic else tool.Data.Automatic
    self.ProjectileType = config.ProjectileType or "Bullet"
    self.FireAnimationName = config.FireAnimationName or "Fire"
    self.RecoilImpulse = config.RecoilImpulse or tool.Data.RecoilImpulse or 0.05

    self.WishFire = false
    self.WasWishFire = false
    self.LastShot = 0

    return self
end

function HitscanFire:Init()
    -- Priority 104 matches the legacy Firearm.UpdateFire — same place in the
    -- pipeline so spring shoves on fire reflect this frame's recoil.
    self.Tool:AddUpdateTask("UpdateFire", 104, function(_dt)
        if self.WishFire then
            self:_attemptFire(not self.WasWishFire)
        end
        self.WasWishFire = self.WishFire
    end)
end

function HitscanFire:Unequip()
    -- Drop the held-fire flag so re-equipping doesn't auto-fire next frame.
    self.WishFire = false
    self.WasWishFire = false
end

function HitscanFire:_canFire(): boolean
    if not self.Tool.Equipped or self.Tool.Swapping then return false end

    local ammo = self.Tool:GetComponent("AmmoStore")
    if not ammo or ammo:IsEmpty() then return false end

    local now = tick()
    if (now - self.LastShot) < 60 / self.RPM then return false end

    return true
end

-- Called from the per-frame poll. `isClick` is true only on the rising edge of
-- WishFire, used to gate semi-auto and to trigger auto-reload on empty.
function HitscanFire:_attemptFire(isClick: boolean)
    if not isClick and not self.Automatic then return end

    local ammo = self.Tool:GetComponent("AmmoStore")
    local reload = self.Tool:GetComponent("MagReload")

    -- Empty click while holding a magless gun → auto-reload, same as Firearm.
    if isClick and ammo and ammo:IsEmpty() and reload then
        reload:WishReload()
    end

    if not self:_canFire() then return end

    -- Interrupting an in-flight reload: stop the animation and put the
    -- crosshair/FOV back to where the user expects given current ADS state.
    if reload and reload.Reloading then
        reload:Interrupt()

        local ads = self.Tool:GetComponent("ADS")
        if not (ads and ads:IsAiming()) then
            self.Tool:ShowCrosshair()
        else
            local crossfade = self.Tool.Data.ADSTime * 0.5
            CameraController:TweenFOV(self.Tool.Data.ADSFOV, crossfade)
        end
    end

    self:_doFire()
end

function HitscanFire:_doFire()
    local ammo = self.Tool:GetComponent("AmmoStore")
    if ammo then ammo:Consume(1) end
    self.LastShot = tick()

    -- Recoil shove. The Impact spring is built into ToolBase but the legacy
    -- Firearm never poked it on fire; HitscanFire does.
    local impactSpring = self.Tool.Springs.Impact
    if impactSpring then
        impactSpring:Shove(Vector3.new(0, self.RecoilImpulse, 0))
    end

    -- Hindsight resolves the shot. Camera-space origin/direction matches the
    -- server's origin-drift validation tolerance.
    local camera = workspace.CurrentCamera
    ProjectileController:Cast(self.ProjectileType, camera.CFrame.Position, camera.CFrame.LookVector)

    local animation = self.Tool.Animations[self.FireAnimationName]
    if animation then animation:Play(0) end
end

function HitscanFire:CreateDebug(Iris)
    local YesText = "<font color='rgb(0, 255, 0)'>Yes</font>"
    local NoText = "<font color='rgb(255, 0, 0)'>No</font>"

    local canFire = self:_canFire()
    local timeSince = math.round((tick() - self.LastShot) * 10) / 10

    Iris.Text({"Can Fire: " .. (canFire and YesText or NoText), nil, nil, true})
    Iris.Text({"Wish Fire: " .. (self.WishFire and YesText or NoText), nil, nil, true})
    Iris.Text({"Time Since Last Shot: " .. timeSince})
    Iris.Text({"RPM: " .. tostring(self.RPM)})
    Iris.Text({"Automatic: " .. (self.Automatic and YesText or NoText), nil, nil, true})
end

return HitscanFire
