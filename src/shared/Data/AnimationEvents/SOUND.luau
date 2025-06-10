return function (ID)
    local Sound = Instance.new("Sound")
    Sound.SoundId = "rbxassetid://" .. ID
    Sound.Name = "Sound_" .. ID
    Sound.Parent = workspace

    Sound:Play()

    Sound.Ended:Wait()

    Sound:Destroy()
end