local ToolManager = {}
ToolManager.__index = ToolManager

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Trove = shared.Import("Trove")
local Net = shared.Import("Net")

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

    -- DEBUG
    local Iris = DebugController.Iris
    local OffsetEditorEnabled = false

    self.Trove:Add(Iris:Connect(function()
        local windowSize = Iris.State(Vector2.new(240, 580))
        local windowPos = Iris.State(Vector2.new(10, 0))
        local editorWindowSize = Iris.State(Vector2.new(300, 125))
        local editorWindowPos = Iris.State(Vector2.new(260, 0))


        -- Tool manager window
        Iris.Window({"Tool Manager"}, {size = windowSize, position = windowPos})

        if Iris.Button("Toggle Offset Editor").clicked() then
            OffsetEditorEnabled = not OffsetEditorEnabled

            if not OffsetEditorEnabled then
                workspace:SetAttribute("BaseOffset", nil)
            end
        end

        if OffsetEditorEnabled then
            Iris.Window({"Offset Editor", nil,nil,true,true}, {size = editorWindowSize, position = editorWindowPos})

            local Args = {
                "X",
                0.025,
                -5,
                5
            }
            local X = Iris.InputNum(Args)

            Args[1] = "Y"
            local Y = Iris.InputNum(Args)

            Args[1] = "Z"
            local Z = Iris.InputNum(Args)

            Iris.SameLine()
            if Iris.Button("Reset to Data Offset").clicked() and self.EquippedTool then
                local ToolObject = self.Tools[self.EquippedTool]
                X.state.number:set(ToolObject.Data.Offsets.Base.X)
                Y.state.number:set(ToolObject.Data.Offsets.Base.Y)
                Z.state.number:set(ToolObject.Data.Offsets.Base.Z)
            end

            local BaseOffset = CFrame.new(X.state.number.value, Y.state.number.value, Z.state.number.value)
            workspace:SetAttribute("BaseOffset", BaseOffset)

            if Iris.Button("Print").clicked() then
                print(BaseOffset)
            end
            Iris.End()

            Iris.End()
        end

        Iris.Separator()

        Iris.TabBar()
		for ToolName, ToolObject in pairs(self.Tools) do
			Iris.Tab({ToolObject.Data.Name})
            Iris.Indent()

            if Iris.Button({ToolObject.Equipped and "Unequip" or "Equip"}).clicked() then
                if ToolObject.Equipped then
                    self:UnequipTool(ToolName)
                else
                    self:EquipTool(ToolName)
                end
            end

            if ToolObject.Data.HudImage then
                Iris.Image({ToolObject.Data.HudImage,UDim2.new(.5,.1,.1,.1),nil,Enum.ScaleType.Fit})
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
            Iris.End()
		end

        Iris.End()
        
	    Iris.End()
    end))
    
    return self
end

-- Main methods
function ToolManager:HideTools(Hide: boolean)
    for _, ToolObject in pairs(self.Tools) do
        ToolObject:Hide(Hide)
    end

    InterfaceController.WeaponUI.Instance.Visible = not Hide
    InterfaceController.EffectUI.VignetteInstance.Visible = not Hide
end

function ToolManager:AddTool( ToolName:string )
    local ToolFolder = ReplicatedStorage.Weapons:FindFirstChild(ToolName)
    assert(ToolFolder, "ToolManager.AddTool - ToolFolder is nil")
    local ToolData = require(ToolFolder:FindFirstChildOfClass("ModuleScript"))
    local ToolObject = ClassMap[ToolData.Type].new(ToolFolder)
    if not ToolObject then
        warn("ToolManager.AddTool - ToolObject is nil for " .. ToolName)
        return
    end
    
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

    if self.EquippedTool then
        self:UnequipTool(self.EquippedTool, ToolObject)
    end

    if ToolName == "Fists" then
        InterfaceController.WeaponUI.Hide:Play()
    else
        InterfaceController.WeaponUI.Show:Play()
    end

    self.EquippedTool = ToolName
    ToolObject:Equip()
    InterfaceController.WeaponUI.ToolObject = ToolObject
end

function ToolManager:UnequipTool( ToolName:string, NextTool )
    local ToolObject = self.Tools[ToolName]
    if not ToolObject then return end

    if ToolName=="Fists" and not NextTool then -- cant unequip nothing
        return
    end
    
    ToolObject:Unequip(NextTool)
    self.EquippedTool = nil

    if not NextTool then
        self:EquipTool("Fists")
    end
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
