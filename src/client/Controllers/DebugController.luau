--[[
    
    Created Thursday, May 8th 2025, 8:45:33 pm
    RealEncryptal
    
--]]

local Controller = {}

Controller.Priority = 0

function Controller:Init()
    Controller.Iris = shared.Import("iris")
    Controller.Gizmo = shared.Import("imgizmo")

    Controller.Iris.Init()
    Controller.Gizmo.Init()
end



return Controller


--[[
EXAMPLE

local Gizmo = require(game:GetService("ReplicatedStorage"):WaitForChild("Gizmo"))
local ObjParser = require(script.ObjParser)

local Mesh = script.Mesh.Value
local ParsedObj = ObjParser(Mesh)

local function deepCopy(original)
	local copy = {}

	for k, v in pairs(original) do

		if type(v) == "table" then

			v = deepCopy(v)

		end

		copy[k] = v

	end

	return copy
end

local Iris = require(script.Iris).Init()

Gizmo.Init()

local Propertys = {
	DrawTriangles = true,
	AlwaysOnTop = true,

	Sizes = {
		BoxSize = Vector3.new(4, 4, 4),
		WedgeSize = Vector3.new(4, 4, 4),
		MeshSize = Vector3.new(5, 5, 5),
		SphereRadius = 2,
		CylinderRadius = 2,
		CylinderLength = 4,
		CapsuleRadius = 2,
		CapsuleLength = 4,
		ArrowRadius = 0.25,
		ArrowLength = 0.5,
	},

	Positions = {
		BoxPosition = Vector3.new(0, 5, 0),
		WedgePosition = Vector3.new(5, 5, 0),
		SpherePosition = Vector3.new(10, 5, 0),
		CylinderPosition = Vector3.new(15, 5, 0),
		CapsulePosition = Vector3.new(20, 5, 0),
		MeshPosition = Vector3.new(25, 5, 0),
		ArrowPosition = Vector3.new(-5, 5, 0),
		ArrowEndPosition = Vector3.new(-5, 10, 0),
	},

	Subdivision = {
		CylinderSubdivision = 20,
		CapsuleSubdivision = 20,
		SphereSubdivision = 20,
		ArrowSubdivision = 9,
	}
}

Iris:Connect(function()
	Iris.Window({"Edit Propertys", [Iris.Args.Window.NoClose] = true})

	local function AddProperty(Table)
		for k, v in Table do
			if type(v) == "table" then
				Iris.CollapsingHeader({k})
				AddProperty(v)
				Iris.End()
			end

			if typeof(v) == "Vector3" then
				local Input = Iris.InputVector3({k, Vector3.new(0.25, 0.25, 0.25)}, {number = v})

				Table[k] = Input.state.number.value
			end 

			if typeof(v) == "number" then
				local Input = Iris.SliderNum({k, 0.25, 0, 25}, {number = v})

				Table[k] = Input.state.number.value
			end 

			if typeof(v) == "boolean" then
				local Input = Iris.Checkbox({k}, {isChecked = v})

				Table[k] = Input.state.isChecked.value
			end
		end
	end

	AddProperty(Propertys)

	Iris.End()
end)

local Box = Gizmo.Box:Create(CFrame.new(Propertys.Positions.BoxPosition), Propertys.Sizes.BoxSize, Propertys.DrawTriangles)

Gizmo.TweenProperties(Box, {Color = Color3.new(1, 0.00392157, 0.486275)}, TweenInfo.new(10, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out))

local g_Style = Gizmo.Styles

game:GetService("RunService").RenderStepped:Connect(function(dt)
	local RotX = math.sin(tick() / 10) * 360
	local RotY = math.cos(tick() / 10) * 360
	local RotZ = (math.sin(tick() / 10) + math.cos(tick() / 10)) / 2 * 360

	local Rotation = CFrame.new()-- CFrame.Angles(math.rad(RotX), math.rad(RotY), math.rad(RotZ))
	
	Gizmo.PushProperty("AlwaysOnTop", Propertys.AlwaysOnTop)

	Box.Transform = CFrame.new(Propertys.Positions.BoxPosition) * Rotation
	Box.Size = Propertys.Sizes.BoxSize
	Box.DrawTriangles = Propertys.DrawTriangles

	
	debug.profilebegin("Cylinder")
	Gizmo.PushProperty(g_Style.Color, Color3.new(0.184314, 0.184314, 1))
	Gizmo.Cylinder:Draw(CFrame.new(Propertys.Positions.CylinderPosition) * Rotation, Propertys.Sizes.CylinderRadius, Propertys.Sizes.CylinderLength, Propertys.Subdivision.CylinderSubdivision)
	debug.profileend()
	
	debug.profilebegin("Capsule")
	Gizmo.PushProperty(g_Style.Color, Color3.new(1, 0.360784, 0.0431373))
	Gizmo.Capsule:Draw(CFrame.new(Propertys.Positions.CapsulePosition) * Rotation, Propertys.Sizes.CapsuleRadius, Propertys.Sizes.CapsuleLength, Propertys.Subdivision.CapsuleSubdivision)
	debug.profileend()
	
	debug.profilebegin("Sphere")
	Gizmo.SetStyle(Color3.new(0.67451, 0.278431, 1), 0, false)
	Gizmo.Sphere:Draw(CFrame.new(Propertys.Positions.SpherePosition) * Rotation, Propertys.Sizes.SphereRadius, Propertys.Subdivision.SphereSubdivision, 360)
	debug.profileend()
	
	debug.profilebegin("Wedge")
	Gizmo.PushProperty("Color3", Color3.new(0.309804, 1, 0.564706))
	Gizmo.Wedge:Draw(CFrame.new(Propertys.Positions.WedgePosition) * Rotation, Propertys.Sizes.WedgeSize, Propertys.DrawTriangles)
	debug.profileend()
	
	debug.profilebegin("Clone Vertex Data")
	local vertices = deepCopy(ParsedObj.v)
	local faces = deepCopy(ParsedObj.f)
	debug.profileend()

	Gizmo.PushProperty("Color3", Color3.new(1, 0.843137, 0.827451))
	
	debug.profilebegin("Mesh")
	Gizmo.Mesh:Draw(CFrame.new(Propertys.Positions.MeshPosition) * Rotation, Propertys.Sizes.MeshSize, vertices, faces)
	debug.profileend()
	
	debug.profilebegin("Arrow")
	Gizmo.Arrow:Draw(Propertys.Positions.ArrowPosition, Propertys.Positions.ArrowEndPosition, Propertys.Sizes.ArrowRadius, Propertys.Sizes.ArrowLength, Propertys.Subdivision.ArrowSubdivision)
	debug.profileend()
	
	debug.profilebegin("Text")
	Gizmo.PushProperty("Color3", Color3.new(0.8, 0, 0.8))
	Gizmo.Text:Draw(Vector3.new(0, 5, 0), "Hello world!!", 20)
	debug.profileend()
	
	script.Parent.Text = `Active Instances: {Gizmo.ActiveInstances}, Active Rays: {Gizmo.ActiveRays}, Always On Top: {Propertys.AlwaysOnTop}, Draw Triangles: {Propertys.DrawTriangles}, Pool Size: {Gizmo.GetPoolSize()}, Frame Time: {string.format("%0.4f", dt)}, Fps: {math.floor(1/dt)}`	
end)

while task.wait(0.25) do
	local x = math.random(-10, 10)
	local z = math.random(-10, 10)
	
	Gizmo.AddDebrisInSeconds(1, function()
		Gizmo.PushProperty("Color3", Color3.new(0.164706, 1, 0.678431))
		Gizmo.Box:Draw(CFrame.new(x - 20, 5, z), Vector3.new(2, 2, 2), true)
	end)
end
]]