local InputUtil = shared.Import("InputUtil")
local ToolBase = shared.Import("ToolBase")


local Firearm = setmetatable({}, ToolBase)
Firearm.__index = Firearm

function Firearm.new(ToolFolder: Folder)
    local self = setmetatable(ToolBase.new(ToolFolder), Firearm)

    self.ToolState = {
        Reloading = false
    }

    InputUtil:BindAction("Reload", function(_, InputState)
        if InputState ~= Enum.UserInputState.Begin then return end
    
        self:Reload()
    end, false, Enum.KeyCode.R)

    self.Trove:Add(function()
        InputUtil:UnbindAction("Reload")
    end)

    self.Trove:Add(self.Animations.Reload:GetMarkerReachedSignal("MagIn"):Connect(function()
        print("MagIn")
    end))

    self.Trove:Add(self.Animations.Reload.Stopped:Connect(function()
        print("Completed")
        self.ToolState.Reloading = false
    end))

    return self
end

function Firearm:Reload()
    if self.ToolState.Reloading then return end
    print(self.ToolState.Reloading)
    self.ToolState.Reloading = true
    self.Animations.Reload:Play()
end


return Firearm