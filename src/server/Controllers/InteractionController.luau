local Controller = {
    Signals = {},
    Priority = 50
}
Controller.PendingActions = {}
local Net, ActionIndex, ObjectIndex

function Controller:PreInit()
    Controller.PendingActions = {}
end

function Controller:Init()
    Net = shared.Import "Net"
    ActionIndex = shared.Import "ActionIndex"
    ObjectIndex = shared.Import "ObjectIndex"

    Controller.Remotes = {}
    Controller.Remotes.ActionCancelled = Net:RemoteEvent("ActionCancelled")
    Controller.Remotes.ActionStart = Net:RemoteEvent("ActionStart")
    Controller.Remotes.ActionFailed = Net:RemoteEvent("ActionFailed")
    Controller.Remotes.ActionSignal = Net:RemoteEvent("ActionSignal")

    Controller.Remotes.ActionCancelled.OnServerEvent:Connect(Controller._ActionCancelled)
    Controller.Remotes.ActionStart.OnServerEvent:Connect(Controller._StartAction)
end

function Controller.Signals.Update(DeltaTime, Connection)
    local CurrentTick = tick()

    for Object, PendingAction in pairs(Controller.PendingActions) do
        if PendingAction.Completed then continue end

        local EndTick = PendingAction.EndTick
        local Complete = CurrentTick >= EndTick
        local Player = PendingAction.Player

        if not Complete then continue end

        Controller.PendingActions[Object].Completed = true
        Controller:_CallActionSignal("Triggered", Player, Object, PendingAction.ActionName)
    end
end

--

function Controller._ActionCancelled(Player, Object, ActionName)
    local PendingAction = Controller.PendingActions[Object]
    if not PendingAction then return end

    if PendingAction.Completed then
        Controller:_CallActionSignal("TriggerEnded", Player, Object, ActionName)
    end

    Controller:_CallActionSignal("HoldEnded", Player, Object, ActionName)

    -- Remove the pending action
    Controller.PendingActions[Object] = nil
end

function Controller._StartAction(Player, Object, ActionName)
    local ActionData = ActionIndex[ActionName]
    if not ActionData then return end

    -- Validate the action
    local ObjectData = ObjectIndex[Object.Name]
    if not ActionData.Validate(Player, Object, ObjectData) then
        warn("Server action failed")
        Controller.Remotes.ActionFailed:FireClient(Player, Object)
        return
    end

    local HoldDuration = ActionData.HoldDuration
    
    if ObjectData.ActionSettings and ObjectData.ActionSettings[ActionName] then
        HoldDuration = ObjectData.ActionSettings[ActionName].HoldDuration
    end

    local EndTick = tick() + HoldDuration

    local PendingAction = {
        Player = Player,
        EndTick = EndTick,
        Completed = false,
        ActionName = ActionName
    }

    Controller.PendingActions[Object] = PendingAction
    Controller:_CallActionSignal("HoldBegan", Player, Object, ActionName)
end
--

function Controller:_CallActionSignal(SignalName, Player, Object, ActionName)
    local ActionData = ActionIndex[ActionName]

    if not ActionData.Server then return end
    local Callback = ActionData.Server[SignalName]
    local ObjectData = ObjectIndex[Object.Name]
    if Callback then
        Callback(Player, Object, ObjectData)
    end

    Controller.Remotes.ActionSignal:FireClient(Player, SignalName, Object, ActionName)
end

--

return Controller