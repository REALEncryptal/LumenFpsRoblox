--[[

    CITO LOADER
    Requires, initializes, and connects events for all modules.

    The Cito framework provides:
    - Automatic module discovery and loading
    - Priority-based initialization with dependency resolution
    - Automatic signal connections
    - Error handling for module loading and execution
    
    Encryptal 

--]]

-- Type definitions
--[[ 
    @class Controller
    A module that can be initialized and have signals connected
    @field Init (self: Controller) -> nil? - Initialization function called according to priority
    @field Priority number? - Priority value determining initialization order (lower = earlier)
    @field Dependencies {string}? - List of module names this controller depends on
    @field Signals table? - Table containing signal callbacks
]]
type Controller = {
	Init: ((self: Controller) -> nil)?,
	Priority: number?,
	Dependencies: {string}?,
	Signals: {
		Update: ((deltaTime: number) -> nil)?, -- Called every frame with deltaTime
		InputBegan: ((input: InputObject, gameProcessed: boolean) -> nil)?, -- Called when input is detected
		InputEnded: ((input: InputObject, gameProcessed: boolean) -> nil)?, -- Called when input is no longer detected
		PlayerAdded: ((player: Player) -> nil)?, -- Called when a player joins the game
		PlayerRemoving: ((player: Player) -> nil)?, -- Called when a player leaves the game
		CharacterAdded: ((character: Model) -> nil)?, -- Called when a character is added (client-only)
		CharacterRemoving: ((character: Model) -> nil)? -- Called when a character is removed (client-only)
	}?
}

--[[
    @class CitoInstance
    The main framework instance that manages modules and their lifecycle
    @field Controllers {Controller} - Array of loaded controller modules
    @field ControllerMap {[string]: Controller} - Map of controller names to controller instances
    @field Paths {Instance}? - Paths used for module discovery
]]
type CitoInstance = {
	Controllers: {Controller},
	ControllerMap: {[string]: Controller},
	Paths: {Instance}?,
	Discover: (self: CitoInstance, Path: {Instance}) -> CitoInstance,
	LoadModules: (self: CitoInstance, Path: Instance) -> CitoInstance,
	Init: (self: CitoInstance) -> CitoInstance
}

local Cito = {} :: CitoInstance
Cito.__index = Cito

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Librarian = require(script.Librarian)
local Constants = nil -- Will be loaded via Librarian

-- Map to track modules by name (for dependency resolution)
local moduleNames = {}

--[[
    @function Cito.new
    Creates a new instance of the Cito framework
    @return CitoInstance - A new Cito instance
]]
function Cito.new()
	local self = setmetatable({}, Cito) :: CitoInstance

	-- to get load time
	self.InitialTime = tick()
	self.Debug = true

	self.Controllers = {}
	self.ControllerMap = {}

	return self
end

--[[
    @function Cito:Discover
    Sets up discovery paths for modules and initializes the Librarian
    @param Path {Instance} - Array of paths to discover modules from
    @return CitoInstance - The Cito instance (for method chaining)
]]
function Cito:Discover(Path: {Instance})
	assert(Path, "Path cannot be nil")
	assert(typeof(Path) == "table", "Path must be a table")
	
	self.Paths = Path

	-- Wrap in pcall to catch any errors with Librarian initialization
	local success, errorMsg = pcall(function()
		Librarian:Init(self.Paths)
	end)
	
	if not success then
		warn("[Cito] Failed to initialize Librarian: " .. errorMsg)
	else
		-- Load Constants after Librarian is initialized
		local constantsSuccess, constantsError = pcall(function()
			Constants = Librarian.Import("Constants")
		end)
		
		if not constantsSuccess then
			warn("[Cito] Failed to load Constants: " .. tostring(constantsError))
			-- Create default Constants if loading fails
			Constants = {
				PRIORITY = {
					NORMAL = 500
				},
				Debug = function() end
			}
		end
		
		-- Create a shared import function that can be used by controllers
		rawset(_G, "shared", {})
		rawset(_G.shared, "Import", function(name)
			local result = nil
			local success, err = pcall(function()
				result = Librarian.Import(name)
			end)
			
			if not success then
				warn("[Cito] Failed to import module: " .. tostring(name) .. " - " .. tostring(err))
				return nil
			end
			
			return result
		end)
	end

	return self
