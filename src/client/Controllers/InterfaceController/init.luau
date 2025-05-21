local Controller = {
    Signals = {}
}


local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
Controller.Priority = 35

local CharacterController

function Controller:Init() 
    CharacterController = shared.Import("CharacterController")

    Controller.Instance = Players.LocalPlayer.PlayerGui:WaitForChild("Game")

    Controller.WeaponUI = require(script.WeaponUI):Init(Controller)
    Controller.EffectUI = require(script.EffectUI):Init(Controller)
end

function Controller.Signals.Update(DeltaTime: number)
    Controller.WeaponUI:Update(DeltaTime)
    Controller.EffectUI:Update(DeltaTime)

    -- hide cursor in first person
    local Character = CharacterController.GetCharacter()
    if not Character then return end
    if not Character.Head then return end

    if Character.Head.LocalTransparencyModifier == 1 then
       UserInputService.MouseIconEnabled = false 
    else
       UserInputService.MouseIconEnabled = true 
    end
end

-- Utility functions
function Controller:SetText(Label:TextLabel, Text: string)
    Label.Text = Text

    if Label:FindFirstChild("ShadowLabel") then
        Controller:SetText(Label:FindFirstChild("ShadowLabel"), Text)
    end
end

function Controller:SetImage(Image:ImageLabel, ImageId:string)
    Image.Image = ImageId

    if Image:FindFirstChild("ShadowImage") then
        Controller:SetImage(Image:FindFirstChild("ShadowImage"), ImageId)
    end
end

return Controller