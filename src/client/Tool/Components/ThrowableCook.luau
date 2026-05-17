--[[
    ThrowableCook Component

    State machine for cookable throwables:

        Idle ──Begin──> Cooking ──End──> Throwing ──(throw anim ends)──> Idle
                            │
                            └──(FuseTime elapsed)──> Throwing  (auto-throw,
                                                                 CookElapsed=fuse)

    Holding MB1 starts the cook timer (plays optional PinPull then Cook
    animations). Releasing MB1 fires the throw — ThrowableSpawn picks it up
    from the OnThrow signal and hands the projectile to ProjectileController.
    Holding past FuseTime auto-throws in place so the grenade explodes in your
    hand.

    Config:
        FuseTime           number? — total fuse from cook-start (default Data.FuseTime or 5)
        CookAnimation      string? — defaults to "Cook"
        ThrowAnimation     string? — defaults to "Throw"
        PinPullAnimation   string? — defaults to "PinPull"
        ThrowAnimationTime number? — how long the throw animation takes before we return to Idle (defaults 0.5)

    Other components subscribe to:
        Cook.OnThrow:Connect(function(CookElapsed) ... end)
            — emitted from the Cooking → Throwing transition. ThrowableSpawn
            listens here.
]]

local Signal = shared.Import("Signal")
local Trove = shared.Import("Trove")

local ThrowableCook = {}
ThrowableCook.__index = ThrowableCook

ThrowableCook.Bindings = {
    Throw = {
        Inputs = {Enum.UserInputType.MouseButton1},
        OnState = function(self, State)
            if State == Enum.UserInputState.Begin then
                self:Begin()
            elseif State == Enum.UserInputState.End then
                self:End()
            end
        end,
    },
}

function ThrowableCook.new(Tool, Config)
    local self = setmetatable({}, ThrowableCook)
    self.Tool = Tool
    self.Config = Config

    self.FuseTime = Config.FuseTime or Tool.Data.FuseTime or 5
    self.CookAnimation = Config.CookAnimation or "Cook"
    self.ThrowAnimation = Config.ThrowAnimation or "Throw"
    self.PinPullAnimation = Config.PinPullAnimation or "PinPull"
    self.ThrowAnimationTime = Config.ThrowAnimationTime or 0.5

    self.State = "Idle"
    self.CookStart = 0

    self.Trove = Trove.new()
    self.OnThrow = self.Trove:Add(Signal.new())
    return self
end

function ThrowableCook:_Inventory()
    return self.Tool:GetComponent("ThrowableInventory")
end

function ThrowableCook:_PlayAnimation(Name: string, FadeTime: number?)
    local Animation = self.Tool.Animations[Name]
    if Animation then
        Animation:Play(FadeTime)
    end
end

function ThrowableCook:_StopAnimation(Name: string)
    local Animation = self.Tool.Animations[Name]
    if Animation then Animation:Stop() end
end

function ThrowableCook:Init()
    -- Fuse timeout watcher. Runs at priority 110 (after springs and viewmodel
    -- so it doesn't fight the visual pipeline). Auto-throws when held past fuse.
    self.Tool:AddUpdateTask("CookFuseWatch", 110, function(_Dt)
        if self.State ~= "Cooking" then return end
        local Elapsed = tick() - self.CookStart
        if Elapsed >= self.FuseTime then
            self:_CompleteThrow(self.FuseTime)
        end
    end)
end

function ThrowableCook:CookElapsed(): number
    if self.State ~= "Cooking" then return 0 end
    return tick() - self.CookStart
end

function ThrowableCook:Begin()
    if self.State ~= "Idle" then return end

    local Inventory = self:_Inventory()
    if Inventory and not Inventory:Has() then return end

    self.State = "Cooking"
    self.CookStart = tick()

    self:_PlayAnimation(self.PinPullAnimation, 0)
    self:_PlayAnimation(self.CookAnimation, 0.1)
end

function ThrowableCook:End()
    if self.State ~= "Cooking" then return end
    self:_CompleteThrow(self:CookElapsed())
end

function ThrowableCook:_CompleteThrow(CookElapsed: number)
    self.State = "Throwing"

    self:_StopAnimation(self.CookAnimation)
    self:_StopAnimation(self.PinPullAnimation)
    self:_PlayAnimation(self.ThrowAnimation, 0)

    self.OnThrow:Fire(CookElapsed)

    -- Return to Idle once the throw animation should be done so the next
    -- press can begin another cook. We don't gate on the actual animation
    -- end signal because some assets may not have a throw animation at all.
    task.delay(self.ThrowAnimationTime, function()
        if self.State == "Throwing" then
            self.State = "Idle"
        end
    end)
end

function ThrowableCook:Unequip()
    -- A grenade held in cook state is functionally a live one. If the player
    -- swaps tools while cooking, auto-throw it in place rather than silently
    -- cancelling — matches typical FPS expectations.
    if self.State == "Cooking" then
        self:_CompleteThrow(self:CookElapsed())
    end
end

function ThrowableCook:GetHudContribution()
    if self.State ~= "Cooking" then return nil end
    local Remaining = math.max(0, self.FuseTime - self:CookElapsed())
    return {
        Secondary = string.format("%.1f", Remaining),
    }
end

function ThrowableCook:CreateDebug(Iris)
    Iris.Text({"State: " .. self.State})
    if self.State == "Cooking" then
        Iris.Text({"Cook Elapsed: " .. string.format("%.2f", self:CookElapsed()) .. " / " .. self.FuseTime})
    end
end

function ThrowableCook:Destroy()
    self.Trove:Destroy()
end

return ThrowableCook
