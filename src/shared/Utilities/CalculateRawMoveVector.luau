local function CalculateRawMoveVector(CameraRelativeMoveVector: Vector3, Swimming: boolean?): Vector3
	local Camera = workspace.CurrentCamera
	if not Camera then
		return CameraRelativeMoveVector
	end
	local CameraCFrame = Camera.CFrame

	if Swimming then
		return CameraCFrame:VectorToWorldSpace(CameraRelativeMoveVector)
	end

	local C, S
	local _, _, _, R00, R01, R02, _, _, R12, _, _, R22 = CameraCFrame:GetComponents()
	if R12 < 1 and R12 > -1 then
		-- X and Z components from back vector.
		C = R22
		S = R02
	else
		-- In this case the camera is looking straight up or straight down.
		-- Use X components from right and up vectors.
		C = R00
		S = -R01 * math.sign(R12)
	end
	local Norm = math.sqrt(C * C + S * S)
	return Vector3.new(
		(C * CameraRelativeMoveVector.X + S * CameraRelativeMoveVector.Z) / Norm,
		0,
		(C * CameraRelativeMoveVector.Z - S * CameraRelativeMoveVector.X) / Norm
	)
end

return CalculateRawMoveVector
