local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Controller = {
    Signals = {}
}

Controller.Priority = 20

-- Punchy kick with smoothed full recovery to aim.
--
-- Offset — degrees of pitch/yaw applied on top of mouse-look this frame.
-- ApplyRecoil shoves Offset by the full per-shot impulse (instant snap-up).
-- Every render step Offset eases toward zero via frame-rate-independent
-- exponential decay, so the camera kicks and smoothly returns all the way
-- back to where the player was aiming. Bursts stack on Offset (kicks compound
-- while firing) but always recover to zero once firing stops.
--
-- Roblox's default Custom camera re-derives Camera.CFrame from mouse pitch/yaw
-- each frame, so we re-apply Offset every render step at Camera+2 (after the
-- default camera AND MovementController's eye-height bind at Camera+1) to
-- stack the kick on top of mouse-look.
Controller.Offset = Vector2.new()

local SMOOTHNESS = 12

local RECOIL_BIND = "Lumen_RecoilApply"

local SettingsController
function Controller:Init()
    SettingsController = shared.Import("SettingsController")
    Controller.Instance = workspace.CurrentCamera

    Controller:SetFOV(SettingsController:GetSetting("FOV"))

    RunService:BindToRenderStep(RECOIL_BIND, Enum.RenderPriority.Camera.Value + 2, function(DeltaTime)
        local Alpha = 1 - math.exp(-SMOOTHNESS * DeltaTime)
        Controller.Offset = Controller.Offset:Lerp(Vector2.new(), Alpha)

        if Controller.Offset.Magnitude > 1e-4 then
            Controller.Instance.CFrame = Controller.Instance.CFrame
                * CFrame.Angles(math.rad(Controller.Offset.X), math.rad(Controller.Offset.Y), 0)
        end
    end)
end

-- Per-shot kick. Pitch is degrees of upward rotation (positive = up); Yaw is
-- degrees of horizontal rotation (callers should randomize sign so bursts
-- spray instead of drifting one direction). Stacks on the current Offset and
-- decays smoothly back to zero — no permanent residual.
function Controller:ApplyRecoil(Pitch: number, Yaw: number)
    Controller.Offset = Controller.Offset + Vector2.new(Pitch, Yaw)
end

function Controller:ResetRecoil()
    Controller.Offset = Vector2.new()
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