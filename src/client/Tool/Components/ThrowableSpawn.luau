--[[
    ThrowableSpawn Component

    Listens for ThrowableCook's OnThrow signal, consumes one item from
    ThrowableInventory, and hands the projectile to ProjectileController.

    Origin matches the camera (server validates origin proximity to head).
    Direction is the camera LookVector — Hindsight applies the projectile's
    gravity to give the arc.

    Config:
        ProjectileType string? — Hindsight definition key (default "Grenade")
]]

local ProjectileController = shared.Import("ProjectileController")
local Trove = shared.Import("Trove")

local ThrowableSpawn = {}
ThrowableSpawn.__index = ThrowableSpawn

function ThrowableSpawn.new(Tool, Config)
    local self = setmetatable({}, ThrowableSpawn)
    self.Tool = Tool
    self.Config = Config
    self.ProjectileType = Config.ProjectileType or "Grenade"

    self.Trove = Trove.new()
    return self
end

function ThrowableSpawn:Init()
    local Cook = self.Tool:GetComponent("ThrowableCook")
    if not Cook then
        warn("ThrowableSpawn: tool has no ThrowableCook component; nothing to listen to")
        return
    end

    self.Trove:Add(Cook.OnThrow:Connect(function(CookElapsed)
        self:_Spawn(CookElapsed)
    end))
end

function ThrowableSpawn:_Spawn(CookElapsed: number)
    local Inventory = self.Tool:GetComponent("ThrowableInventory")
    if Inventory then
        if not Inventory:Has() then return end
        Inventory:Consume()
    end

    local Camera = workspace.CurrentCamera
    ProjectileController:Throw(
        self.ProjectileType,
        Camera.CFrame.Position,
        Camera.CFrame.LookVector,
        CookElapsed
    )
end

function ThrowableSpawn:Destroy()
    self.Trove:Destroy()
end

return ThrowableSpawn
