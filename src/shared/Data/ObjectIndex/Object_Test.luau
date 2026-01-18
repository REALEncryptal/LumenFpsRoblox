return  {
    Name = "Test Object!!",
    Description = "This is a test object!",

    Weight = 1,

    Actions = {
        "Store",
        "Activate",
    },

    ActionSettings = {
        Store = {
            HoldDuration = 2,
        }
    },

    Validate = function() return true end,
    Activate = function(Player, Object)
        shared.Import("Net"):RemoteEvent("PlayCutscene"):FireClient(Player, "TestScene")
    end,
}