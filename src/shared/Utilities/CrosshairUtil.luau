local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[[

    Thank you klutzer/mod for the crosshair util

    Creates a crosshair that can be updated to scale with the camera

]] 
return function()
    local CurrentCamera = workspace.Camera
    local SurfaceGuiPart = ReplicatedStorage.Assets.Crosshair:Clone()
    SurfaceGuiPart.Parent = CurrentCamera
    
    local function GetSurfaceGui() return SurfaceGuiPart end

    local function UpdateSurfaceGui()
        SurfaceGuiPart.CFrame = CurrentCamera.CFrame * CFrame.new(CurrentCamera.CFrame.LookVector * 10)
    end

    return GetSurfaceGui, UpdateSurfaceGui
end
