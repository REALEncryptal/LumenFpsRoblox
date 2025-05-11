local ToolManager = {}
ToolManager.__index = ToolManager

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Trove = shared.Import("trove")
local Net = shared.Import("net")

local ToolBase = shared.Import("ToolBase")
local Firearm = shared.Import("Firearm")
local DebugController = shared.Import("DebugController")
local InterfaceController = shared.Import("InterfaceController")

local ClassMap = {
    ToolBase = ToolBase,
    Firearm = Firearm,
}

function ToolManager.new( Character:Model )

    assert(Character, "ToolManager.New - Character is nil")
    assert(typeof(Character) == "Instance", "ToolManager.New - Character is not an Instance")
    assert(Character:IsA("Model"), "ToolManager.New - Character is not a Model")

    local self = setmetatable({}, ToolManager)

    self.Trove = Trove.new()
    self.Character = Character

    self.Tools = {}

    self.Trove:Add(function()
       for ToolName, ToolObject in pairs(self.Tools) do
           ToolObject:Destroy()
           self.Tools[ToolName] = nil
       end
    end)

    local Iris = DebugController.Iris
    self.Trove:Add(Iris:Connect(function()
        local windowSize = Iris.State(Vector2.new(300, 400))
        Iris.Window({"Tool Manager"}, {size = windowSize})

		Iris.Text({"Current Tools: " .. #self.Tools})

        Iris.Indent()

		for ToolName, ToolObject in pairs(self.Tools) do
			Iris.Tree({"Tool: " .. ToolName .. " - " .. ToolObject.Data.Name})

            if Iris.Button({ToolObject.Equipped and "Unequip" or "Equip"}).clicked() then
                if ToolObject.Equipped then
                    self:UnequipTool(ToolName)
                else
                    self:EquipTool(ToolName)
                end
            end
            
            if ToolObject.Data.HudImage then
                Iris.Image({ToolObject.Data.HudImage,UDim2.new(.5,.1,.2,.1),nil,Enum.ScaleType.Fit})
            end

            local YesText = "<font color='rgb(0, 255, 0)'>Yes</font>"
            local NoText = "<font color='rgb(255, 0, 0)'>No</font>"

            Iris.Text({"Equipped: " .. (ToolObject.Equipped and YesText or NoText), nil, nil, true})
            Iris.Text({"Swapping: " .. (ToolObject.Swapping and YesText or NoText), nil, nil, true})

            if ToolObject.Swapping then
                Iris.Indent()
                Iris.Text({"Swap To: " .. (ToolObject.Equipping and "Equipping" or "Unequipping")})
                Iris.End()
            end
            
            ToolObject:CreateDebug(Iris)

            Iris.End()
		end
        
        Iris.End() -- indent
        
	    Iris.End()
    end))
    
    return self
end

-- Main methods
function ToolManager:AddTool( ToolName:string )
    local ToolFolder = ReplicatedStorage.Weapons:FindFirstChild(ToolName)
    assert(ToolFolder, "ToolManager.AddTool - ToolFolder is nil")
    local ToolData = require(ToolFolder:FindFirstChildOfClass("ModuleScript"))
    
    local ToolObject = ClassMap[ToolData.Type].new(ToolFolder)
    
    self.Tools[ToolName] = ToolObject

    return ToolObject
end

function ToolManager:RemoveTool( ToolName:string )
    local ToolObject = self.Tools[ToolName]
    
    if not ToolObject then return end

    ToolObject:Destroy()
    self.Tools[ToolName] = nil
end

function ToolManager:EquipTool( ToolName:string )
    local ToolObject = self.Tools[ToolName]
    
    if not ToolObject then return end

    ToolObject:Equip()
    InterfaceController.WeaponUI.ToolObject = ToolObject
end

function ToolManager:UnequipTool( ToolName:string )
    local ToolObject = self.Tools[ToolName]
    
    if not ToolObject then return end

    ToolObject:Unequip()
    InterfaceController.WeaponUI.ToolObject = nil
end

function ToolManager:UnequipAllTools()
    for _, ToolObject in pairs(self.Tools) do
        if not ToolObject then continue end
        ToolObject:Unequip()
    end
end

function ToolManager:SwapTool( NewToolName:string )
    if not self.Tools[NewToolName] then return end
    
    self:UnequipAllTools()
    self:EquipTool(NewToolName)
end

function ToolManager:Update( DeltaTime: number )
    for _, ToolObject in pairs(self.Tools) do
        if not ToolObject then continue end
        ToolObject:Update(DeltaTime)
    end
end

-- Cleanup
function ToolManager:Destroy()
    self.Trove:Destroy()
end

return ToolManager
