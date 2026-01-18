local VectorLib = {}

function VectorLib.ProjectOnPlane(Vector:Vector3, PlaneNormal:Vector3): Vector3
	local SqrMag = PlaneNormal:Dot(PlaneNormal)
	if SqrMag < 1e-8 then
		return Vector
	else
		local DotValue = Vector:Dot(PlaneNormal)
		return Vector3.new(
			Vector.X - PlaneNormal.X * DotValue / SqrMag,
			Vector.Y - PlaneNormal.Y * DotValue / SqrMag,
			Vector.Z - PlaneNormal.Z * DotValue / SqrMag
		)
	end
end

function VectorLib.ProjectAndScale(Vector:Vector3, Normal:Vector3): Vector3
	local Magnitude = Vector.Magnitude
	Vector = VectorLib.ProjectOnPlane(Vector, Normal).Unit
	Vector *= Magnitude
		
	return Vector
end

function VectorLib.SafeUnit(Vector:Vector3): Vector3
	if not Vector then
		return Vector3.zero
	end
	if Vector.Magnitude == 0 then
		return Vector3.zero
	end
	
	return Vector.Unit
end

function VectorLib.DegreesBetween(VectorA: Vector3, VectorB: Vector3): number
	local DotProduct = VectorA:Dot(VectorB)
	local MagnitudeA = VectorA.Magnitude
	local MagnitudeB = VectorB.Magnitude

	if MagnitudeA == 0 or MagnitudeB == 0 then
		return 0 -- Avoid division by zero
	end

	local CosTheta = DotProduct / (MagnitudeA * MagnitudeB)
	CosTheta = math.clamp(CosTheta, -1, 1)

	local AngleRadians = math.acos(CosTheta)
	local AngleDegrees = math.deg(AngleRadians)

	return AngleDegrees
end

return VectorLib