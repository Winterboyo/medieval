--!strict
-- Medieval Land - two reversible look previews from the 2026-10-06 lighting pass, both OFF by
-- default. Toggle them live with Workspace attributes; turning one off restores exactly what it
-- changed. They are local to each client and purely visual.
--
--   PreviewPlayerHighlight  a thin team-coloured outline on OTHER players (never yourself),
--                           hidden behind walls (DepthMode Occluded) so it is not a wallhack.
--                           Tests whether players read better against tall grass and haze.
--                           Not a broad outline style: nothing else is outlined.
--   PreviewTextureVariation a small brightness variation (0-10% darker) on repeated Battlefield
--                           pieces (wall sections, pines, shore rocks) so long walls stop reading
--                           as one uniform band. Keyed to the mirrored position (|x|, z), so both
--                           castles vary identically. Never touches resource nodes, collision,
--                           geometry or positions.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

-- ---------------------------------------------------------------- player highlight
local HIGHLIGHT_NAME = "PreviewOutline"

local function outlineFor(other: Player): Color3
	local team = other.Team
	local c = if team then team.TeamColor.Color else Color3.fromRGB(230, 225, 210)
	return c:Lerp(Color3.new(0, 0, 0), 0.25)
end

local function setHighlight(other: Player, on: boolean)
	local character = other.Character
	if not character or other == player then
		return
	end
	local existing = character:FindFirstChild(HIGHLIGHT_NAME)
	if not on then
		if existing then
			existing:Destroy()
		end
		return
	end
	local h = if existing and existing:IsA("Highlight") then existing else Instance.new("Highlight")
	h.Name = HIGHLIGHT_NAME
	h.FillTransparency = 1
	h.OutlineTransparency = 0.45
	h.OutlineColor = outlineFor(other)
	h.DepthMode = Enum.HighlightDepthMode.Occluded
	h.Adornee = character
	h.Parent = character
end

local function highlightsOn(): boolean
	return Workspace:GetAttribute("PreviewPlayerHighlight") == true
end

local function refreshHighlights()
	for _, other in Players:GetPlayers() do
		setHighlight(other, highlightsOn())
	end
end

local function watchPlayer(other: Player)
	if other == player then
		return
	end
	other.CharacterAdded:Connect(function()
		task.defer(function()
			setHighlight(other, highlightsOn())
		end)
	end)
	other:GetPropertyChangedSignal("Team"):Connect(function()
		setHighlight(other, highlightsOn())
	end)
end
for _, other in Players:GetPlayers() do
	watchPlayer(other)
end
Players.PlayerAdded:Connect(watchPlayer)
Workspace:GetAttributeChangedSignal("PreviewPlayerHighlight"):Connect(refreshHighlights)
refreshHighlights()

-- ---------------------------------------------------------------- texture variation
local VARY = { "^Wall_", "^BF_Pines", "^BF_Shore_Rocks" }
local AMOUNT = 0.10 -- darken by 0-10%: these parts are often white (vertex colours), so brightening would clip
local original: { [BasePart]: Color3 } = {}

local function varies(name: string): boolean
	for _, pattern in VARY do
		if name:match(pattern) then
			return true
		end
	end
	return false
end

-- deterministic in the mirrored position, so a piece and its mirror get the same factor
local function factor(part: BasePart): number
	local p = part.Position
	local key = math.floor(math.abs(p.X) + 0.5) * 73856093 + math.floor(p.Z + 0.5) * 19349663
	local unit = (key % 1000) / 999 -- 0..1
	return 1 - unit * AMOUNT
end

local function setVariation(on: boolean)
	local field = Workspace:FindFirstChild("Battlefield")
	if not field then
		return
	end
	if on then
		for _, part in field:GetDescendants() do
			if part:IsA("BasePart") and varies(part.Name) and original[part] == nil then
				original[part] = part.Color
				local c, f = part.Color, factor(part)
				part.Color = Color3.new(math.clamp(c.R * f, 0, 1), math.clamp(c.G * f, 0, 1), math.clamp(c.B * f, 0, 1))
			end
		end
	else
		for part, colour in original do
			if part.Parent then
				part.Color = colour
			end
		end
		table.clear(original)
	end
end

Workspace:GetAttributeChangedSignal("PreviewTextureVariation"):Connect(function()
	setVariation(Workspace:GetAttribute("PreviewTextureVariation") == true)
end)
if Workspace:GetAttribute("PreviewTextureVariation") == true then
	setVariation(true)
end
