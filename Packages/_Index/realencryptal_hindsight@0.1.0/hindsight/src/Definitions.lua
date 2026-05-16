--!strict

--> Main-thread definitions registry. Mirrors what the actors see (same source
--> module, re-required on the main thread for the lookup). Two jobs:
--> - Resolve `type` → ProjectileDefinition
--> - Translate positional Output args from actors back into the typed ctx
-->   table the user's callback expects

local Types = require(script.Parent.Types)

type Self = {
	_module: ModuleScript,
	_byType: { [string]: Types.ProjectileDefinition },
}

local Definitions = {}
Definitions.__index = Definitions

export type Definitions = typeof(setmetatable({} :: Self, Definitions))

function Definitions.new(module: ModuleScript): Definitions
	local byType = require(module) :: { [string]: Types.ProjectileDefinition }
	local self: Self = {
		_module = module,
		_byType = byType,
	}
	return (setmetatable(self, Definitions) :: any) :: Definitions
end

function Definitions.get(self: Definitions, type: string): Types.ProjectileDefinition?
	return self._byType[type]
end

--> Wire protocol from actor → main thread (positional, see Simulation/init.lua):
--> onImpact:       type, caster, direction, instance, normal, position, material, extra
--> onIntersection: type, caster, direction, part, player, character, position, extra
--> onDestroyed:    type, caster, position, extra
function Definitions.dispatch(self: Definitions, action: string, ...: any)
	local type = (select(1, ...) :: any) :: string
	local definition = self._byType[type]
	if not definition then
		return
	end
	local callback = (definition :: any)[action]
	if not callback then
		return
	end

	if action == "onImpact" then
		local _, caster, direction, instance, normal, position, material, extra = ...
		callback({
			type = type,
			caster = caster,
			direction = direction,
			instance = instance,
			normal = normal,
			position = position,
			material = material,
			extra = extra,
		})
	elseif action == "onIntersection" then
		local _, caster, direction, part, player, character, position, extra = ...
		callback({
			type = type,
			caster = caster,
			direction = direction,
			part = part,
			player = player,
			character = character,
			position = position,
			extra = extra,
		})
	elseif action == "onDestroyed" then
		local _, caster, position, extra = ...
		callback({
			type = type,
			caster = caster,
			position = position,
			extra = extra,
		})
	end
end

return Definitions
