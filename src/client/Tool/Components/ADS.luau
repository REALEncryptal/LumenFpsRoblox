--[[
    ADS Component

    Aim-down-sights: holding MB2 tweens FOV in, fades the vignette, and lerps
    the viewmodel toward the tool's AimPart so the iron sights / scope line up
    with the camera. Releasing MB2 reverses everything.

    Config:
        FOV  number? — narrow FOV while aiming (defaults to Data.ADSFOV)
        Time number? — tween duration (defaults to Data.ADSTime)

    Used by other components:
        ads:IsAiming()                — for MagReload's FOV crossfade decision
        ads:StartADS() / :EndADS()    — for Firearm.StartUnequip to bail out
]]

local TweenService = game:GetService("TweenService")

local CameraController = shared.Import("CameraController")
local SettingsController = shared.Import("SettingsController")
local InterfaceController = shared.Import("InterfaceController")
local InteractionController = shared.Import("InteractionController")
local Constants = shared.Import("Constants")
local CFrameUtil = shared.Import("CFrameUtil")
local Trove = shared.Import("Trove")

local AIM_THRESHOLD = 0.95
local VIGNETTE_AIMING = 0
local VIGNETTE_HIPFIRE = 0.8

local ADS = {}
ADS.__index = ADS

ADS.Bindings = {
    ADS = {
        Inputs = {Enum.UserInputType.MouseButton2},
        OnState = function(self, state)
            local wasWishADS = self.WishADS
            self.WishADS = state == Enum.UserInputState.Begin
            if wasWishADS == self.WishADS then return end

            if self.WishADS then
                self:StartADS()
            else
                self:EndADS()
            end
        end,
    },
}

function ADS.new(tool, config)
    local self = setmetatable({}, ADS)
    self.Tool = tool
    self.Config = config

    self.WishADS = false
    self.Aiming = false
    self.Progress = Instance.new("NumberValue")
    self.Progress.Value = 0

    self.Trove = Trove.new()
    self.Trove:Add(self.Progress)
    return self
end

function ADS:_fov(): number
    return self.Config.FOV or self.Tool.Data.ADSFOV
end

function ADS:_time(): number
    return self.Config.Time or self.Tool.Data.ADSTime
end

function ADS:_magReload()
    return self.Tool:GetComponent("MagReload")
end

function ADS:Init()
    -- Lerps the viewmodel toward the AimPart attachment. Priority 103.5 slots
    -- between ToolBase's viewmodel-CFrame build (103) and its set (104), same
    -- as the legacy Firearm.UpdateAimPart task.
    self.Tool:AddUpdateTask("UpdateAimPart", 103.5, function(_dt)
        local aimPart = self.Tool.Viewmodel:FindFirstChild("AimPart")
        if not aimPart then return end

        local aimOffset = workspace:GetAttribute("AimOffset")
            or CFrameUtil.Scale(self.Tool.Data.Offsets.Aim, Constants.ToolScale)

        local t = 1 - self.Progress.Value
        self.Aiming = t < AIM_THRESHOLD

        self.Tool.ViewmodelCFrame *= aimOffset:Lerp(CFrame.new(), t)
    end)

    self.Trove:Add(function()
        self.Tool:RemoveUpdateTask("UpdateAimPart")
    end)
end

function ADS:IsAiming(): boolean
    return self.Aiming
end

function ADS:_canTransition(): boolean
    return self.Tool.Equipped and not self.Tool.Swapping
end

function ADS:StartADS()
    if not self:_canTransition() then return end

    InteractionController.Enabled = false
    self.Tool:HideCrosshair()
    InterfaceController.EffectUI.Vignette = VIGNETTE_AIMING

    CameraController:TweenFOV(self:_fov(), self:_time())
    TweenService:Create(self.Progress, TweenInfo.new(self:_time()), {Value = 1}):Play()
end

function ADS:EndADS()
    if not self:_canTransition() then return end

    -- Crosshair returns unless we're still mid-reload (MagReload will re-show
    -- it on its own when the mag swaps).
    local reload = self:_magReload()
    if not (reload and reload.Reloading) then
        InteractionController.Enabled = true
        self.Tool:ShowCrosshair()
    end

    InterfaceController.EffectUI.Vignette = VIGNETTE_HIPFIRE
    CameraController:TweenFOV(SettingsController:GetSetting("FOV"), self:_time())
    TweenService:Create(self.Progress, TweenInfo.new(self:_time()), {Value = 0}):Play()
end

function ADS:Unequip()
    -- Bail out of any in-flight aim so the next tool starts in hipfire state.
    if self.WishADS or self.Progress.Value > 0 then
        self.WishADS = false
        self:EndADS()
    end
end

function ADS:CreateDebug(Iris)
    local YesText = "<font color='rgb(0, 255, 0)'>Yes</font>"
    local NoText = "<font color='rgb(255, 0, 0)'>No</font>"

    Iris.Text({"Wish ADS: " .. (self.WishADS and YesText or NoText), nil, nil, true})
    Iris.Text({"Aiming: " .. (self.Aiming and YesText or NoText), nil, nil, true})
    Iris.Text({"ADS Progress: " .. self.Progress.Value})

    Iris.Separator()
    if Iris.Button({"Set Aim Offset"}).clicked() then
        local v = self.Tool.Viewmodel
        local aimPart = v:FindFirstChild("AimPart")
        if aimPart then
            workspace:SetAttribute(
                "AimOffset",
                v.PrimaryPart.CFrame:ToObjectSpace(
                    aimPart.CFrame * (workspace:GetAttribute("BaseOffset") or self.Tool.Offsets.Base)
                ):Inverse()
            )
        end
    end
    if Iris.Button("Print Aim Offset").clicked() then
        print(workspace:GetAttribute("AimOffset"))
    end
end

function ADS:Destroy()
    self.Trove:Destroy()
end

return ADS
