local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Controller = {
    Signals = {}
}

Controller.Priority = 20

-- Source-style view punch. Single accumulator; firing slams it instantly
-- (no smoothing on the climb), each frame it decays exponentially back to
-- zero. No lerp, no chase between two states — the only physics is the
-- decay. Camera CFrame is rotated by Punch AFTER the default camera writes
-- the frame's mouse-look CFrame, so the punch stacks on top of mouse input
-- and the player's aim is preserved through the kick.
Controller.Punch = Vector2.new()
Controller.PunchDecay = 14  -- per-second exponential decay (~70ms time constant; high = each kick recovers fast enough to read as a discrete thump instead of drift)

local RECOIL_BIND = "Lumen_RecoilApply"

local SettingsController
function Controller:Init()
    SettingsController = shared.Import("SettingsController")
    Controller.Instance = workspace.CurrentCamera

    Controller:SetFOV(SettingsController:GetSetting("FOV"))

    -- Priority Camera + 2 runs after Roblox's default camera (200) AND
    -- MovementController's eye-height bind (201) so the rotation composes
    -- cleanly on top of both.
    RunService:BindToRenderStep(RECOIL_BIND, Enum.RenderPriority.Camera.Value + 2, function(DeltaTime)
        Controller:_UpdateRecoil(DeltaTime)
    end)
end

-- Instant view punch. Pitch is degrees of camera-up rotation; Yaw is degrees
-- of camera-yaw rotation (callers should randomize sign so bursts spray
-- instead of drifting one direction). Adds directly to Punch — the camera
-- jumps this much on the very next frame, no ramp.
function Controller:ApplyRecoil(Pitch: number, Yaw: number)
    Controller.Punch = Controller.Punch + Vector2.new(Pitch, Yaw)
end

function Controller:_UpdateRecoil(DeltaTime: number)
    Controller.Punch = Controller.Punch * math.exp(-Controller.PunchDecay * DeltaTime)

    if Controller.Punch.Magnitude > 1e-4 then
        Controller.Instance.CFrame = Controller.Instance.CFrame
            * CFrame.Angles(math.rad(Controller.Punch.X), math.rad(Controller.Punch.Y), 0)
    end
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
