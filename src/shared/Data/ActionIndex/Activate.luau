return {
    KeyCode = Enum.KeyCode.E,
    HoldDuration = 0.2,

    Validate = function(Player, Object, ObjectData)
        return ObjectData.Validate and ObjectData.Validate(Player, Object) or not Object:GetAttribute("Activated")
    end,
    
    Server = {
        Triggered = function(Player, Object, ObjectData)
            if not ObjectData.Activate then return end
            ObjectData.Activate(Player, Object)
        end,
        TriggerEnded = function(Player, Object)
        end,
        HoldBegan = function(Player, Object)
        end,
        HoldEnded = function(Player, Object)
        end,
    },
    Client = {
        Triggered = function(Object)
        end,
        TriggerEnded = function(Object)
        end,
        HoldBegan = function(Object)
        end,
        HoldEnded = function(Object)
        end,
    },
}