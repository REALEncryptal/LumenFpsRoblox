--[[
    Crosshair Component

    Owns the in-world crosshair Part that floats in front of the camera while a
    tool is equipped. Lifted out of ToolBase.

    Tool data shape:
        Components = {
            {Name = "Crosshair", Config = {}},
        }

    Other components and ToolBase reach the crosshair via
        tool:GetComponent("Crosshair"):Show()  / :Hide() / :SetEnabled(bool)
    so the rest of the codebase doesn't touch the cloned Instance directly.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TweenUtil = shared.Import("TweenUtil")
local Trove = shared.Import("Trove")

local FADE_TIME = 0.2
local DISTANCE_FROM_CAMERA = 5

local Crosshair = {}
Crosshair.__index = Crosshair

function Crosshair.new(tool, _config)
    local self = setmetatable({}, Crosshair)
    self.Tool = tool
    self.Trove = Trove.new()

    self.Instance = self.Trove:Clone(ReplicatedStorage.Assets.Crosshair)
    self.Instance.Parent = workspace.CurrentCamera

    -- The Crosshair asset is a Part with a child SurfaceGui named "Crosshair"
    -- (or similar). The tween targets transparency on that child.
    self.SurfaceTarget = self.Instance:FindFirstChild("Crosshair") or self.Instance
    self.ShowTween = TweenUtil.CreateTransparencyTween(self.SurfaceTarget, nil, FADE_TIME)
    self.HideTween = TweenUtil.CreateTransparencyTween(self.SurfaceTarget, 1, FADE_TIME)

    return self
end

-- The actual per-frame positioning lives in ToolBase's main Update task
-- (priority 106) because it has to interleave with the camera CFrame surgery
-- (revert previous offset → position crosshair using the raw camera →
-- apply current offset). ToolBase reads `crosshair.Instance` directly to
-- avoid a third camera-CFrame split.
function Crosshair:GetPositionDistance(): number
    return DISTANCE_FROM_CAMERA
end

function Crosshair:Show()
    self.ShowTween:Play()
end

function Crosshair:Hide()
    self.HideTween:Play()
end

-- Hard on/off (cutscene tool-hide path). Bypasses the fade tween.
function Crosshair:SetEnabled(enabled: boolean)
    if self.SurfaceTarget:IsA("GuiObject") or self.SurfaceTarget:IsA("LayerCollector") then
        self.SurfaceTarget.Enabled = enabled
    end
end

function Crosshair:Destroy()
    self.Trove:Destroy()
end

return Crosshair
