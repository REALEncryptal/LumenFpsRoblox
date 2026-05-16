--!strict

--> Actor pool. Spins up N Actors inside a user-supplied container, hooks each
--> actor's Output event to the main-thread definitions registry, and exposes
--> :dispatch (least-loaded actor) + :broadcast (all actors) + :destroy.

local RunService = game:GetService("RunService")

local Definitions = require(script.Parent.Definitions)

local IS_SERVER = RunService:IsServer()

type Self = {
	_actors: { Actor },
	_connections: { RBXScriptConnection },
	_template: Actor,
	_container: Instance,
}

local Dispatcher = {}
Dispatcher.__index = Dispatcher

export type Dispatcher = typeof(setmetatable({} :: Self, Dispatcher))

export type Options = {
	container: Instance,
	threads: number,
	simulationModule: ModuleScript,
	definitionsModule: ModuleScript,
	definitions: Definitions.Definitions,
	payload: any,
	rollbackConfig: any?,
}

--> Builds the Actor template programmatically once per Dispatcher. The
--> controller (Script on server, LocalScript on client) is cloned from a
--> sibling of the Hindsight module so the template can stay context-agnostic.
local function buildTemplate(): Actor
	local actor = Instance.new("Actor")
	actor:SetAttribute("Tasks", 0)

	local output = Instance.new("BindableEvent")
	output.Name = "Output"
	output.Parent = actor

	local controllerSource = if IS_SERVER then script.Parent.ServerController else script.Parent.ClientController
	local controller = controllerSource:Clone()
	controller.Name = "Controller"
	controller.Parent = actor

	return actor
end

function Dispatcher.new(options: Options): Dispatcher
	assert(options.threads > 0, "Dispatcher: threads must be > 0")

	local template = buildTemplate()
	template.Parent = script --> Keep template alive but inert in the lib's tree.

	local self: Self = {
		_actors = {},
		_connections = {},
		_template = template,
		_container = options.container,
	}

	for _ = 1, options.threads do
		local actor = template:Clone()
		actor.Parent = options.container

		local controller = actor:FindFirstChild("Controller") :: BaseScript?
		if controller then
			controller.Enabled = true
		end

		local output = actor:FindFirstChild("Output") :: BindableEvent
		local connection = output.Event:Connect(function(action: string, ...: any)
			options.definitions:dispatch(action, ...)
		end)

		table.insert(self._actors, actor)
		table.insert(self._connections, connection)
	end

	--> Yield one frame so each actor's controller script has bound its
	--> Initialize handler before we send the first SendMessage.
	RunService.PostSimulation:Wait()

	for _, actor in self._actors do
		actor:SendMessage(
			"Initialize",
			options.simulationModule,
			options.definitionsModule,
			options.payload,
			options.rollbackConfig
		)
	end

	return (setmetatable(self, Dispatcher) :: any) :: Dispatcher
end

--> Sends a Dispatch message to the actor with the lowest `Tasks` attribute.
function Dispatcher.dispatch(self: Dispatcher, ...: any)
	local actors = table.clone(self._actors)
	table.sort(actors, function(a: Actor, b: Actor): boolean
		return (a:GetAttribute("Tasks") :: number) < (b:GetAttribute("Tasks") :: number)
	end)
	actors[1]:SendMessage("Dispatch", ...)
end

--> Sends `messageName` with payload to every actor.
function Dispatcher.broadcast(self: Dispatcher, messageName: string, ...: any)
	for _, actor in self._actors do
		actor:SendMessage(messageName, ...)
	end
end

function Dispatcher.destroy(self: Dispatcher)
	for _, connection in self._connections do
		connection:Disconnect()
	end
	for _, actor in self._actors do
		actor:Destroy()
	end
	self._template:Destroy()
	table.clear(self._connections)
	table.clear(self._actors)
end

return Dispatcher
