local Actions = {
    ["Store"] = {
        KeyCode = Enum.KeyCode.F,
        HoldDuration = 1,
        Validate = function(...)
            return true
        end,
    },
}

for _, Action in ipairs(script:GetChildren()) do
    local ActionName = Action.Name
    local ActionData = require(Action)

    Actions[ActionName] = ActionData
end

return Actions