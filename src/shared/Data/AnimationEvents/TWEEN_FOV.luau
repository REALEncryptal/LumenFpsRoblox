local CameraController = shared.Import("CameraController")

return function (FOV)
    FOV = tonumber(FOV)
    CameraController:TweenFOV(FOV, .4, Enum.EasingStyle.Linear)
end