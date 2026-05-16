--[[
    Firearm

    Thin ToolBase subclass that wires the standard firearm Component set onto a
    tool. All behavior (ammo, reload, ADS, fire, recoil, HUD) lives in the
    Components — Firearm just decides which ones to add and pulls config from
    the tool's data file.

    Once tool data modules migrate to declaring `Components = {...}` directly,
    this subclass and the ClassMap dispatch in ToolManager can both go away.
]]

local ToolBase = shared.Import("ToolBase")

local Firearm = setmetatable({}, ToolBase)
Firearm.__index = Firearm

function Firearm.new(ToolFolder: Folder)
    local self = setmetatable(ToolBase.new(ToolFolder), Firearm)
    self.Type = "Firearm"

    -- Crosshair is added by ToolBase's legacy fallback for Data.Crosshair = true.
    -- The order here matches the HUD merge order: AmmoStore writes primary +
    -- secondary, MagReload overrides primary to "--" while reloading.
    self:AddComponent("AmmoStore", shared.Import("AmmoStore"), {
        Capacity = self.Data.MagCapacity,
        StoredStart = self.Data.MagCapacity,
    })
    self:AddComponent("MagReload", shared.Import("MagReload"), {})
    self:AddComponent("ADS", shared.Import("ADS"), {})
    self:AddComponent("HitscanFire", shared.Import("HitscanFire"), {
        RPM = self.Data.RPM,
        Automatic = self.Data.Automatic,
        ProjectileType = "Bullet",
    })

    return self
end

return Firearm
