--!strict
--!native
--!optimize 2

--> Ballistic kinematics: position + velocity under constant gravity. The
--> `correction` term is a half-step Verlet adjustment matched to the dispatcher
--> frame rate (1 / 480 s); it cancels the bias introduced by sampling position
--> at frame boundaries and is small enough to ignore in user-facing math.

local HALF_STEP = 1 / 480
local EPSILON = 1e-6

local Kinematics = {}

local function vectorSqrt(v: Vector3): Vector3
	return Vector3.new(math.sqrt(v.X), math.sqrt(v.Y), math.sqrt(v.Z))
end

function Kinematics.positionAt(origin: Vector3, velocity: Vector3, gravity: Vector3, time: number): Vector3
	return origin + velocity * time + 0.5 * gravity * (time * time)
end

function Kinematics.velocityAt(velocity: Vector3, gravity: Vector3, time: number): Vector3
	return velocity + gravity * time
end

function Kinematics.correction(gravity: Vector3, time: number): Vector3
	return HALF_STEP * gravity * time
end

function Kinematics.positionAtCorrected(origin: Vector3, velocity: Vector3, gravity: Vector3, time: number): Vector3
	return Kinematics.positionAt(origin, velocity, gravity, time) + Kinematics.correction(gravity, time)
end

--> Inverse of positionAt under uniform gravity. Returns whichever of the two
--> quadratic roots lies closer to `referenceTime` — the simulation always wants
--> the root in the forward direction of travel. Falls back to `referenceTime`
--> when gravity is zero on the Y axis (no quadratic to solve).
function Kinematics.timeAtPosition(
	origin: Vector3,
	velocity: Vector3,
	gravity: Vector3,
	position: Vector3,
	referenceTime: number
): number
	if math.abs(gravity.Y) < EPSILON then
		return referenceTime
	end

	local a = -velocity - HALF_STEP * gravity
	local b = velocity + HALF_STEP * gravity
	local c = 2 * gravity * (origin - position)

	local disc = b * b - c
	local root = vectorSqrt(disc)

	local t1 = ((a - root) / gravity).Y
	local t2 = ((a + root) / gravity).Y

	local d1 = math.abs(referenceTime - t1)
	local d2 = math.abs(referenceTime - t2)

	return d1 < d2 and t1 or t2
end

return Kinematics
