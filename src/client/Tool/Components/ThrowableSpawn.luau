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

function ThrowableSpawn.new(tool, config)
    local self = setmetatable({}, ThrowableSpawn)
    self.Tool = tool
    self.Config = config
    self.ProjectileType = config.ProjectileType or "Grenade"

    self.Trove = Trove.new()
    return self
end

function ThrowableSpawn:Init()
    local cook = self.Tool:GetComponent("ThrowableCook")
    if not cook then
        warn("ThrowableSpawn: tool has no ThrowableCook component; nothing to listen to")
        return
    end

    self.Trove:Add(cook.OnThrow:Connect(function(cookElapsed)
        self:_spawn(cookElapsed)
    end))
end

function ThrowableSpawn:_spawn(cookElapsed: number)
    local inventory = self.Tool:GetComponent("ThrowableInventory")
    if inventory then
        if not inventory:Has() then return end
        inventory:Consume()
    end

    local camera = workspace.CurrentCamera
    ProjectileController:Throw(
        self.ProjectileType,
        camera.CFrame.Position,
        camera.CFrame.LookVector,
        cookElapsed
    )
end

function ThrowableSpawn:Destroy()
    self.Trove:Destroy()
end

return ThrowableSpawn
