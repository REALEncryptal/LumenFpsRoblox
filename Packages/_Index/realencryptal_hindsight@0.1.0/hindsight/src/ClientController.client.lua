--!strict

--> Per-actor client controller. Body mirrors ServerController; separate file
--> exists so Rojo emits a LocalScript (runs on the client) rather than a
--> Script (server-only).

local Actor = script.Parent :: Actor

Actor:BindToMessage("Initialize", function(
	simulationModule: ModuleScript,
	definitionsModule: ModuleScript,
	payload: any,
	rollbackConfig: any?
)
	local simulation = (require(simulationModule) :: any) :: { initialize: (Actor, any, any, any?) -> () }
	local definitions = require(definitionsModule) :: any
	simulation.initialize(Actor, payload, definitions, rollbackConfig)
end)
