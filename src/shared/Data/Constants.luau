local Constants = {
    -- PLACE
    VERSION = 1,
    DEBUG = false,

    -- 
    ToolScale = 1,

    
    -- PRIORITY LEVELS FOR CITO INITIALIZATION
    PRIORITY = {
        -- 1-100: Core services
        FIRST = 1,          -- Absolute first (data stores, critical services)
        CORE = 50,          -- Core systems (network, fundamental game services)
        
        -- 101-300: Game systems
        EARLY = 150,        -- Early-initialized systems (world, physics)
        
        -- 301-700: Gameplay elements
        NORMAL = 500,       -- Standard priority (most gameplay systems)
        
        -- 701-900: UI and feedback systems
        INTERFACE = 800,    -- UI systems
        
        -- 901-1000: Non-critical systems
        LATE = 950,         -- Non-critical systems (analytics, effects)
        LAST = 1000         -- Absolute last
    }
}

--[[
    @function Constants:Debug
    Prints a message if DEBUG is enabled
    @param ... any - Arguments to print
]]
function Constants:Debug(...)
    if not Constants.DEBUG then return end
    print(...)
end

--[[
    @function Constants:DebugFunction
    Calls a function if DEBUG is enabled
    @param Function function - The function to call
    @param ... any - Arguments to pass to the function
]]
function Constants:DebugFunction(Function, ...)
    if not Constants.DEBUG then return end
    Function(...)
end


return Constants