end

--[[
    Helper function to get a controller's name
    @param controller Controller - The controller to get the name for
    @param index number - The index of the controller in the Controllers array
    @return string - The controller's name
]]
local function getControllerName(controller, index, controllerMap)
	-- Try to find the name in the controller map
	for name, ctrl in pairs(controllerMap) do
		if ctrl == controller then
			return name
		end
	end
	
	-- Fall back to a generic name with index
	return "Controller_" .. tostring(index)
end

--[[
    @function Cito:LoadModules
    Loads all modules from the specified path or table of ModuleScripts
    @param Path Instance | {ModuleScript} - Path containing modules to load or table of ModuleScripts
    @return CitoInstance - The Cito instance (for method chaining)
]]
function Cito:LoadModules(Path: Instance | {ModuleScript})
	assert(Path, "Path cannot be nil")
	assert(typeof(Path) == "Instance" or typeof(Path) == "table", "Path must be an Instance or table of ModuleScripts")
	
	if typeof(Path) == "Instance" then
		Path = Path:GetDescendants()
	end

	for _, Module in ipairs(Path) do
		if not Module:IsA("ModuleScript") then continue end

		-- Verify run context
		local IsServer = Module:GetAttribute("IsServer")
		if IsServer ~= nil then
			if RunService:IsServer() ~= IsServer then
				continue
			end
		end

		-- 
		local moduleName = Module.Name
		
		-- Safely require the module
		local success, loadedModule = pcall(function()
			return require(Module)
		end)

		if not success then
			warn("[Cito] Failed to require module " .. Module:GetFullName() .. ": " .. tostring(loadedModule))
			continue
		end

		-- Add metadata
		loadedModule._Cito = {
			_Module = Module
		}

		-- Store module in array and map
		table.insert(self.Controllers, loadedModule)
		self.ControllerMap[moduleName] = loadedModule
		
		-- Track module by name for dependency resolution
		moduleNames[loadedModule] = moduleName
	end

	return self
end

--[[
    Helper function to resolve dependencies and build an initialization order
    @param controllers {Controller} - Array of controllers to initialize
    @param controllerMap {[string]: Controller} - Map of controller names to controllers
    @return {Controller} - Array of controllers in initialization order
]]
local function resolveInitOrder(controllers, controllerMap)
	-- Create a copy of the controllers array
	local result = {}
	
	-- Map to track visited controllers (to detect circular dependencies)
	local visited = {}
	local initialized = {}
	
	-- Assign default priority if not set
	for _, controller in ipairs(controllers) do
		if not controller.Priority then
			controller.Priority = Constants.PRIORITY.NORMAL
		end
	end
	
	-- Helper function for depth-first traversal
	local function visit(controller, index)
		local name = getControllerName(controller, index, controllerMap)
		
		if initialized[controller] then
			return
		end
		
		if visited[controller] then
			warn("[Cito] Circular dependency detected involving controller: " .. name)
			return
		end
		
		visited[controller] = true
		
		-- Resolve dependencies first if they exist
		if controller.Dependencies then
			for _, depName in ipairs(controller.Dependencies) do
				local dependency = controllerMap[depName]
				
				if dependency then
					visit(dependency, index)
				else
					-- Try to use Librarian to import the dependency
					local importSuccess, importResult = pcall(function()
						return Librarian.Import(depName)
					end)
					
					if not importSuccess or not importResult then
						warn("[Cito] Dependency not found: " .. depName .. " required by " .. name)
					end
				end
			end
		end
		
		-- Mark as initialized and add to result
		initialized[controller] = true
		table.insert(result, controller)
		visited[controller] = false
	end
	
	-- Sort controllers by priority (lower first)
	table.sort(controllers, function(a, b) 
		return (a.Priority or Constants.PRIORITY.NORMAL) < (b.Priority or Constants.PRIORITY.NORMAL) 
	end)
	
	-- Visit each controller in priority order
	for i, controller in ipairs(controllers) do
		if not initialized[controller] then
			visit(controller, i)
		end
	end
	
	return result
