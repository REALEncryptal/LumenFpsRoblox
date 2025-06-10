local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Cutscene = {}
Cutscene.__index = Cutscene

local Trove = shared.Import("trove")
local Signal = shared.Import("signal")

function Cutscene.new(Name)
    local self = setmetatable({}, Cutscene)
    self.Type = "Cutscene"
    self.Name = Name

    self.Trove = Trove.new()
    self._Debug = true

    self.Container = Instance.new("Folder")
    self.Container.Name = "Cutscene_" .. Name
    self.Container.Parent = workspace
    self.Trove:Add(self.Container)

    self.OnStart = Signal.new()
    self.OnEnd = Signal.new()

    self.Instances = {}
    self.Animations = {}
    self.Sounds = {}
    self.Functions = {}
    self.Signals = {}

    self.Events = {}
    self.UpdateTasks = {}

    self.StartTime = tick()
    self.Playing = false

    self.Destroyed = false

    ---

    self.Trove:Add(function()
        self.UpdateTasks = {}
        self.SortedUpdateTasks = {}
    end)

    self:LoadInstances({
        Camera = ReplicatedStorage.Assets.Camera
    })

    -- Camera

    self:AddUpdateTask("Camera", 0, function(DeltaTime)
        -- Rotate the camera to look out from the bottom face
        local torsoCFrame = self:GetInstance("Camera").Torso.CFrame
        local bottomFaceCFrame = torsoCFrame * CFrame.Angles(math.rad(90), 0, math.rad(90)) -- Rotate 90 degrees around X-axis for bottom face then 90 deg to make it landscape
        workspace.CurrentCamera.CFrame = bottomFaceCFrame
    end)

    return self
end

-- Main methods
function Cutscene:Play()
    self.Playing = true
    self.StartTime = tick()
    self.OnStart:Fire()
end

function Cutscene:Destroy()
    self.Playing = false
    self.Destroyed = true
    self.Trove:Destroy()
end

function Cutscene:CheckDestroyed()
    if self.Destroyed then
        warn("[Cutscene] Attempted to use destroyed cutscene: " .. self.Name)
    end

    return self.Destroyed
end

-- Internal
function Cutscene:Create(EventType: string, Events: { any }, Triggers: { any }, ...: any) -- trigger is a signal
    if self:CheckDestroyed() then return end
    
    local EventData = {
        Type = EventType,
        Events = Events,
        Triggers = Triggers,
        ...
    }

    table.insert(self.Events, EventData)

    for _, Trigger in ipairs(Triggers) do
        local Connection
        Connection = Trigger:Connect(function()
            Connection:Disconnect()

            if EventType == "End" then
                self:ExecuteEvent(nil, EventType, EventData)
                return
            end
            
            for _, Event in ipairs(Events) do
                self:ExecuteEvent(Event, EventType, EventData)
            end
        end)
    end
end

function Cutscene:ExecuteEvent(Event, Type, EventData)
    if self:CheckDestroyed() then return end

    if Type == "Function" then
        local success, err = pcall(function()
            Event()
        end)
        if not success and self._Debug then
            warn("[Cutscene] Error executing function event: ", err)
        end
    elseif Type == "Animation" then
        if EventData.Stop then
            Event:Stop()
        else
            Event:Play(if EventData.FadeTime then EventData.FadeTime else 0)
        end
    elseif Type == "Sound" then
        local Sound = Instance.new("Sound")
        Sound.SoundId = "rbxassetid://" .. Event
        Sound.Name = "Sound_" .. Event
        Sound.Parent = self.Container

        self.Trove:Add(Sound)
        Sound:Play()
    elseif Type == "End" then
        self.Playing = false
        self.OnEnd:Fire()
        self:Destroy()
    end
end

