local InputUtil = shared.Import("InputUtil")
local ToolBase = shared.Import("ToolBase")


local Firearm = setmetatable({}, ToolBase)
Firearm.__index = Firearm

function Firearm.new(ToolFolder: Folder)
    local self = setmetatable(ToolBase.new(ToolFolder), Firearm)
    self.Type = "Firearm"

    self.Equipped = true    

    self.State = {
        Ammo = self.Data.MagCapacity,
        StoredAmmo = self.Data.MagCapacity,
    
        Reloading = false,

        WishFire = false,
        WishADS = false,
        ADSStart = tick(),
        ADSEnd = tick(),

        LastShot = tick(),
        
    }

    -- Add update tasks
    self:AddUpdateTask("UpdateAimPart", 103.5, function(DeltaTime: number)
        local aimPart = self.Viewmodel:FindFirstChild("AimPart")
        if aimPart then
            local aimOffset = self.Viewmodel.PrimaryPart.CFrame:ToObjectSpace(aimPart.CFrame * self.Offsets.Base):Inverse()

            local position = aimOffset.Position
            local rotation = aimOffset - position

            local t = math.abs(math.sin(tick()/2))

            local newX = position.X * (1 - t)
            local newY = position.Y * (1 - t)^2

            local newPosition = Vector3.new(newX, newY, position.Z)
            local interpolatedCFrame = CFrame.new(newPosition) * rotation

            self.ViewmodelCFrame *= interpolatedCFrame
        end
    end)

    -- Bind input actionns
    InputUtil:BindAction("Reload", function(_, InputState)
        if InputState ~= Enum.UserInputState.Begin then return end
    
        self:WishReload()
    end, false, Enum.KeyCode.R)

    InputUtil:BindAction("Fire", function(_, InputState)
        self.State.WishFire = InputState == Enum.UserInputState.Begin
    end, false, Enum.UserInputType.MouseButton1)

    InputUtil:BindAction("ADS", function(_, InputState)
        self.State.WishADS = InputState == Enum.UserInputState.Begin
    end, false, Enum.UserInputType.MouseButton2)

    -- Create trove cleanup
    self.Trove:Add(function()
        InputUtil:UnbindAction("Reload")
        InputUtil:UnbindAction("Fire")
        InputUtil:UnbindAction("ADS")
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

        self:WishFire()
    end)

    self:AddUpdateTask("UpdateADS", 105, function(DeltaTime: number)
        if not self.State.WishADS then return end

        self:WishADS()
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
    Iris.Text({"Was Reloading: " .. (self.WasReloading and YesText or NoText), nil, nil, true})
    Iris.Text({"Wish Fire: " .. (self.State.WishFire and YesText or NoText), nil, nil, true})
    Iris.Text({"Last Shot: " .. math.round(self.State.LastShot)})
    Iris.Text({"Time Since Last Shot: " .. (CanFire and "<font color='rgb(0, 255, 0)'>" .. TimeSinceLastShot .. "</font>" or "<font color='rgb(255, 0, 0)'>" .. TimeSinceLastShot .. "</font>"), nil, nil, true})
    Iris.Text({"Can Fire: " .. (CanFire and YesText or NoText), nil, nil, true})
    Iris.Text({"Can Reload: " .. (CanReload and YesText or NoText), nil, nil, true})    
end

function Firearm:CanAction()
    return 
        self.Equipped
        and not self.Swapping
end

function Firearm:CanReload()
    return 
        self:CanAction()
        and self.State.Reloading == false
        and self.State.StoredAmmo > 0
        and self.State.Ammo <= self.Data.MagCapacity
end

function Firearm:WishReload()
    if not self:CanReload() then return end

    self.State.Reloading = true
    self.Animations.Reload:Play()
    self.HideCrosshair:Play()
end

function Firearm:Reload()
    self.State.Reloading = false
    self.ShowCrosshair:Play()

    local AmmoToAdd = self.Data.MagCapacity - self.State.Ammo
    self.State.Ammo = self.State.Ammo + AmmoToAdd
    self.State.StoredAmmo = self.State.StoredAmmo - AmmoToAdd
end

function Firearm:WishADS()
    if not self:CanAction() then return end
end

function Firearm:EndADS()
    self.State.ADSEnd = tick()
end

function Firearm:CanFire()
    return self:CanAction()
        and self.State.Ammo > 0 
        and (tick() - self.State.LastShot) >= 60 / self.Data.RPM
end

function Firearm:WishFire()
    if self.State.Ammo == 0 then
        self:WishReload()
    end

    if not self:CanFire() then return end

    if self.State.Reloading then
        self.Animations.Reload:Stop()
        self.ShowCrosshair:Play()
    end

    self.State.Ammo = self.State.Ammo - 1
    self.State.LastShot = tick()

    -- Simulate event
    -- TODO: IMPLEMENT HIT DETECTION AND ROLLBACKS

    -- Visuals
    self.Animations.Fire:Play(0)
end

function Firearm:StartUnequip()
    if self.State.Reloading then
        self.Animations.Reload:Stop()
        self.State.WasReloading = true
    end
end

function Firearm:EndEquip() 
    if self.State.WasReloading then
        self:WishReload()
        self.State.WasReloading = false
    end
end

return Firearm