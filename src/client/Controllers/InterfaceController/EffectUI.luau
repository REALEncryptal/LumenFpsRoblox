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

    return EffectUI
end

function EffectUI:DeltaLerp(DeltaTime: number, Number: number, Goal: number, Speed: number): number
    return lerpDamped(Number, Goal, Speed, DeltaTime)
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