local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Controller = {
    Signals = {}
}

Controller.Priority = 20

-- Punchy kick with smoothed recovery toward a residual drift floor.
--
-- Two-vector model:
--   Current — degrees actually applied to the camera this frame
--   Target  — degrees Current is easing toward (the residual / drift floor)
--
-- ApplyRecoil shoves Current by the full per-shot magnitude (instant snap-up)
-- and bumps Target by RESIDUAL_RATIO of that (the part that sticks). Every
-- render step Current eases toward Target via frame-rate-independent
-- exponential decay, so the camera snaps up and smoothly bleeds back to the
-- drift floor. Sustained fire compounds the drift — player still has to aim
-- back manually, but each shot's transient kick recovers on its own.
--
-- Roblox's default Custom camera re-derives Camera.CFrame from mouse pitch/yaw
-- each frame, so we re-apply Current every render step at Camera+2 (after
-- the default camera AND MovementController's eye-height bind at Camera+1)
-- to keep the offset stacked on top of mouse-look.
Controller.Current = Vector2.new()
Controller.Target = Vector2.new()

local RESIDUAL_RATIO = 0.20
local SMOOTHNESS = 12

local RECOIL_BIND = "Lumen_RecoilApply"

local SettingsController
function Controller:Init()
    SettingsController = shared.Import("SettingsController")
    Controller.Instance = workspace.CurrentCamera

    Controller:SetFOV(SettingsController:GetSetting("FOV"))

    RunService:BindToRenderStep(RECOIL_BIND, Enum.RenderPriority.Camera.Value + 2, function(DeltaTime)
        local Alpha = 1 - math.exp(-SMOOTHNESS * DeltaTime)
        Controller.Current = Controller.Current:Lerp(Controller.Target, Alpha)

        if Controller.Current.Magnitude > 1e-4 then
            Controller.Instance.CFrame = Controller.Instance.CFrame
                * CFrame.Angles(math.rad(Controller.Current.X), math.rad(Controller.Current.Y), 0)
        end
    end)
end

-- Per-shot kick. Pitch is degrees of upward rotation (positive = up); Yaw is
-- degrees of horizontal rotation (callers should randomize sign so bursts
-- spray instead of drifting one direction). The full magnitude lands on
-- Current instantly; RESIDUAL_RATIO of it sticks to Target as drift.
function Controller:ApplyRecoil(Pitch: number, Yaw: number)
    local Impulse = Vector2.new(Pitch, Yaw)
    Controller.Current = Controller.Current + Impulse
    Controller.Target = Controller.Target + Impulse * RESIDUAL_RATIO
end

function Controller:ResetRecoil()
    Controller.Current = Vector2.new()
    Controller.Target = Vector2.new()
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
