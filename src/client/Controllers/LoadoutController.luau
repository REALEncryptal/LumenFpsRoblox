local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

local Controller = {Signals={}}

Controller.Priority = 70

local ToolManager

-- Builds (or rebuilds) the ToolManager for the given Character. Used by both
-- CharacterAdded and the CurrentCamera-change rebuild path. `EquipToolName`
-- lets the camera-reset rebuild restore whatever the player had out before
-- the camera nuked the viewmodel.
local function BuildManager(Character: Model, EquipToolName: string?)
    if Controller.Manager then
        Controller.Manager:Destroy()
        Controller.Manager = nil
    end

    Controller.Manager = ToolManager.new(Character)
    Controller.Manager:AddTool("Fists")
    Controller.Manager:AddTool("M4A1")

    -- Grenade is data-driven via the new ThrowableInventory/Cook/Spawn
    -- components — no subclass needed. Skip silently if the Studio asset
    -- hasn't been authored yet so existing playtest setups don't break.
    if ReplicatedStorage.Weapons:FindFirstChild("M67") then
        Controller.Manager:AddTool("M67")
    end

    Controller.Manager:EquipTool(EquipToolName or "Fists")
end

function Controller:Init()
    ToolManager = shared.Import("ToolManager")

    -- Roblox occasionally destroys + recreates `workspace.CurrentCamera`
    -- (respawn, CameraType resets). The viewmodel is parented to the camera,
    -- so when the camera dies the viewmodel dies with it and update tasks
    -- start hitting nil descendants. Rebuild the ToolManager against the new
    -- camera so the viewmodel comes back without waiting for the next
    -- respawn. ToolBase has defensive guards that suppress per-frame errors
    -- in the gap between camera-destroyed and the rebuild landing.
    workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
        local Character = LocalPlayer.Character
        if not Character or not Character.Parent then return end
        if not Controller.Manager then return end
        BuildManager(Character, Controller.Manager.EquippedTool)
    end)

    if LocalPlayer.Character then
        Controller.Signals.CharacterAdded(LocalPlayer.Character)
    end
end

function Controller.Signals.CharacterAdded(Character: Model)
    BuildManager(Character)
end

function Controller.Signals.Update(DeltaTime: number)
    if not Controller.Manager then return end
    Controller.Manager:Update(DeltaTime)
end

return Controller