-- Internal Signals
function Cutscene:TimeTrigger(Time: number)
    if self:CheckDestroyed() then return end

    local TimeSignal = self.Signals["TimeTrigger_" .. Time]

    if not TimeSignal then
        TimeSignal = Signal.new()
        self.Signals["TimeTrigger_" .. Time] = TimeSignal

        self:AddUpdateTask("TimeTrigger_" .. Time, 100, function(DeltaTime)
            if self:Time() >= Time then
                TimeSignal:Fire()
                TimeSignal:Destroy()
                self:RemoveUpdateTask("TimeTrigger_" .. Time)
            end
        end)
    end

    return TimeSignal
end

-- Internal Utils
function Cutscene:Time()
    return tick() - self.StartTime
end

-- Internal Getters
function Cutscene:GetInstance(Name: string): Instance?
    return self.Instances[Name]
end

function Cutscene:GetAnimation(Name: string): AnimationTrack?
    return self.Animations[Name]
end

function Cutscene:GetSound(Name: string): Sound?
    return self.Sounds[Name]
end

function Cutscene:GetFunction(Name: string): (() -> any)?
    return self.Functions[Name]
end

-- Internal Loaders

function Cutscene:LoadInstances(Instances: { [string]: Instance })
    for Name, Instance in pairs(Instances) do
        self.Instances[Name] = self.Trove:Clone(Instance)
    end
end

function Cutscene:LoadAnimations(AnimationOwners: { [string]: { AnimationName: string, AnimationID: string } })
    for AnimationOwnerName, Animations in pairs(AnimationOwners) do
        local AnimationOwner = self:GetInstance(AnimationOwnerName)
        assert(AnimationOwner, "AnimationOwner not found: " .. AnimationOwnerName)

        local Animator:Animator = AnimationOwner:FindFirstChild("Animator", true)
        assert(Animator, "AnimationOwner must have an Animator: " .. AnimationOwner:GetFullName())

        local Parent = AnimationOwner.Parent
        AnimationOwner.Parent = workspace

        for AnimationName, AnimationID in pairs(Animations) do
            local Animation = Instance.new("Animation")
            Animation.Parent = AnimationOwner
            Animation.AnimationId = "rbxassetid://" .. AnimationID
            self.Trove:Add(Animation)

            self.Animations[AnimationOwnerName.."."..AnimationName] = Animator:LoadAnimation(Animation)
        end     

        AnimationOwner.Parent = Parent
    end
end

function Cutscene:LoadSounds(Sounds: { [string]: Sound })
    for Name, Sound in pairs(Sounds) do
        self.Sounds[Name] = Sound
    end
end

function Cutscene:LoadFunctions(Functions: { [string]: () -> any })
    for Name, Function in pairs(Functions) do
        self.Functions[Name] = Function
    end
end

function Cutscene:CreateSignals(Signals: { [string]: any })
    for _, SignalName in ipairs(Signals) do
        self.Signals[SignalName] = Signal.new()
    end
end

-- Update tasks
function Cutscene:AddUpdateTask(Name: string, Priority: number?, Task: (Delta: number) -> any)
    self.UpdateTasks[Name] = {
        Priority = Priority or 100,
        Task = Task,
    }
    
    self:SortUpdateTasks()
end

function Cutscene:RemoveUpdateTask(Name: string)
    self.UpdateTasks[Name] = nil
    
    for Index, TaskData in ipairs(self.SortedUpdateTasks) do
        if TaskData.Name == Name then
            table.remove(self.SortedUpdateTasks, Index)
            break
        end
    end
end

function Cutscene:SortUpdateTasks()
    self.SortedUpdateTasks = {}
    
    for TaskName, TaskData in pairs(self.UpdateTasks) do
        table.insert(self.SortedUpdateTasks, {
            Name = TaskName,
            Data = TaskData,
        })
    end
    
    table.sort(self.SortedUpdateTasks, function(a, b)
        return a.Data.Priority < b.Data.Priority
    end)
end

function Cutscene:Update(DeltaTime: number)
    if self:CheckDestroyed() then return end

    for _, TaskData in ipairs(self.SortedUpdateTasks) do
        TaskData.Data.Task(DeltaTime)
    end
end

return Cutscene
