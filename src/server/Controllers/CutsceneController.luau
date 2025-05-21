local Controller = {}

Controller.Priority = 150

local Net
function Controller:Init()
    Net = shared.Import("net")

    Net:RemoteEvent("PlayCutscene")
end


return Controller