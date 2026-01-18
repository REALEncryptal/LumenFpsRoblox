local function calculateRawMoveVector(cameraRelativeMoveVector: Vector3, swimming:boolean?): Vector3
	local camera = workspace.CurrentCamera
	if not camera then
		return cameraRelativeMoveVector
	end
	local cameraCFrame = camera.CFrame

	if swimming then	
		return cameraCFrame:VectorToWorldSpace(cameraRelativeMoveVector)
	end

	local c, s
	local _, _, _, R00, R01, R02, _, _, R12, _, _, R22 = cameraCFrame:GetComponents()
	if R12 < 1 and R12 > -1 then
		-- X and Z components from back vector.
		c = R22
		s = R02
	else
		-- In this case the camera is looking straight up or straight down.
		-- Use X components from right and up vectors.
		c = R00
		s = -R01*math.sign(R12)
	end
	local norm = math.sqrt(c*c + s*s)
	return Vector3.new(
		(c*cameraRelativeMoveVector.X + s*cameraRelativeMoveVector.Z)/norm,
		0,
		(c*cameraRelativeMoveVector.Z - s*cameraRelativeMoveVector.X)/norm
	)
end

return calculateRawMoveVector