--[[
    ThrowableInventory Component

    Tracks how many of this throwable the player has left. Hands off depletion
    signal so ToolManager (or another component) can swap to a different tool
    when the player throws their last grenade.

    Config:
        Capacity number? — starting count (defaults to Data.Capacity or 2)

    State:
        Count number
        OnDepleted Signal (Trove-backed, fires once when Count hits 0)
]]

local Signal = shared.Import("Signal")
local Trove = shared.Import("Trove")

local ThrowableInventory = {}
ThrowableInventory.__index = ThrowableInventory

function ThrowableInventory.new(tool, config)
    local self = setmetatable({}, ThrowableInventory)
    self.Tool = tool
    self.Config = config
    self.Capacity = config.Capacity or tool.Data.Capacity or 2
    self.Count = self.Capacity

    self.Trove = Trove.new()
    self.OnDepleted = self.Trove:Add(Signal.new())
    return self
end

function ThrowableInventory:Has(): boolean
    return self.Count > 0
end

function ThrowableInventory:Consume()
    if self.Count <= 0 then return end
    self.Count -= 1
    if self.Count <= 0 then
        self.OnDepleted:Fire()
    end
end

function ThrowableInventory:GetHudContribution()
    return {
        primary = self.Count,
        mode = "count",
    }
end

function ThrowableInventory:CreateDebug(Iris)
    Iris.Text({"Count: " .. self.Count .. " / " .. self.Capacity})
    if Iris.Button({"Refill"}).clicked() then
        self.Count = self.Capacity
    end
end

function ThrowableInventory:Destroy()
    self.Trove:Destroy()
end

return ThrowableInventory
