local InputUtil = shared.Import("InputUtil")
local ToolBase = shared.Import("ToolBase")


local Firearm = setmetatable({}, ToolBase)
Firearm.__index = Firearm

function Firearm.new(ToolFolder: Folder)
    local self = setmetatable(ToolBase.new(ToolFolder), Firearm)

    self.Equipped = true    

    self.State = {
        Ammo = self.Data.MagCapacity,
        StoredAmmo = self.Data.MagCapacity,
    
        Reloading = false,

        WishFire = false,

        LastShot = tick(),
    }

    -- Bind input actionns
    InputUtil:BindAction("Reload", function(_, InputState)
        if InputState ~= Enum.UserInputState.Begin then return end
    
        self:WishReload()
    end, false, Enum.KeyCode.R)

    InputUtil:BindAction("Fire", function(_, InputState)
        self.State.WishFire = InputState == Enum.UserInputState.Begin
    end, false, Enum.UserInputType.MouseButton1)

    -- Create trove cleanup
    self.Trove:Add(function()
        InputUtil:UnbindAction("Reload")
        InputUtil:UnbindAction("Fire")
    end)

    -- Add animation events
    self.Trove:Add(self.Animations.Reload:GetMarkerReachedSignal("MagIn"):Connect(function()
        self:Reload()
    end))

    self.Trove:Add(self.Animations.Reload.Stopped:Connect(function()
        self.State.Reloading = false
    end))

    -- Add update tasks
    self:AddUpdateTask("UpdateFire", 104, function(DeltaTime: number)
        if not self.State.WishFire then return end
        if not self:CanFire() then return end

        self:Fire()
    end)

    return self
end

function Firearm:CreateDebug(Iris)
    local YesText = "<font color='rgb(0, 255, 0)'>Yes</font>"
    local NoText = "<font color='rgb(255, 0, 0)'>No</font>"

    local CanFire = self:CanFire()
    local CanReload = self:CanReload()
    local TimeSinceLastShot = math.round((tick() - self.State.LastShot) * 10)/10

    Iris.Text({"Ammo: " .. self.State.Ammo})
    Iris.Text({"Stored Ammo: " .. self.State.StoredAmmo})
    Iris.Text({"Reloading: " .. (self.State.Reloading and YesText or NoText), nil, nil, true})
    Iris.Text({"Wish Fire: " .. (self.State.WishFire and YesText or NoText), nil, nil, true})
    Iris.Text({"Last Shot: " .. math.round(self.State.LastShot)})
    Iris.Text({"Time Since Last Shot: " .. (CanFire and "<font color='rgb(0, 255, 0)'>" .. TimeSinceLastShot .. "</font>" or "<font color='rgb(255, 0, 0)'>" .. TimeSinceLastShot .. "</font>"), nil, nil, true})
    Iris.Text({"Can Fire: " .. (CanFire and YesText or NoText), nil, nil, true})
    Iris.Text({"Can Reload: " .. (CanReload and YesText or NoText), nil, nil, true})    
end

function Firearm:CanReload()
    return self.State.Reloading == false
        and self.State.StoredAmmo > 0
        and self.State.Ammo <= self.Data.MagCapacity
end

function Firearm:WishReload()
    if not self:CanReload() then return end

    self.State.Reloading = true
    self.Animations.Reload:Play()
end

function Firearm:Reload()
    local AmmoToAdd = self.Data.MagCapacity - self.State.Ammo
    self.State.Ammo = self.State.Ammo + AmmoToAdd
    self.State.StoredAmmo = self.State.StoredAmmo - AmmoToAdd
end

function Firearm:CanFire()
    return self.State.Ammo > 0 
        and self.Equipped 
        and not self.Swapping
        and (tick() - self.State.LastShot) >= 60 / self.Data.RPM
end

function Firearm:Fire()
    if not self:CanFire() then return end

    self.State.Ammo = self.State.Ammo - 1
    self.State.LastShot = tick()

    -- Simulate event
    -- TODO: IMPLEMENT HIT DETECTION AND ROLLBACKS

    -- Visuals
    self.Animations.Fire:Play()
end

return Firearm