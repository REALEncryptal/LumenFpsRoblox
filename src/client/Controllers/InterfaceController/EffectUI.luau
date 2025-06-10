local TweenService = game:GetService("TweenService")
--[[

    EffectUI
        A controller for Vignettess, damage screens, etc
    
    Created Saturday, May 15th 2025, 12:14 pm
    RealEncryptal
    
--]]

local EffectUI = {
    _Raw = true -- this is not a controller, DO NOT INIT
}

local Controller


function EffectUI:Init(InterfaceController)
    Controller = InterfaceController

    EffectUI.VignetteInstance = Controller.Instance.Vignette
    EffectUI.Vignette = .8
    EffectUI._CurrentVignette = .8

    EffectUI.CinematicBlinds = Controller.Instance.CinematicBlinds
    EffectUI.CinematicBlindsTopIn = TweenService:Create(EffectUI.CinematicBlinds.Top, TweenInfo.new(.5), {Size = UDim2.new(1, 0, 0.1, 0)})
    EffectUI.CinematicBlindsBottomIn = TweenService:Create(EffectUI.CinematicBlinds.Bottom, TweenInfo.new(.5), {Size = UDim2.new(1, 0, 0.1, 0)})
    EffectUI.CinematicBlindsTopOut = TweenService:Create(EffectUI.CinematicBlinds.Top, TweenInfo.new(.2), {Size = UDim2.new(1, 0, 0, 0)})
    EffectUI.CinematicBlindsBottomOut = TweenService:Create(EffectUI.CinematicBlinds.Bottom, TweenInfo.new(.2), {Size = UDim2.new(1, 0, 0, 0)})

    return EffectUI
end

function EffectUI:DeltaLerp(DeltaTime: number, Number: number, Goal: number, Speed: number): number
    return lerpDamped(Number, Goal, Speed, DeltaTime)
end

function EffectUI:ShowCinematicBlinds()
    EffectUI.CinematicBlindsTopIn:Play()
    EffectUI.CinematicBlindsBottomIn:Play()
end

function EffectUI:HideCinematicBlinds()
    EffectUI.CinematicBlindsTopOut:Play()
    EffectUI.CinematicBlindsBottomOut:Play()
end

function EffectUI:Update(DeltaTime: number) 
    EffectUI._CurrentVignette = EffectUI:DeltaLerp(
        DeltaTime, EffectUI._CurrentVignette, EffectUI.Vignette, 5
    )
    EffectUI.VignetteInstance.ImageTransparency = EffectUI._CurrentVignette
end

function lerpDamped(a, b, smoothness, deltaTime)
    -- smoothness: how quickly it approaches (higher = slower)
    -- deltaTime: time since last frame
    local alpha = 1 - math.exp(-smoothness * deltaTime)
    return a + (b - a) * alpha
end


return EffectUI