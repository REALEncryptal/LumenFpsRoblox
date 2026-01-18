local Controller = {
    Signals = {}
}

local SecureCast
function Controller:Init()
    SecureCast = shared.Import("SecureCast")
    SecureCast.Initialize()
end

function Controller.Signals.PlayerAdded(Player:Player)
    if Player.Character then
        Player.Character.Parent = workspace.Characters
    end
    
    Player.CharacterAdded:Connect(function(Character)
        Character.Parent = workspace.Characters
    end)
    
end

return Controller