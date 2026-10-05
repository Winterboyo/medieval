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
-- The "Gritty" preset swaps in the overcast warm-grey deck from the same script
-- (build("overcast")) and hides the sun disc.
local GOLDEN_SKY = {
	Ft = "rbxassetid://125025616651962",
	Bk = "rbxassetid://115298958132412",
	Lf = "rbxassetid://118607207189786",
	Rt = "rbxassetid://136975032525324",
	Up = "rbxassetid://85577216608863",
	Dn = "rbxassetid://127934957660455",
}
local OVERCAST_SKY = {
	Ft = "rbxassetid://109973027061798",
	Bk = "rbxassetid://140555260418044",
	Lf = "rbxassetid://83772241168916",
	Rt = "rbxassetid://89259834518061",
	Up = "rbxassetid://134389785252545",
	Dn = "rbxassetid://102841679008854",
}
local sky = owned("Sky", "Sky", Lighting) :: Sky
sky.SunAngularSize = 12
sky.MoonAngularSize = 9
sky.StarCount = 0

local function setSky(faces: { [string]: string }, sunShown: boolean)
	sky.SkyboxFt = faces.Ft
	sky.SkyboxBk = faces.Bk
	sky.SkyboxLf = faces.Lf
	sky.SkyboxRt = faces.Rt
	sky.SkyboxUp = faces.Up
	sky.SkyboxDn = faces.Dn
	sky.CelestialBodiesShown = sunShown
end

-- "Gritty": the overcast warm-grey daylight from REALISM-TARGET.md (The Forge's outdoor look).
-- Low, diffuse light, a warm-grey cloud deck hiding the painted sky, near-black interiors so
-- torches and braziers carry them, saturation kept in the darks, a little contrast.
local function setGritty()
	pcall(function() Lighting.LightingStyle = Enum.LightingStyle.Realistic end)
	setSky(OVERCAST_SKY, false)
	Lighting.ClockTime = 14.2
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = 0.9
	Lighting.Brightness = 1.0 -- the sun is behind the deck: soft shadows; the warm-grey fill does most of the lighting
	Lighting.ExposureCompensation = -0.05
	Lighting.Ambient = Color3.fromRGB(34, 32, 32)
	Lighting.OutdoorAmbient = Color3.fromRGB(185, 178, 166)
	Lighting.ColorShift_Top = Color3.fromRGB(214, 202, 184)
	Lighting.ColorShift_Bottom = Color3.fromRGB(0, 0, 0)
	Lighting.EnvironmentDiffuseScale = 0.8
	Lighting.EnvironmentSpecularScale = 0.25
	atmosphere.Density = 0.36
	atmosphere.Offset = 0.05
	atmosphere.Haze = 1.4
	atmosphere.Glare = 0
	atmosphere.Color = Color3.fromRGB(181, 172, 156)
	atmosphere.Decay = Color3.fromRGB(150, 140, 126)
	grade.Brightness = 0
	grade.Contrast = 0.1
	grade.Saturation = 0
	grade.TintColor = Color3.fromRGB(255, 248, 238)
	bloom.Intensity = 0.45
	bloom.Size = 24
	bloom.Threshold = 1.1
	sunRays.Intensity = 0
	depth.FarIntensity = 0.12
	depth.FocusDistance = 140
	depth.InFocusRadius = 160
	depth.NearIntensity = 0
	clouds.Enabled = false -- the overcast skybox is the cloud deck
end

local function setWeather(preset: string)
	if preset == "Gritty" then
		setGritty()
		return
	end
	local wet = preset == "Rain"
	local overcast = wet or preset == "Overcast"
	pcall(function() Lighting.LightingStyle = Enum.LightingStyle.Realistic end)
	setSky(GOLDEN_SKY, true)
	Lighting.ClockTime = 16.4 -- the painted sky's sun position; long, warm late-afternoon shadows
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = if overcast then 0.45 else 0.25
	Lighting.Brightness = if overcast then 1.8 else 2.0
	Lighting.ExposureCompensation = if overcast then -0.13 else -0.2
	Lighting.Ambient = if overcast then Color3.fromRGB(77, 82, 88) else Color3.fromRGB(70, 76, 92)
	-- cool sky fill: shadows go blue-grey like the references, not saturated green
	Lighting.OutdoorAmbient = if overcast then Color3.fromRGB(122, 130, 136) else Color3.fromRGB(136, 148, 176)
	Lighting.ColorShift_Top = if overcast then Color3.fromRGB(224, 229, 232) else Color3.fromRGB(255, 222, 180)
	Lighting.ColorShift_Bottom = Color3.fromRGB(0, 0, 0)
	-- the skybox lights the scene too: warm from the sun side, cool from the open sky
	Lighting.EnvironmentDiffuseScale = 1
	-- no sky reflections: the references are matte; this was putting a plastic sheen on the grass
	Lighting.EnvironmentSpecularScale = 0
	atmosphere.Density = if overcast then 0.30 else 0.2
	atmosphere.Offset = if overcast then 0.04 else 0.1
	atmosphere.Haze = if overcast then 0.9 else 0.1 -- thin, so the sea and sky keep their blue
	atmosphere.Glare = if overcast then 0.03 else 0.1
	atmosphere.Color = if overcast then Color3.fromRGB(183, 194, 200) else Color3.fromRGB(204, 206, 210)
	atmosphere.Decay = if overcast then Color3.fromRGB(114, 125, 135) else Color3.fromRGB(120, 140, 170)
	grade.Brightness = 0
	grade.Contrast = if overcast then 0.08 else 0.04
	-- the baked mesh greens are brighter than the references; pull them toward olive
	grade.Saturation = if overcast then -0.08 else -0.16
	grade.TintColor = if overcast then Color3.fromRGB(230, 236, 239) else Color3.fromRGB(255, 246, 234)
	bloom.Intensity = if overcast then 0.16 else 0.25
	bloom.Size = 28
	bloom.Threshold = if overcast then 1.75 else 1.3
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

local function forge(team: string, x: number, z: number)
	local p = lantern(team .. "_ForgeFire", Vector3.new(x, 14.5, z),
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

-- Placed from layout.json's interior (each specialist building's centre), so the lights follow the
-- castles when the layout moves; the forge fire stands six studs gate-side of the forge centre and
-- six deeper in from its door, where the fire table is.
local Layout = require(game:GetService("ServerStorage"):WaitForChild("Layout")) :: any
local LANTERN = {
	Fletcher = Color3.fromRGB(255, 204, 136),
	Alchemist = Color3.fromRGB(246, 204, 145),
	Carpenter = Color3.fromRGB(255, 204, 136),
}
for _, castle in Layout.castles do
	local team = castle.team :: string
	local toGate = math.sign(castle.gate.x - castle.center.x)
	for _, s in (castle.interior and castle.interior.specialists) or {} do
		local cx, cz = (s.min_x + s.max_x) / 2, (s.min_z + s.max_z) / 2
		if s.role == "Blacksmith" then
			forge(team, cx + 6 * toGate, cz + 6 * math.sign(cz - s.door.z))
		elseif LANTERN[s.role] then
			lantern(team .. "_" .. s.role .. "Lantern", Vector3.new(cx, 17.2, cz), LANTERN[s.role], 0.72, 14)
		end
	end
end

if Workspace:GetAttribute("WeatherPreset") == nil then
	Workspace:SetAttribute("WeatherPreset", "Clear")
end
setWeather(Workspace:GetAttribute("WeatherPreset") :: string)
Workspace:GetAttributeChangedSignal("WeatherPreset"):Connect(function()
	setWeather(Workspace:GetAttribute("WeatherPreset") :: string)
end)
