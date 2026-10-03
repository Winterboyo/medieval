--!strict
-- Castle lighting and restrained environmental VFX for the approved layout.
-- All placements are symmetric and have no collision or gameplay effect.

local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local function owned(className: string, name: string, parent: Instance): Instance
	local current = parent:FindFirstChild(name)
	if current and current.ClassName ~= className then
		current:Destroy()
		current = nil
	end
	if not current then
		current = Instance.new(className)
		current.Name = name
		current.Parent = parent
	end
	return current
end

local atmosphere = owned("Atmosphere", "Atmosphere", Lighting) :: Atmosphere
local grade = owned("ColorCorrectionEffect", "ColorCorrection", Lighting) :: ColorCorrectionEffect
local bloom = owned("BloomEffect", "Bloom", Lighting) :: BloomEffect
local sunRays = owned("SunRaysEffect", "SunRays", Lighting) :: SunRaysEffect
local depth = owned("DepthOfFieldEffect", "DepthOfField", Lighting) :: DepthOfFieldEffect
local clouds = owned("Clouds", "Clouds", Workspace.Terrain) :: Clouds

-- The skybox is original art: a golden-hour gradient with faceted low-poly cumulus,
-- rendered in Blender by assets/sky/build_sky.py and uploaded as images. Its warm glow is
-- painted where the sun stands at ClockTime 16.4 (latitude -12): low in the north-west,
-- behind Castle A from the field. Change the clock and the glow no longer matches.
-- All six faces must be the same size; a smaller one breaks environment lighting (magenta).
local sky = owned("Sky", "Sky", Lighting) :: Sky
sky.SkyboxFt = "rbxassetid://125025616651962"
sky.SkyboxBk = "rbxassetid://115298958132412"
sky.SkyboxLf = "rbxassetid://118607207189786"
sky.SkyboxRt = "rbxassetid://136975032525324"
sky.SkyboxUp = "rbxassetid://85577216608863"
sky.SkyboxDn = "rbxassetid://127934957660455"
sky.CelestialBodiesShown = true
sky.SunAngularSize = 12
sky.MoonAngularSize = 9
sky.StarCount = 0

local function setWeather(preset: string)
	local wet = preset == "Rain"
	local overcast = wet or preset == "Overcast"
	pcall(function() Lighting.LightingStyle = Enum.LightingStyle.Realistic end)
	Lighting.ClockTime = 16.4 -- the painted sky's sun position; long, warm late-afternoon shadows
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = if overcast then 0.45 else 0.25
	Lighting.Brightness = if overcast then 1.8 else 2.6
	Lighting.ExposureCompensation = if overcast then -0.13 else 0
	Lighting.Ambient = if overcast then Color3.fromRGB(77, 82, 88) else Color3.fromRGB(70, 72, 84)
	Lighting.OutdoorAmbient = if overcast then Color3.fromRGB(122, 130, 136) else Color3.fromRGB(128, 124, 134)
	Lighting.ColorShift_Top = if overcast then Color3.fromRGB(224, 229, 232) else Color3.fromRGB(255, 226, 186)
	Lighting.ColorShift_Bottom = Color3.fromRGB(0, 0, 0)
	-- the skybox lights the scene too: warm from the sun side, cool from the open sky
	Lighting.EnvironmentDiffuseScale = 1
	Lighting.EnvironmentSpecularScale = 0.35
	atmosphere.Density = if overcast then 0.30 else 0.26
	atmosphere.Offset = if overcast then 0.04 else 0.1
	atmosphere.Haze = if overcast then 0.9 else 0.55
	atmosphere.Glare = if overcast then 0.03 else 0.25
	atmosphere.Color = if overcast then Color3.fromRGB(183, 194, 200) else Color3.fromRGB(222, 212, 196)
	atmosphere.Decay = if overcast then Color3.fromRGB(114, 125, 135) else Color3.fromRGB(164, 172, 196)
	grade.Brightness = 0
	grade.Contrast = if overcast then 0.08 else 0.12
	grade.Saturation = if overcast then -0.08 else 0.12
	grade.TintColor = if overcast then Color3.fromRGB(230, 236, 239) else Color3.fromRGB(255, 244, 228)
	bloom.Intensity = if overcast then 0.16 else 0.35
	bloom.Size = 28
	bloom.Threshold = if overcast then 1.75 else 1.15
	sunRays.Intensity = if overcast then 0.025 else 0.07
	sunRays.Spread = 0.75
	-- a soft far blur gives the island the concept's painted, miniature distance
	depth.FarIntensity = if overcast then 0.1 else 0.18
	depth.FocusDistance = 140
	depth.InFocusRadius = 160
	depth.NearIntensity = 0
	-- dynamic clouds only for bad weather; on clear days the painted sky carries them
	clouds.Enabled = overcast
	clouds.Cover = if wet then 0.78 else 0.61
	clouds.Density = 0.48
	clouds.Color = Color3.fromRGB(188, 195, 197)
