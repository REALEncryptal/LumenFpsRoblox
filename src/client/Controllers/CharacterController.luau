--[[
    
    Controller
        Utility for character related functions
    
    Created Sunday, May 4th 2025, 6:59:15 pm
    RealEncryptal
    
--]]

local Controller = {
    _GroundedInternal = false,
    _WasGroundedInternal = false,
    _VelocityInternal = Vector3.new(),
    Signals = {}
}

Controller.Priority = 10

local Signal, MovementController
function Controller:Init()
    Signal = shared.Import("Signal")
    MovementController = shared.Import("MovementController")

    Controller.OnImpact = Signal.new()
end

function Controller.Signals.Update(DeltaTime: number)
    if not Controller.GetCharacter() then return end
    
    Controller._WasGroundedInternal = Controller._GroundedInternal
    Controller._GroundedInternal = Controller.IsGrounded()
    Controller._VelocityInternal = Controller.GetVelocity()

    if Controller._GroundedInternal and not Controller._WasGroundedInternal and Controller._VelocityInternal.Y < -2 then
        Controller.OnImpact:Fire()
    end
end

-- middleware
function Controller.RequireCharacter(func: (Character: Model, ...any) -> any, ...: string)
    return function(...)
        local Character = Controller.GetCharacter()
        if not Character then return end
        
        for _, PartName in {...} do
            if not Character:FindFirstChild(PartName) then return end
        end
        
        return func(Character, ...)
    end
end

-- methods
Controller.GetCharacter = function(): Model
    return game.Players.LocalPlayer.Character
end

-- middleware methods
Controller.GetMoveDirection = function(Character: Model): Vector3
    return MovementController.MoveVector or Vector3.new()
end

Controller.GetVelocity = function(Character: Model): Vector3
    return MovementController.Collider.AssemblyLinearVelocity or Vector3.new()
end

Controller.GetMoveSpeed = function(Character: Model): number
    return MovementController.AssemblyLinearVelocity.Magnitude or 0
end

Controller.IsGrounded =function(Character: Model): boolean
    Controller._Grounded = MovementController.Grounded
    return Controller._Grounded 
end

Controller.WasGrounded = function(Character: Model): boolean
    return Controller._Grounded
end

Controller.IsJumping = function(Character: Model): boolean
    return Controller.Jump or false
end

return Controller
