--[[
    ThrowableCook Component

    State machine for cookable throwables:

        Idle ──Begin──> Cooking ──End──> Throwing ──(throw anim ends)──> Idle
                            │
                            └──(FuseTime elapsed)──> Throwing  (auto-throw,
                                                                 cookElapsed=fuse)

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
        cook.OnThrow:Connect(function(cookElapsed) ... end)
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
        OnState = function(self, state)
            if state == Enum.UserInputState.Begin then
                self:Begin()
            elseif state == Enum.UserInputState.End then
                self:End()
            end
        end,
    },
}

function ThrowableCook.new(tool, config)
    local self = setmetatable({}, ThrowableCook)
    self.Tool = tool
    self.Config = config

    self.FuseTime = config.FuseTime or tool.Data.FuseTime or 5
    self.CookAnimation = config.CookAnimation or "Cook"
    self.ThrowAnimation = config.ThrowAnimation or "Throw"
    self.PinPullAnimation = config.PinPullAnimation or "PinPull"
    self.ThrowAnimationTime = config.ThrowAnimationTime or 0.5

    self.State = "Idle"
    self.CookStart = 0

    self.Trove = Trove.new()
    self.OnThrow = self.Trove:Add(Signal.new())
    return self
end

function ThrowableCook:_inventory()
    return self.Tool:GetComponent("ThrowableInventory")
end

function ThrowableCook:_playAnimation(name: string, fadeTime: number?)
    local animation = self.Tool.Animations[name]
    if animation then
        animation:Play(fadeTime)
    end
end

function ThrowableCook:_stopAnimation(name: string)
    local animation = self.Tool.Animations[name]
    if animation then animation:Stop() end
end

function ThrowableCook:Init()
    -- Fuse timeout watcher. Runs at priority 110 (after springs and viewmodel
    -- so it doesn't fight the visual pipeline). Auto-throws when held past fuse.
    self.Tool:AddUpdateTask("CookFuseWatch", 110, function(_dt)
        if self.State ~= "Cooking" then return end
        local elapsed = tick() - self.CookStart
        if elapsed >= self.FuseTime then
            self:_completeThrow(self.FuseTime)
        end
    end)
end

function ThrowableCook:CookElapsed(): number
    if self.State ~= "Cooking" then return 0 end
    return tick() - self.CookStart
end

function ThrowableCook:Begin()
    if self.State ~= "Idle" then return end

    local inventory = self:_inventory()
    if inventory and not inventory:Has() then return end

    self.State = "Cooking"
    self.CookStart = tick()

    self:_playAnimation(self.PinPullAnimation, 0)
    self:_playAnimation(self.CookAnimation, 0.1)
end

function ThrowableCook:End()
    if self.State ~= "Cooking" then return end
    self:_completeThrow(self:CookElapsed())
end

function ThrowableCook:_completeThrow(cookElapsed: number)
    self.State = "Throwing"

    self:_stopAnimation(self.CookAnimation)
    self:_stopAnimation(self.PinPullAnimation)
    self:_playAnimation(self.ThrowAnimation, 0)

    self.OnThrow:Fire(cookElapsed)

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
        self:_completeThrow(self:CookElapsed())
    end
end

function ThrowableCook:GetHudContribution()
    if self.State ~= "Cooking" then return nil end
    local remaining = math.max(0, self.FuseTime - self:CookElapsed())
    return {
        secondary = string.format("%.1f", remaining),
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
