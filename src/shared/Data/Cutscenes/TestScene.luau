local ReplicatedStorage = game:GetService("ReplicatedStorage")

return function(CutsceneClass)
    local Cutscene = setmetatable({}, CutsceneClass)
    Cutscene.__index = Cutscene

    function Cutscene.new()
        local self = setmetatable(CutsceneClass.new("TestScene"), Cutscene)
        
        -- Load
        self:LoadSounds({
            Cat = 7148585764,
            Explode = 2814355743,
        })

        self:LoadInstances({
            Map = ReplicatedStorage.Assets.Cutscenes.TestScene.Map,
            Cat = ReplicatedStorage.Assets.Cutscenes.TestScene.Maxwell,
            SmokeEmitter = ReplicatedStorage.Assets.Cutscenes.TestScene.SmokeEmitter,
        })

        self:LoadAnimations({
            ["Camera"] = {
                Track = 0,
            },
            ["Cat"] = {
                Walk = 0,
                Spin = 0
            }
        })

        -- Create cutscene events
        self.OnStart:Connect(function()
            for _, Instance in pairs(self.Instances) do
                Instance.Parent = self.Container
            end
        end)

        self:Create(
            "Function",
            {function()
                self:GetInstance("Map").Parent = workspace
                self:GetInstance("Cat").Parent = self:GetInstance("Map")
                print("Parented map and cat")
            end},
            {self:TimeTrigger(0)}
        )

        self:Create(
            "Animation",
            { self:GetAnimation("Cat.Walk") },
            {self:TimeTrigger(1)}
        )

        self:Create(
            "Animation",
            { self:GetAnimation("Cat.Spin") },
            {self:TimeTrigger(3)}
        )

        self:Create(
            "Sound",
            {self:GetSound("Cat")},
            {self:TimeTrigger(3)}
        )

        self:Create(
            "Function",
            {function()
                local SmokeEmitter = self:GetInstance("SmokeEmitter")
                SmokeEmitter.Enabled = true
                SmokeEmitter.Parent = self:GetInstance("Cat")
                print("Parented smoke emitter and enabled")
            end},
            {self:TimeTrigger(5)}
        )

        self:Create(
            "Sound",
            {self:GetSound("Explode")},
            {self:TimeTrigger(6)}
        )

        self:Create(
            "End",
            nil,
            {self:TimeTrigger(7)}
        )

        return self
    end

    return Cutscene
end