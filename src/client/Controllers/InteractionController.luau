local Controller = {}
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Net, Constants, ObjectIndex, InputImageMap, ActionIndex

function Controller:Init()
    Net = shared.Import "net"
    Constants = shared.Import "Constants"
    ObjectIndex = shared.Import "ObjectIndex"
    InputImageMap = shared.Import "InputImageMap"
    ActionIndex = shared.Import "ActionIndex"

    Controller.LastHoveredModel = nil

    Controller.AvailableActions = {}
    Controller.Object = nil
    Controller.Tweens = {}

    Controller.Gui = game.Players.LocalPlayer.PlayerGui:WaitForChild("Game")
    Controller.Highlight = ReplicatedStorage.Assets:WaitForChild("HoverHighlight"):Clone()
    Controller.Highlight.Parent = ReplicatedStorage

    Controller.Gui:WaitForChild("ObjectName")

    -- create remotes
    Controller.ActionSignal = Net:RemoteEvent("ActionSignal")
    Controller.ActionStart = Net:RemoteEvent("ActionStart")
    Controller.ActionCancelled = Net:RemoteEvent("ActionCancelled")

    -- connect
    Controller.ActionSignal:Connect(Controller._ActionSignal)
end

function Controller:Update()
    local HoveredModel = Controller:GetHoveredModel()
    Controller:VisualizeHoveredModel(HoveredModel)

    if HoveredModel and not Controller.LastHoveredModel then
        Controller.LastHoveredModel = HoveredModel

        Controller:_ModelNotHovered()
        Controller:_ModelHovered(HoveredModel)
    elseif not HoveredModel and Controller.LastHoveredModel then
        Controller.LastHoveredModel = HoveredModel
        
        Controller:_ModelNotHovered()
    end


    if not Controller.Gui then return end
    Controller.Gui:WaitForChild("ObjectName").Visible = if HoveredModel then true else false
end

function Controller:InputBegan(Input, Processed)
    if Processed then return end
    if not Controller.LastHoveredModel then return end
    if #Controller.AvailableActions <= 0 then return end

    for _, Action in ipairs(Controller.AvailableActions) do
        local ActionData = ActionIndex[Action]
        if ActionData.KeyCode ~= Input.KeyCode then continue end

        Controller:ActionStart(Action)
        Controller.ActionStart:FireServer(Controller.LastHoveredModel, Action)
        return
    end
end

function Controller:InputEnded(Input, Processed)
    if Processed then return end
    if not Controller.LastHoveredModel then return end
    if #Controller.AvailableActions <= 0 then return end

    for _, Action in ipairs(Controller.AvailableActions) do
        local ActionData = ActionIndex[Action]
        if ActionData.KeyCode ~= Input.KeyCode then continue end

        Controller:ActionStop(Action)
        Controller.ActionCancelled:FireServer(Controller.LastHoveredModel, Action)
        return
    end
end

--

function Controller:ActionStart(Action)
    local Label = Controller.Gui.ActionContainer:FindFirstChild(Action).ActionName
    local ProgressBar = Label.ProgressBar
    local Background = Label.ProgressBarBackground

    local HoldDuration = ActionIndex[Action].HoldDuration
    if Controller.Object.ActionSettings and Controller.Object.ActionSettings[Action] then
        HoldDuration = Controller.Object.ActionSettings[Action].HoldDuration
    end

    local Tween = TweenService:Create(ProgressBar, TweenInfo.new(
        HoldDuration, Enum.EasingStyle.Linear
    ), {Size=UDim2.new(1, 0 , .01, 0)})

    ProgressBar.Visible = true
    Background.Visible = true
    
    ProgressBar.Size = UDim2.new(0, 0 , .01, 0)
    Tween:Play()
    print(Action)
    Controller.Tweens[Action] = Tween
end

function Controller:ActionStop(Action)
    local Label = Controller.Gui.ActionContainer:FindFirstChild(Action).ActionName
    local ProgressBar = Label.ProgressBar
    local Background = Label.ProgressBarBackground

    ProgressBar.Visible = false
    Background.Visible = false
    ProgressBar.Size = UDim2.new(0, 0 , .01, 0)

    local Tween:Tween = Controller.Tweens[Action]
    Tween:Destroy()
    Controller.Tweens[Action] = nil
end

function Controller._ActionSignal(SignalName, Object, ActionName)
    local ActionData = ActionIndex[ActionName]
    if not ActionData then return end

    local Function = ActionData.Client[SignalName]
    if not Function then return end

    local ObjectData = ObjectIndex[Object.Name]

    Function(Object, ObjectData)
end 

function Controller:_ModelHovered(Model)
    Controller:VisualizeHoveredModel(Model)

    local Object = ObjectIndex[Model.Name]
    if not Object then return end


    Controller.AvailableActions = Object.Actions
    Controller.Object = Object


    -- Populate action gui
    local ActionContainer = Controller.Gui.ActionContainer

    for i, Action in ipairs(Object.Actions) do

        local ActionData = ActionIndex[Action]
        local ActionEntry:Frame = ReplicatedStorage.Assets.Interface.ActionEntry:Clone()
        ActionEntry.Name = Action

        ActionEntry.ActionName.Text = Action
        ActionEntry.ActionInput.Image = InputImageMap[ActionData.KeyCode]
        ActionEntry.LayoutOrder = i

        ActionEntry.Parent = ActionContainer
    end
end

function Controller:_ModelNotHovered(Model)
    Controller.VisualizeHoveredModel(nil)

    Controller.AvailableActions = {}
    Controller.Object = nil

    for _, ActionEntry in ipairs(Controller.Gui.ActionContainer:GetChildren()) do
        if not ActionEntry:IsA("Frame") then continue end
        ActionEntry:Destroy()
    end
end

function Controller:GetHoveredModel(): Model?
    local MaxObjectHoverDistance = Constants.MAX_OBJECT_HOVER_DISTANCE

    local Mouse = UserInputService:GetMouseLocation()
    local Camera = workspace.CurrentCamera
    local Ray = Camera:ViewportPointToRay(Mouse.X, Mouse.Y)

    local Params = RaycastParams.new()
    Params.FilterType = Enum.RaycastFilterType.Blacklist
    Params.FilterDescendantsInstances = {Camera, game.Players.LocalPlayer.Character}
    Params.IgnoreWater = true

    local Hit, Position = workspace:Raycast(Ray.Origin, Ray.Direction * MaxObjectHoverDistance, Params)
    if not Hit then return end

    -- Find if hit part is a descendant of a model
    local Model = Hit.Instance:FindFirstAncestorWhichIsA("Model")
    if not Model then return end
    if not ObjectIndex[Model.Name] then return end

    return Model, Position
end

function Controller:VisualizeHoveredModel(Model)
    Controller.Highlight.Parent = if Model then Model else ReplicatedStorage

    if not Model then return end
    if not ObjectIndex[Model.Name] then return end
    Controller.Gui.ObjectName.Text = ObjectIndex[Model.Name].Name
end

--

return Controller