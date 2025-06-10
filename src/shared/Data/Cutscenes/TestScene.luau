local ReplicatedStorage = game:GetService("ReplicatedStorage")

return function(CutsceneClass)
    local Cutscene = setmetatable({}, CutsceneClass)
    Cutscene.__index = Cutscene

    local LoadoutController = shared.Import("LoadoutController")
    local InterfaceController = shared.Import("InterfaceController")
    local AnimationEventUtil = shared.Import("AnimationEventUtil")
    local CameraController = shared.Import("CameraController")
    local SettingsController = shared.Import("SettingsController")

    function Cutscene.new()
        local self = setmetatable(CutsceneClass.new("TestScene"), Cutscene)
        
        -- Load
        self:LoadSounds({
            Ambience = 6189453706,
            RoadAmbience = 9112784949,
            Scary1 = 157636218,
            Happy = 1843468325,
        })

        self:LoadInstances({
            MyRig = ReplicatedStorage.Assets.MyRig,
            Booga = ReplicatedStorage.Assets.Booga
        })

        self:LoadAnimations({
            ["Camera"] = {
                Track = 80630252024209
            },
            ["MyRig"] = {
                Dance = 72289498916934
            }
        })

        -- 
        self.OnStart:Connect(function()
            for _, Instance in pairs(self.Instances) do
                Instance.Parent = self.Container
            end

            self.CleanupAnimationEventUtil = AnimationEventUtil:ServeTrack(self:GetAnimation("Camera.Track"))
        end)

        -- CLeanup
        self.Trove:Add(function()
            LoadoutController.Manager:HideTools(false)
            InterfaceController.EffectUI:HideCinematicBlinds()
            CameraController:TweenFOV(SettingsController:GetSetting("FOV"), .4)

            self.CleanupAnimationEventUtil()
        end)

        -- Create events
        self:Create(
            "Sound",
            {self:GetSound("Ambience"), self:GetSound("RoadAmbience")},
            {self:TimeTrigger(0)}
        )

        
        self:Create(
            "Function",
            {function()
                self:GetInstance("MyRig").Parent = workspace
                
                LoadoutController.Manager:HideTools(true)
                
                InterfaceController.EffectUI:ShowCinematicBlinds()
            end},
            {self:TimeTrigger(0)}
        )

        self:Create(
            "Animation",
            { self:GetAnimation("Camera.Track") },
            {self:TimeTrigger(0)},
            {FadeTime = 1}
        )

        self:Create(
            "Sound",
            {self:GetSound("Scary1")},
            {self:TimeTrigger(7)}
        )

        self:Create(
            "Function",
            {function()
                self:GetInstance("Booga").PrimaryPart.Sound:Play()
            end},
            {self:TimeTrigger(10)}
        )
        

        self:Create(
            "Animation",
            { self:GetAnimation("MyRig.Dance") },
            {self:TimeTrigger(13)}
        )

        self:Create(
            "Sound",
            {self:GetSound("Happy")},
            {self:TimeTrigger(16)}
        )

        self:Create(
            "End",
            nil,
            {self:TimeTrigger(21.46)}
        )

        return self
    end

    return Cutscene
end