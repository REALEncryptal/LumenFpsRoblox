local TweenService = game:GetService("TweenService")

local Controller = {
    Signals = {}
}

Controller.Priority = 20

local SettingsController
function Controller:Init()
    SettingsController = shared.Import("SettingsController")
    Controller.Instance = workspace.CurrentCamera

    Controller:SetFOV(SettingsController:GetSetting("FOV"))
end

-- FIELD OF VIEW
function Controller:SetFOV(FOV: number)
    Controller.Instance.FieldOfView = FOV
end

function Controller:TweenFOV(FOV: number, Time: number, EasingStyle: Enum.EasingStyle?)
    EasingStyle = EasingStyle or Enum.EasingStyle.Quad
    TweenService:Create(
        Controller.Instance,
        TweenInfo.new(Time, EasingStyle),
        {FieldOfView = FOV}
    ):Play()
end

return Controller