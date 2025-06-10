local Util = {}

function Util:ServeTrack(AnimationTrack:AnimationTrack): () -> ()
    local AnimationEvents = shared.Import("AnimationEvents")

    local Connections = {}

    for EventName, EventFunction in pairs(AnimationEvents) do
        Connections[EventName] = AnimationTrack:GetMarkerReachedSignal(EventName):Connect(function(...)
            print("AnimationEvent: " .. EventName, " - Args: ", ...)
            EventFunction(...)
        end)
    end

    return function ()
        for _, Connection in pairs(Connections) do
            Connection:Disconnect()
        end
    end
end

return Util