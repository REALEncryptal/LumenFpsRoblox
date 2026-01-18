--[[
    
    ObjectProvider Controller
        Loads all objects after init so that they may use shared.Import
    
    Created Sunday, May 4th 2025, 12:41:05 pm
    RealEncryptal
    
--]]

local Controller = {
    Objects = {},
}

Controller.Priority = 50

function Controller:Init() 
    Controller:Load("PlayerLoadout")
end

function Controller:Load(Name:string)
    Controller.Objects[Name] = require(script:FindFirstChild(Name))
end

return Controller