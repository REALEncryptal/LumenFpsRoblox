local Controller = {
    Signals = {},
    Loadouts = {}
}


local Net
function Controller:Init()
    Net = shared.Import("Net")
end

function Controller.Signals.PlayerAdded(Player:Player)
    
end

return Controller