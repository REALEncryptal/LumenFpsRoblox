local TweenUtil = {}

local TweenService = game:GetService("TweenService")

-- Helper function to create a property tween
local function CreatePropertyTween(Instance, Property, Goal, TweenInfo)
    local Properties = {}
    Properties[Property] = Goal
    local Tween = TweenService:Create(Instance, TweenInfo, Properties)
    return Tween
end

-- Helper function to handle transparencies for different UI types
local function HandleTransparency(Instance, Property, Goal, TweenInfo, Tweens)
    -- Skip properties that are already fully transparent
    if Property ~= "BackgroundTransparency" or Instance[Property] < 1 then
        local TargetGoal = Goal
        if TargetGoal == nil then
            TargetGoal = Instance[Property]
        end
        table.insert(Tweens, CreatePropertyTween(Instance, Property, TargetGoal, TweenInfo))
    end
end

-- Function to process each instance and create appropriate tweens
local function ProcessInstance(Instance, Goal, TweenInfo, Tweens)
    -- Text-based UI elements
    if Instance:IsA("TextLabel") or Instance:IsA("TextButton") or Instance:IsA("TextBox") then
        HandleTransparency(Instance, "TextTransparency", Goal, TweenInfo, Tweens)
        HandleTransparency(Instance, "TextStrokeTransparency", Goal, TweenInfo, Tweens)
        HandleTransparency(Instance, "BackgroundTransparency", Goal, TweenInfo, Tweens)
    
    -- Image-based UI elements    
    elseif Instance:IsA("ImageLabel") or Instance:IsA("ImageButton") then
        HandleTransparency(Instance, "ImageTransparency", Goal, TweenInfo, Tweens)
        HandleTransparency(Instance, "BackgroundTransparency", Goal, TweenInfo, Tweens)
    
    -- Container UI elements
    elseif Instance:IsA("Frame") or Instance:IsA("ScrollingFrame") or Instance:IsA("CanvasGroup") then
        HandleTransparency(Instance, "BackgroundTransparency", Goal, TweenInfo, Tweens)
    
    -- UI decorations
    elseif Instance:IsA("UIStroke") then
        HandleTransparency(Instance, "Transparency", Goal, TweenInfo, Tweens)
    end
    
    -- Process descendants
    for _, Child in Instance:GetChildren() do
        ProcessInstance(Child, Goal, TweenInfo, Tweens)
    end
end

-- Main function to tween transparency of an object and all its descendants
function TweenUtil.CreateTransparencyTween(Object: Instance | {Instance}, Goal, Time: number, EaseStyle: Enum.EasingStyle?, EaseDirection: Enum.EasingDirection?)
    local TweenInfo = TweenInfo.new(Time, EaseStyle or Enum.EasingStyle.Quad, EaseDirection or Enum.EasingDirection.Out)
    local Tweens = {}
    local Objects = typeof(Object) == "table" and Object or {Object}
    
    -- Process objects and their descendants
    for _, Obj in Objects do
        ProcessInstance(Obj, Goal, TweenInfo, Tweens)
    end

    -- Create and return the tween group controller
    local TweenGroup = {}

    function TweenGroup:Play()
        for _, Tween in Tweens do
            Tween:Play()
        end
    end

    function TweenGroup:Cancel()
        for _, Tween in Tweens do
            Tween:Cancel()
        end
    end

    return TweenGroup
end

return TweenUtil