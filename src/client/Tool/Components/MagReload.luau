--[[
    MagReload Component

    Animation-driven magazine reload: pressing R plays the Reload animation;
    when the animation hits its MagIn marker, the mag swaps and AmmoStore
    refills in one chunk. If the user fires during reload (handled by
    HitscanFire), or unequips mid-reload, the animation stops and the reload
    interrupts cleanly. If the user re-equips a tool that was mid-reload when
    they last had it out, the reload picks back up from the start.

    Config:
        AnimationName  string?  — defaults to "Reload"
        MagInMarker    string?  — defaults to "MagIn"
        FovCrossfadeTime number? — half-time of the FOV blend during reload-in-ADS

    Depends on:
        AmmoStore (for capacity / consume logic — required)
        ADS       (optional — drives FOV crossfade when reloading while aiming)
        Crosshair (optional — shown/hidden through tool facade)
]]

local CameraController = shared.Import("CameraController")
local SettingsController = shared.Import("SettingsController")
local InteractionController = shared.Import("InteractionController")
local Trove = shared.Import("Trove")

local MagReload = {}
MagReload.__index = MagReload

MagReload.Bindings = {
    Reload = {
        Inputs = {Enum.KeyCode.R},
        OnState = function(self, State)
            if State ~= Enum.UserInputState.Begin then return end
            self:WishReload()
        end,
    },
}

function MagReload.new(Tool, Config)
    local self = setmetatable({}, MagReload)
    self.Tool = Tool
    self.Config = Config
    self.AnimationName = Config.AnimationName or "Reload"
    self.MagInMarker = Config.MagInMarker or "MagIn"

    self.Reloading = false
    self.WasReloading = false

    self.Trove = Trove.new()
    return self
end

function MagReload:_AmmoStore()
    return self.Tool:GetComponent("AmmoStore")
end

function MagReload:_Ads()
    return self.Tool:GetComponent("ADS")
end

function MagReload:_Animation()
    return self.Tool.Animations[self.AnimationName]
end

function MagReload:Init()
    local Animation = self:_Animation()
    if not Animation then return end

    -- MagIn marker is the canonical "mag is now seated" beat in the animation.
    -- That's when ammo actually swaps over.
    self.Trove:Add(Animation:GetMarkerReachedSignal(self.MagInMarker):Connect(function()
        self:Complete()
    end))

    -- Animation can also stop on its own (track replaced, weight zeroed, etc.).
    -- Make sure Reloading flag clears so the tool can fire again.
    self.Trove:Add(Animation.Stopped:Connect(function()
        self.Reloading = false
    end))
end

-- Whether the tool can begin a reload right now. Used by the WishReload
-- guard and by HitscanFire's empty-trigger auto-reload path.
function MagReload:CanReload(): boolean
    if self.Reloading then return false end
    if not self.Tool.Equipped or self.Tool.Swapping then return false end

    local Ammo = self:_AmmoStore()
    return Ammo ~= nil and Ammo:CanRefill()
end

function MagReload:WishReload()
    if not self:CanReload() then return end

    self.Reloading = true
    InteractionController.Enabled = false

    local Animation = self:_Animation()
    if Animation then Animation:Play() end
    self.Tool:HideCrosshair()

    local CrossfadeTime = (self.Config.FovCrossfadeTime or self.Tool.Data.ADSTime * 0.5)
    CameraController:TweenFOV(SettingsController:GetSetting("FOV"), CrossfadeTime)
end

-- Fired by the animation's MagIn marker.
function MagReload:Complete()
    self.Reloading = false

    local Ads = self:_Ads()
    if not Ads or not Ads:IsAiming() then
        self.Tool:ShowCrosshair()
    end

    local Ammo = self:_AmmoStore()
    if Ammo then Ammo:Refill() end

    if Ads and Ads:IsAiming() then
        local CrossfadeTime = (self.Config.FovCrossfadeTime or self.Tool.Data.ADSTime * 0.5)
        CameraController:TweenFOV(self.Tool.Data.ADSFOV, CrossfadeTime)
    end

    InteractionController.Enabled = true
end

-- Called by HitscanFire on fire-during-reload, or by Unequip mid-reload.
-- Stops the animation; Reloading flag clears via the Stopped connection.
function MagReload:Interrupt()
    if not self.Reloading then return end
    local Animation = self:_Animation()
    if Animation then Animation:Stop() end
    self.Reloading = false
end

function MagReload:Unequip()
    -- If we're putting the tool away mid-reload, snapshot that we were so
    -- Equip can resume the reload next time this tool comes out.
    if self.Reloading then
        self.WasReloading = true
        self:Interrupt()
    end
end

function MagReload:Equip()
    if self.WasReloading then
        self.WasReloading = false
        self:WishReload()
    end
end

function MagReload:GetHudContribution()
    -- Override AmmoStore's Primary while a reload is in flight so the UI
    -- shows "--" until MagIn lands. Secondary (stored ammo) is unchanged.
    if not self.Reloading then return nil end
    return { Primary = "--" }
end

function MagReload:CreateDebug(Iris)
    local YesText = "<font color='rgb(0, 255, 0)'>Yes</font>"
    local NoText = "<font color='rgb(255, 0, 0)'>No</font>"

    Iris.Text({"Reloading: " .. (self.Reloading and YesText or NoText), nil, nil, true})
    Iris.Text({"Was Reloading: " .. (self.WasReloading and YesText or NoText), nil, nil, true})
    Iris.Text({"Can Reload: " .. (self:CanReload() and YesText or NoText), nil, nil, true})
end

function MagReload:Destroy()
    self.Trove:Destroy()
end

return MagReload
