--!strict
-- Camera-local rain keeps weather inexpensive on a large mirrored battlefield.
-- The default preset is Clear; Workspace.WeatherPreset may be set to Rain.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local field = Instance.new("Part")
field.Name = "LocalRainField"
field.Anchored = true
field.CanCollide = false
field.CanQuery = false
field.CanTouch = false
field.CastShadow = false
field.Transparency = 1
field.Size = Vector3.new(48, 0.2, 48)
field.Parent = Workspace

local rain = Instance.new("ParticleEmitter")
rain.Name = "Rain"
rain.Texture = "rbxasset://textures/particles/sparkles_main.dds"
rain.EmissionDirection = Enum.NormalId.Bottom
rain.Rate = 260
rain.Lifetime = NumberRange.new(0.4, 0.65)
rain.Speed = NumberRange.new(55, 69)
rain.Acceleration = Vector3.new(0, -35, 0)
rain.SpreadAngle = Vector2.new(4, 4)
rain.Size = NumberSequence.new(0.075)
rain.Transparency = NumberSequence.new(0.36, 0.65)
rain.Color = ColorSequence.new(Color3.fromRGB(181, 205, 216))
rain.LightInfluence = 1
rain.Enabled = false
rain.Parent = field

local player = Players.LocalPlayer
local elapsed = 0
RunService.RenderStepped:Connect(function(dt)
	local camera = Workspace.CurrentCamera
	if not camera then return end
	field.Position = camera.CFrame.Position + Vector3.new(0, 23, 0)
	elapsed += dt
	if elapsed < 0.28 then return end
	elapsed = 0
	if Workspace:GetAttribute("WeatherPreset") ~= "Rain" then
		rain.Enabled = false
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		rain.Enabled = false
		return
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character, field }
	local shelter = Workspace:Raycast(root.Position, Vector3.new(0, 22, 0), params)
	rain.Enabled = shelter == nil
end)