end

local effects = owned("Folder", "CastleVisualEffects", Workspace)

local function anchor(name: string, position: Vector3): Part
	local p = owned("Part", name, effects) :: Part
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = Vector3.new(0.2, 0.2, 0.2)
	p.Position = position
	return p
end

local function lantern(name: string, position: Vector3, color: Color3, brightness: number, range: number)
	local p = anchor(name, position)
	local light = owned("PointLight", "Glow", p) :: PointLight
	light.Color = color
	light.Brightness = brightness
	light.Range = range
	light.Shadows = true
	return p
end

local function forge(team: string, x: number)
	-- The visual fire table is six studs east of A's forge centre (mirrored on B).
	local p = lantern(team .. "_ForgeFire", Vector3.new(x, 14.5, 67),
		Color3.fromRGB(255, 158, 93), 0.95, 16)
	local smoke = owned("ParticleEmitter", "Smoke", p) :: ParticleEmitter
	smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
	smoke.Rate = 5
	smoke.Lifetime = NumberRange.new(2.4, 3.5)
	smoke.Speed = NumberRange.new(1.1, 2.3)
	smoke.SpreadAngle = Vector2.new(20, 20)
	smoke.RotSpeed = NumberRange.new(-20, 20)
	smoke.Acceleration = Vector3.new(0, 1.7, 0)
	smoke.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.7),
		NumberSequenceKeypoint.new(0.35, 1.8),
		NumberSequenceKeypoint.new(1, 3.3),
	})
	smoke.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.48),
		NumberSequenceKeypoint.new(0.45, 0.72),
		NumberSequenceKeypoint.new(1, 1),
	})
	smoke.Color = ColorSequence.new(Color3.fromRGB(115, 108, 100), Color3.fromRGB(163, 157, 149))
	smoke.LightInfluence = 0.6
	local sparks = owned("ParticleEmitter", "Embers", p) :: ParticleEmitter
	sparks.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	sparks.Rate = 8
	sparks.Lifetime = NumberRange.new(0.45, 0.9)
	sparks.Speed = NumberRange.new(1, 3.2)
	sparks.SpreadAngle = Vector2.new(32, 32)
	sparks.Acceleration = Vector3.new(0, 3.5, 0)
	sparks.Size = NumberSequence.new(0.13)
	sparks.Transparency = NumberSequence.new(0.18, 1)
	sparks.Color = ColorSequence.new(Color3.fromRGB(255, 188, 83), Color3.fromRGB(231, 93, 38))
	sparks.LightEmission = 0.65
end

for _, side in { { "A", -1 }, { "B", 1 } } do
	local team, sign = side[1] :: string, side[2] :: number
	forge(team, sign * 272)
	lantern(team .. "_FletcherLantern", Vector3.new(sign * 226.5, 17.2, -63), Color3.fromRGB(255, 204, 136), 0.72, 14)
	lantern(team .. "_AlchemistLantern", Vector3.new(sign * 286, 17.2, -63), Color3.fromRGB(246, 204, 145), 0.72, 14)
	lantern(team .. "_CarpenterLantern", Vector3.new(sign * 237, 17.2, 60), Color3.fromRGB(255, 204, 136), 0.72, 14)
end

if Workspace:GetAttribute("WeatherPreset") == nil then
	Workspace:SetAttribute("WeatherPreset", "Clear")
end
setWeather(Workspace:GetAttribute("WeatherPreset") :: string)
Workspace:GetAttributeChangedSignal("WeatherPreset"):Connect(function()
	setWeather(Workspace:GetAttribute("WeatherPreset") :: string)
end)
