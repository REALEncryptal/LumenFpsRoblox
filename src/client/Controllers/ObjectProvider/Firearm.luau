local TweenService = game:GetService("TweenService")
local InputUtil = shared.Import("InputUtil")
local ToolBase = shared.Import("ToolBase")


local Firearm = setmetatable({}, ToolBase)
Firearm.__index = Firearm

function Firearm.new(ToolFolder: Folder)
    local self = setmetatable(ToolBase.new(ToolFolder), Firearm)
    self.Type = "Firearm" 

    self.State = {
        Ammo = self.Data.MagCapacity,
        StoredAmmo = self.Data.MagCapacity,
    
        Reloading = false,

        WasWishFire = false,
        WishFire = false,
        WishADS = false,
        ADS = false,
        ADSProgress = Instance.new("NumberValue"),

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

    InputUtil:BindAction("ADS", function(_, InputState)
        local WasWishADS = self.State.WishADS
        self.State.WishADS = InputState == Enum.UserInputState.Begin

        if WasWishADS ~= self.State.WishADS then
            if self.State.WishADS then
                self:StartADS()
            else
                self:EndADS()
            end
        end
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
        if self.State.WishFire then
            self:WishFire(not self.State.WasWishFire)
        end

        self.State.WasWishFire = self.State.WishFire
    end)

    -- Add update tasks
    self:AddUpdateTask("UpdateAimPart", 103.5, function(DeltaTime: number)
        local aimPart = self.Viewmodel:FindFirstChild("AimPart")
        if aimPart then
            local aimOffset = self.Data.Offsets.Aim--self.Viewmodel.PrimaryPart.CFrame:ToObjectSpace(aimPart.CFrame * self.Offsets.Base):Inverse()

    
            local t = 1-self.State.ADSProgress.Value

            self.State.ADS = t < .95
    
            self.ViewmodelCFrame *= aimOffset:Lerp(CFrame.new(), t)
        end
    end)

    return self
end

function Firearm:CreateDebug(Iris)
    local YesText = "<font color='rgb(0, 255, 0)'>Yes</font>"
    local NoText = "<font color='rgb(255, 0, 0)'>No</font>"

    local CanFire = self:CanFire()
    local CanReload = self:CanReload()
    local TimeSinceLastShot = math.round((tick() - self.State.LastShot) * 10)/10

    -- Ammunition information
    Iris.Text({"Ammo: " .. self.State.Ammo})
    Iris.Text({"Stored Ammo: " .. self.State.StoredAmmo})
    
    -- Fire status
    Iris.Text({"Can Fire: " .. (CanFire and YesText or NoText), nil, nil, true})
    Iris.Text({"Wish Fire: " .. (self.State.WishFire and YesText or NoText), nil, nil, true})
    Iris.Text({"Wish Fire (was): " .. (self.State.WasWishFire and YesText or NoText), nil, nil, true})
    
    Iris.Text({"Last Shot: " .. math.round(self.State.LastShot)})
    Iris.Text({"Time Since Last Shot: " .. (CanFire and "<font color='rgb(0, 255, 0)'>" .. TimeSinceLastShot .. "</font>" or "<font color='rgb(255, 0, 0)'>" .. TimeSinceLastShot .. "</font>"), nil, nil, true})
    
    -- Reload status
    Iris.Text({"Can Reload: " .. (CanReload and YesText or NoText), nil, nil, true})
    Iris.Text({"Reloading: " .. (self.State.Reloading and YesText or NoText), nil, nil, true})
    Iris.Text({"Was Reloading: " .. (self.WasReloading and YesText or NoText), nil, nil, true})
    
    -- ADS information
    Iris.Text({"Wish ADS: " .. (self.State.WishADS and YesText or NoText), nil, nil, true})
    Iris.Text({"ADS: " .. (self.State.ADS and YesText or NoText), nil, nil, true})
    Iris.Text({"ADS Progress: " .. self.State.ADSProgress.Value})
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

    if not self.State.ADS then
        self.ShowCrosshair:Play()
    end

    local AmmoToAdd = self.Data.MagCapacity - self.State.Ammo
    self.State.Ammo = self.State.Ammo + AmmoToAdd
    self.State.StoredAmmo = self.State.StoredAmmo - AmmoToAdd
end

function Firearm:StartADS()
    if not self:CanAction() then return end
    self.HideCrosshair:Play()
    TweenService:Create(self.State.ADSProgress, TweenInfo.new(self.Data.ADSTime), {Value = 1}):Play()
end

function Firearm:EndADS()
    if not self:CanAction() then return end
    self.ShowCrosshair:Play()
    TweenService:Create(self.State.ADSProgress, TweenInfo.new(self.Data.ADSTime), {Value = 0}):Play()
end

function Firearm:CanFire()
    return self:CanAction()
        and self.State.Ammo > 0 
        and (tick() - self.State.LastShot) >= 60 / self.Data.RPM
end

function Firearm:WishFire(IsClick:boolean)
    if not IsClick and not self.Data.Automatic then return end
    
    if IsClick and self.State.Ammo <= 0 then
        self:WishReload()
    end
    
    if not self:CanFire() then return end

    if self.State.Reloading then
        self.Animations.Reload:Stop()

        if not self.State.ADS then
            self.ShowCrosshair:Play()
        end
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
    self:EndADS()
end

function Firearm:EndEquip() 
    if self.State.WasReloading then
        self:WishReload()
        self.State.WasReloading = false
    end
end

return Firearm