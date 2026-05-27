--[[
    VisualCharacterController (client)

    Cosmetic-only counterpart to the server's VisualCharacterController. Drives
    LocalTransparencyModifier on the LocalPlayer's VisualRig based on camera
    distance to the Collider: hidden in first-person, visible in third-person.

    Roblox auto-manages this property only for parts of the character's main
    rig — the VisualRig is a nested Model, so the engine doesn't touch it and
    we do the bookkeeping ourselves.

    Other players' rigs are left fully visible.
]]

local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

-- Camera distance below which we treat the player as first-person. The eye
-- sits roughly at Collider.Position + (0, ~1.75, 0) in first-person (see
-- MovementController's RenderStep offset), so anything inside ~3 studs of the
-- Collider center is first-person. Default third-person is 12.5 studs.
local FIRST_PERSON_DISTANCE = 4

local Controller = {
    Signals = {},
}

Controller.Priority = 500 -- NORMAL

local Trove

local CurrentTrove
local CurrentRig: Model? = nil
local CurrentCollider: BasePart? = nil
local CurrentlyHidden = false

local function ApplyToPart(Part: Instance, Hidden: boolean)
    if Part:IsA("BasePart") then
        Part.LocalTransparencyModifier = Hidden and 1 or 0
    end
end

local function ApplyAll(Hidden: boolean)
    if not CurrentRig then return end
    for _, D in CurrentRig:GetDescendants() do
        ApplyToPart(D, Hidden)
    end
end

function Controller:Init()
    Trove = shared.Import("Trove")

    if LocalPlayer.Character then
        Controller.Signals.CharacterAdded(LocalPlayer.Character)
    end
end

function Controller.Signals.CharacterAdded(Character: Model)
    if Character ~= LocalPlayer.Character then return end

    if CurrentTrove then
        CurrentTrove:Destroy()
    end
    CurrentTrove = Trove.new()
    CurrentRig = nil
    CurrentCollider = Character:FindFirstChild("Collider") :: BasePart?
    CurrentlyHidden = false

    task.spawn(function()
        local Rig = Character:WaitForChild("VisualRig", 10)
        if not Rig or not Rig:IsA("Model") then return end
        if Character ~= LocalPlayer.Character then return end

        CurrentRig = Rig :: Model
        ApplyAll(CurrentlyHidden)

        CurrentTrove:Connect(Rig.DescendantAdded, function(Part)
            ApplyToPart(Part, CurrentlyHidden)
        end)
    end)
end

function Controller.Signals.CharacterRemoving()
    if CurrentTrove then
        CurrentTrove:Destroy()
        CurrentTrove = nil
    end
    CurrentRig = nil
    CurrentCollider = nil
end

function Controller.Signals.Update()
    if not CurrentRig or not CurrentCollider or not CurrentCollider.Parent then return end

    local Distance = (Camera.CFrame.Position - CurrentCollider.Position).Magnitude
    local ShouldHide = Distance < FIRST_PERSON_DISTANCE
    if ShouldHide ~= CurrentlyHidden then
        CurrentlyHidden = ShouldHide
        ApplyAll(ShouldHide)
    end
end

return Controller