end

--[[
    @function Cito:Init
    Initializes all loaded modules in order of priority and dependency, then connects their signal handlers
    @return CitoInstance - The Cito instance (for method chaining)
]]
function Cito:Init()
	-- Determine initialization order based on priorities and dependencies
	local orderedControllers = resolveInitOrder(self.Controllers, self.ControllerMap)
	
	-- Initialize controllers in resolved order
	for i, module in ipairs(orderedControllers) do
		local name = getControllerName(module, i, self.ControllerMap)
		
		-- Skip if already initialized
		if module._Cito and module._Cito._Initialized then
			continue
		end

		if module._Raw then continue end
			
		module._Cito._Initialized = true
		module._Cito._InitTime = tick()
		
		if module.Init then
			local success, error = pcall(function()
				self:DebugPrint("Initializing " .. name)
				module:Init()
			end)
			
			if not success then
				warn("[Cito] Error in Init for " .. name .. ": " .. tostring(error))
			end
		end
	end

	-- Map of built-in signals to connection functions
	local BuiltFunctions = {
		Update = function(Callback)
			if RunService:IsClient() then
				RunService.RenderStepped:Connect(Callback)
			else
				RunService.Heartbeat:Connect(Callback)
			end
		end,
		InputBegan = function(Callback)
			UserInputService.InputBegan:Connect(Callback)
		end,
		InputEnded = function(Callback)
			UserInputService.InputEnded:Connect(Callback)
		end,
		PlayerAdded = function(Callback)
			game.Players.PlayerAdded:Connect(Callback)
		end,
		PlayerRemoving = function(Callback)
			game.Players.PlayerRemoving:Connect(Callback)
		end,
		CharacterAdded = function(Callback)
			if not RunService:IsClient() then return end
			game.Players.LocalPlayer.CharacterAdded:Connect(Callback)
		end,
		CharacterRemoving = function(Callback)
			if not RunService:IsClient() then return end
			game.Players.LocalPlayer.CharacterRemoving:Connect(Callback)
		end
	}
	
	-- Connect all signal handlers from modules
	for Name, Function in pairs(BuiltFunctions) do
		for i, Module in ipairs(self.Controllers) do
			local moduleName = getControllerName(Module, i, self.ControllerMap)
			
			-- Skip if module doesn't have signals or this specific signal
			if not Module.Signals or not Module.Signals[Name] then continue end
			
			-- Skip if this signal has already been connected for this module
			if Module._Cito and Module._Cito._ConnectedSignals and Module._Cito._ConnectedSignals[Name] then
				continue
			end
			
			-- Initialize _ConnectedSignals if needed
			if not Module._Cito then
				Module._Cito = {
					_Initialized = false,
					_InitTime = nil,
					_Module = Module,
					_ConnectedSignals = {}
				}
			elseif not Module._Cito._ConnectedSignals then
				Module._Cito._ConnectedSignals = {}
			end
			
			-- Create a wrapper function that can properly handle varargs
			local signalHandler = Module.Signals[Name]
			Function(function(...)
				local args = {...}
				local success, err = pcall(function()
					signalHandler(unpack(args))
				end)
				
				if not success then
					warn("[Cito] Error in signal handler " .. Name .. " for " .. moduleName .. ": " .. tostring(err))
				end
			end)
			
			-- Mark this signal as connected
			Module._Cito._ConnectedSignals[Name] = true
		end
	end

	return self
end

function Cito:DebugPrint(...)
	if not self.Debug then return end

	local isClient = RunService:IsClient()
	
	
	print(isClient and "Client" or "Server", "[Cito]", ...)
end

return Cito
