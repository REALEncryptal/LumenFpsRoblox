--[[
    
    Created Thursday, May 8th 2025, 8:45:33 pm
    RealEncryptal
    
--]]

local Controller = {}

Controller.Priority = 0

function Controller:Init()
    Controller.Iris = shared.Import("iris")
    Controller.Gizmo = shared.Import("imgizmo")

    Controller.Iris.Init()
    Controller.Gizmo.Init()
end

return Controller