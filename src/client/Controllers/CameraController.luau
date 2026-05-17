local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Controller = {
    Signals = {}
}

Controller.Priority = 20

-- Source-style snap recoil. Each shot rotates the aim to a new orientation
-- instantly and the offset persists — no decay, no return wobble. Player
-- compensates by aiming back with the mouse, like spraying an AK in CS.
--
-- Roblox's default Custom camera re-derives Camera.CFrame from its internal
-- pitch/yaw each frame, so a one-time rotation would be overwritten on the
-- next frame. We re-apply Punch every render step at Camera+2 (after the
-- default camera AND MovementController's eye-height bind at Camera+1) to
-- keep the offset stuck on top of mouse-look.
Controller.Punch = Vector2.new()

local RECOIL_BIND = "Lumen_RecoilApply"

local SettingsController
function Controller:Init()
    SettingsController = shared.Import("SettingsController")
    Controller.Instance = workspace.CurrentCamera

    Controller:SetFOV(SettingsController:GetSetting("FOV"))

    RunService:BindToRenderStep(RECOIL_BIND, Enum.RenderPriority.Camera.Value + 2, function()
        if Controller.Punch.Magnitude > 1e-4 then
            Controller.Instance.CFrame = Controller.Instance.CFrame
                * CFrame.Angles(math.rad(Controller.Punch.X), math.rad(Controller.Punch.Y), 0)
        end
    end)
end

-- Snap kick. Pitch is degrees of upward rotation (positive = up); Yaw is
-- degrees of horizontal rotation (callers should randomize sign so bursts
-- spray instead of drifting one direction). Offset is permanent until the
-- player aims back or ResetRecoil is called.
function Controller:ApplyRecoil(Pitch: number, Yaw: number)
    Controller.Punch = Controller.Punch + Vector2.new(Pitch, Yaw)
end

function Controller:ResetRecoil()
    Controller.Punch = Vector2.new()
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
