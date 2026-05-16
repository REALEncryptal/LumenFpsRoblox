--!strict

--> Per-actor server controller. Cloned by the Dispatcher into every simulation
--> Actor. Stays minimal: bind to the Initialize message, then hand off to the
--> Simulation module which installs Dispatch / Capture handlers.

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
