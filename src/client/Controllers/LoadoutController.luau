local Controller = {Signals={}} 

Controller.Priority = 70

local ToolManager

function Controller:Init()
    ToolManager = shared.Import("ToolManager")

    if game:GetService("Players").LocalPlayer.Character then
        Controller.Signals.CharacterAdded(game:GetService("Players").LocalPlayer.Character)
    end
end 

function Controller.Signals.CharacterAdded(Character: Model)
    Controller.Manager = ToolManager.new(Character)
    Controller.Manager:AddTool("M4A1")
    Controller.Manager:EquipTool("M4A1")

    local Humanoid = Character:WaitForChild("Humanoid")
    
    Humanoid.Died:Connect(function()
        Controller.Manager:Destroy()
        Controller.Manager = nil
    end)
end

function Controller.Signals.Update(DeltaTime: number)
    if not Controller.Manager then return end
    Controller.Manager:Update(DeltaTime)
end 

return Controller