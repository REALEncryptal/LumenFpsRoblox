local CameraController = shared.Import("CameraController")

return function (FOV)
    FOV = tonumber(FOV)
    CameraController:SetFOV(FOV)
end