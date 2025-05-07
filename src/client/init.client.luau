--[[

    CITO CLIENT
    Initializes Cito loader with client modules.

    Encryptal 

--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Cito = require(ReplicatedStorage.Shared:WaitForChild("Cito")).new()

Cito:Discover({ReplicatedStorage.Shared, ReplicatedStorage.Packages, script}) -- All descendent modules of these directories can be imported.
    :LoadModules(script.Controllers)
    :Init()
