-- Constants
local ITERATIONS = 8

local Spring = {}
Spring.__index = Spring

function Spring.new(mass, force, damping, speed)
	local self = setmetatable({}, Spring)
	self.Target = Vector3.new()
	self.Position = Vector3.new()
	self.Velocity = Vector3.new()
	
	self.Mass = mass or 5
	self.Force = force or 50
	self.Damping = damping or 4
	self.Speed = speed or 4
	
	return self
end

function Spring:Shove(force)
	force *= 100
	local x, y, z = force.X, force.Y, force.Z
	if x ~= x or x == math.huge or x == -math.huge then x = 0 end
	if y ~= y or y == math.huge or y == -math.huge then y = 0 end
	if z ~= z or z == math.huge or z == -math.huge then z = 0 end
	
	self.Velocity = self.Velocity + Vector3.new(x, y, z)
end

function Spring:Update(dt)
	local scaledDeltaTime = math.min(dt, 1) * self.Speed / ITERATIONS
	
	for i = 1, ITERATIONS do
		local iterationForce = self.Target - self.Position
		local acceleration = (iterationForce * self.Force) / self.Mass
		acceleration = acceleration - self.Velocity * self.Damping
		
		self.Velocity = self.Velocity + acceleration * scaledDeltaTime
		self.Position = self.Position + self.Velocity * scaledDeltaTime
	end
	
	return self.Position
end

return Spring