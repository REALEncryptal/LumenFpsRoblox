local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Controller = {
    Signals = {}
}

Controller.Priority = 150

local CutsceneClass, Iris
function Controller:Init()
    CutsceneClass = shared.Import("Cutscene")
    Iris = shared.Import("iris")

    Controller.Cutscenes = {}
    Controller.Map = {}

    Controller.CurrentCutscene = nil

    -- create cutscene classes
    for _, CutsceneModule:ModuleScript in ipairs(ReplicatedStorage.Shared.Data.Cutscenes:GetChildren()) do
        Controller.Map[CutsceneModule.Name] = require(CutsceneModule)(CutsceneClass)
    end

    -- debug
    Controller:DebugUI()
end

function Controller:DebugUI()
    Iris:Connect(function()
        local windowSize = Iris.State(Vector2.new(240, 240))
        local windowPos = Iris.State(Vector2.new(600, 0))

        Iris.Window({"Cutscene Controller"}, {size = windowSize, position = windowPos})

        if Controller.CurrentCutscene then
            Iris.Text({"Current Cutscene: " .. Controller.CurrentCutscene.Name})
        else
            Iris.Text({"Current Cutscene: None"})
        end

        Iris.SeparatorText({"Cutscenes"})
        Iris.Indent()

        for CutsceneName, _ in pairs(Controller.Map) do
            Iris.SameLine()

            Iris.Text({CutsceneName})

            if not Controller.Cutscenes[CutsceneName] then
                if Iris.Button("Load").clicked() then
                    Controller:LoadCutscene(CutsceneName)
                end
            end

            if Controller.Cutscenes[CutsceneName] and not Controller.Cutscenes[CutsceneName].Destroyed then
                if Iris.Button("Destroy").clicked() then
                    Controller:DestroyCutscene(CutsceneName)
                end

                if Controller.Cutscenes[CutsceneName] then
                    if not Controller.Cutscenes[CutsceneName].Playing then
                        if Iris.Button("Play").clicked() then
                            Controller:StartCutscene(CutsceneName)
                        end
                    else
                        Iris.Text({"Playing"})
                    end
                end
            else
                Controller.Cutscenes[CutsceneName] = nil
            end

            Iris.End()
        end

        Iris.End()

        Iris.End()
    end)
end

function Controller.Signals.Update(DeltaTime: number)
    for _, Cutscene in pairs(Controller.Cutscenes) do
        if not Cutscene then continue end
        if not Cutscene.Playing then continue end
        
        Cutscene:Update(DeltaTime)
    end
end

----- 

function Controller:GetCutscene(CutsceneName: string): any
    return Controller.Cutscenes[CutsceneName]
end

function Controller:HasCutscene(CutsceneName: string): boolean
    return Controller.Map[CutsceneName] ~= nil
end

function Controller:LoadCutscene(CutsceneName: string): any
    assert(not Controller.Cutscenes[CutsceneName], "Cutscene already loaded: " .. CutsceneName)
    
    local Cutscene = Controller.Map[CutsceneName].new()
    Controller.Cutscenes[CutsceneName] = Cutscene

    return Cutscene
end

function Controller:StartCutscene(CutsceneName: string)
    assert(Controller.Cutscenes[CutsceneName], "Cutscene not loaded: " .. CutsceneName)
    
    Controller.Cutscenes[CutsceneName]:Play()
end

function Controller:DestroyCutscene(CutsceneName: string)
    assert(Controller.Cutscenes[CutsceneName], "Cutscene not loaded: " .. CutsceneName)
    
    Controller.Cutscenes[CutsceneName]:Destroy()
    Controller.Cutscenes[CutsceneName] = nil
end

return Controller   