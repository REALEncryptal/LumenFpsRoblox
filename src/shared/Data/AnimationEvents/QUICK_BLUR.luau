local TweenService = game:GetService("TweenService")
local BlurIn = TweenService:Create(game.Lighting.QuickBlur, TweenInfo.new(.4), {Size = 10})
local BlurOut = TweenService:Create(game.Lighting.QuickBlur, TweenInfo.new(.4), {Size = 0})

return function (_)
    BlurIn:Play()
    task.wait(.4)
    BlurOut:Play()
end