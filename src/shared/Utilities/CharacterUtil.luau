--[[
    
    CharacterUtil
        Utility for character related functions
    
    Created Sunday, May 4th 2025, 6:59:15 pm
    RealEncryptal
    
--]]

local CharacterUtil = {
    _Grounded = false
}

-- middleware
function CharacterUtil.RequireCharacter(func: (Character: Model, ...any) -> any)
    return function(...)
        local Character = CharacterUtil.GetCharacter()
        if not Character then return end
        
        return func(Character, ...)
    end
end

-- methods
CharacterUtil.GetCharacter = function(): Model
    return game.Players.LocalPlayer.Character
end

-- middleware methods
CharacterUtil.GetMoveDirection = CharacterUtil.RequireCharacter(function(Character: Model): Vector3
    return Character.Humanoid.MoveDirection or Vector3.new()
end)

CharacterUtil.GetVelocity = CharacterUtil.RequireCharacter(function(Character: Model): Vector3
    return Character.PrimaryPart.AssemblyLinearVelocity or Vector3.new()
end)

CharacterUtil.GetMoveSpeed = CharacterUtil.RequireCharacter(function(Character: Model): number
    return Character.PrimaryPart.AssemblyLinearVelocity.Magnitude or 0
end)

CharacterUtil.IsGrounded = CharacterUtil.RequireCharacter(function(Character: Model): boolean
    CharacterUtil._Grounded = Character.Humanoid.FloorMaterial ~= Enum.Material.Air or false
    return CharacterUtil._Grounded
end)

CharacterUtil.WasGrounded = CharacterUtil.RequireCharacter(function(Character: Model): boolean
    return CharacterUtil._Grounded
end)

CharacterUtil.IsJumping = CharacterUtil.RequireCharacter(function(Character: Model): boolean
    return Character.Humanoid.Jump or false
end)

return CharacterUtil
