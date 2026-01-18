local PlayerLoadout = {}
PlayerLoadout.__index = PlayerLoadout

--[[

    PlayerLoadout
        Server model of a player's loadout. Data is stored here and synced to the client.
        Also handles serverside animations and actions.

--]]

function PlayerLoadout.new(Player:Player)
    local self = setmetatable({}, PlayerLoadout)

    self.Player = Player
    self.Character = Player.Character

    self.Tools = {}

    self.SelectedTool = nil 
    self.IsEquipped = false 
    self.StartSwap = tick() -- when equip/unequip started
    self.IsEquipping = false -- if currently equipping a tool

    self.CanChangeTool = true
    
    return self
end

-- Signals
function PlayerLoadout:CharacterAdded(Character:Model)
    
end

function PlayerLoadout:CharacterRemoving(Character:Model)
    
end

-- Net Signals
function PlayerLoadout:RequestEquipTool(ToolName:string): boolean
    -- Only equip is needed since "no tool" is just fists.
    if not self.CanChangeTool then return false end -- can't change tool

    if not ToolName then return false end
    if typeof(ToolName) ~= "string" then return false end
    if not self.Tools[ToolName] then return false end

    if self.IsEquipped and self.SelectedTool == ToolName then return false end -- already equipped
    if self.IsEquipping then return false end -- already equipping a tool
    

    -- TODO: Implement
    return true
end

-- Main methods
function PlayerLoadout:AddTool(ToolName:string)
    
end

function PlayerLoadout:RemoveTool(ToolName:string)
    
end

function PlayerLoadout:EquipTool(ToolName:string)
    
end

function PlayerLoadout:UnequipTool()
    
end

return PlayerLoadout
