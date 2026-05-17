--[[
    AmmoStore Component

    Owns ammo bookkeeping for a firearm-style tool: how many rounds are in the
    magazine, how many are held in reserve, and the math for consuming or
    refilling on reload. Nothing about firing or reloading lives here — that's
    HitscanFire and MagReload's job. AmmoStore is a value store with HUD
    rendering and a debug panel.

    Config:
        Capacity     number  — magazine size (rounds per reload)
        StoredStart  number? — reserve rounds the tool spawns with; defaults to Capacity

    Reachable via:
        Tool:GetComponent("AmmoStore"):Consume(n)
        Tool:GetComponent("AmmoStore"):Refill()
        Tool:GetComponent("AmmoStore"):IsEmpty()
]]

local AmmoStore = {}
AmmoStore.__index = AmmoStore

function AmmoStore.new(Tool, Config)
    local self = setmetatable({}, AmmoStore)
    self.Tool = Tool
    self.Capacity = Config.Capacity or Tool.Data.MagCapacity
    self.Ammo = self.Capacity
    self.StoredAmmo = Config.StoredStart or self.Capacity
    return self
end

function AmmoStore:Consume(Amount: number)
    Amount = Amount or 1
    self.Ammo = math.max(0, self.Ammo - Amount)
end

function AmmoStore:IsEmpty(): boolean
    return self.Ammo <= 0
end

function AmmoStore:CanRefill(): boolean
    return self.StoredAmmo > 0 and self.Ammo < self.Capacity
end

-- Moves rounds from the reserve into the magazine. Returns the amount actually
-- moved so callers (MagReload) can update sounds / animations if needed.
function AmmoStore:Refill(): number
    local Needed = self.Capacity - self.Ammo
    local Moved = math.min(Needed, self.StoredAmmo)
    self.Ammo += Moved
    self.StoredAmmo -= Moved
    return Moved
end

function AmmoStore:GetHudContribution()
    return {
        Primary = self.Ammo,
        Secondary = self.StoredAmmo,
        Mode = "ammo",
    }
end

function AmmoStore:CreateDebug(Iris)
    local YesText = "<font color='rgb(0, 255, 0)'>Yes</font>"
    local NoText = "<font color='rgb(255, 0, 0)'>No</font>"

    Iris.Text({"Ammo: " .. self.Ammo})
    Iris.Text({"Stored Ammo: " .. self.StoredAmmo})
    Iris.Text({"Can Refill: " .. (self:CanRefill() and YesText or NoText), nil, nil, true})

    if Iris.Button({"Refill mag"}).clicked() then
        self:Refill()
    end
end

return AmmoStore
