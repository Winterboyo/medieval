--!strict
-- Medieval Land - the two-team heads-up display.
--
-- Layout contract: AGENTS.md §8 and DESIGN.md "HUD and feedback target" (decisions 2026-10-03):
--   top-left      health, and stamina once a sprint system publishes it
--   top-centre    empty on purpose
--   top-right     minimap; under it the match clock and both castles' standing
--   bottom-left   goods: the team stockpile, and what you carry once cargo exists
--   bottom-centre the context prompt (every ProximityPrompt is drawn here), only when relevant
--   bottom-right  event feed: match and siege events for the teams, by team name
--   M             the full map (tap the minimap on touch screens)
-- Never: wall-breach lines, kill or elimination counters, resources on the leaderboard.
--
-- Style: the low-key look of REALISM-TARGET.md (Palette.HUD). On touch screens the
-- bottom corners move up out of the thumbstick and jump-button zones, and everything
-- scales with the screen.
--
-- A READER. Everything below is state the server already replicates: Workspace attributes
-- (MatchState, MatchClock, MatchResult), each castle's attributes and structures, the
-- team's Goods folder, Workspace.ResourceNodes and Workspace.Boundary. It opens no remote.
--
-- Contracts for systems that are not built yet; the HUD shows them as soon as they appear:
--   * Player attributes Stamina and StaminaMax (numbers): the stamina bar.
--   * A Player child folder "Cargo" of IntValues named like the team's Goods: a "Carried"
--     column next to the stockpile.
--   * A structure with Kind "Keep" and a Health attribute: "<Team> Keep under attack".

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local StarterGui = game:GetService("StarterGui")
local Teams = game:GetService("Teams")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Palette = require(Shared:WaitForChild("Palette"))
local GameMode = require(Shared:WaitForChild("GameMode"))
if not GameMode.TwoTeam then
	return -- Conquest draws HudConquest.client.luau
end

local HUD = Palette.HUD
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ours replaces Roblox's own health bar
task.spawn(function()
	for _ = 1, 10 do
		if pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
		end) then
			return
		end
		task.wait(1)
	end
end)

-- A phone or tablet without a keyboard: the thumbstick owns the bottom-left and the jump
-- button the bottom-right, so those corners move up.
local TOUCH = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

local FADE = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local GAP = 12

-- ---------------------------------------------------------------- building blocks
local function corner(into: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = into
end

local function panel(parent: Instance, name: string, size: UDim2, position: UDim2, anchor: Vector2): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.Size = size
	f.Position = position
	f.AnchorPoint = anchor
	f.BackgroundColor3 = HUD.PANEL
	f.BackgroundTransparency = HUD.PANEL_ALPHA
	f.BorderSizePixel = 0
	corner(f, HUD.CORNER)
	local stroke = Instance.new("UIStroke")
	stroke.Color = HUD.EDGE
	stroke.Transparency = HUD.EDGE_ALPHA
	stroke.Thickness = 1
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = f
	f.Parent = parent
	return f
end

local function text(parent: Instance, name: string, size: UDim2, position: UDim2, font: Enum.Font,
	textSize: number, colour: Color3, align: Enum.TextXAlignment?): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.Size = size
	t.Position = position
	t.BackgroundTransparency = 1
	t.Font = font
	t.TextSize = textSize
	t.TextColor3 = colour
	t.TextXAlignment = align or Enum.TextXAlignment.Left
	t.TextYAlignment = Enum.TextYAlignment.Center
	t.Text = ""
	t.Parent = parent
	return t
end

-- a track with a fill; returns the fill (its X scale is the value)
local function bar(parent: Instance, name: string, size: UDim2, position: UDim2, colour: Color3): Frame
	local track = Instance.new("Frame")
	track.Name = name
	track.Size = size
	track.Position = position
	track.BackgroundColor3 = HUD.TRACK
	track.BackgroundTransparency = 0.15
	track.BorderSizePixel = 0
	corner(track, 2)
	track.Parent = parent
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = colour
	fill.BorderSizePixel = 0
	corner(fill, 2)
	fill.Parent = track
	return fill
end

local function setFill(fill: Frame, fraction: number)
	fill.Size = UDim2.fromScale(math.clamp(fraction, 0, 1), 1)
end

local function clockFace(seconds: number): string
	local whole = math.max(0, math.floor(seconds))
	return ("%d:%02d"):format(whole // 60, whole % 60)
end

-- ---------------------------------------------------------------- the screen
local old = playerGui:FindFirstChild("Hud")
if old then
	old:Destroy()
end
local gui = Instance.new("ScreenGui")
gui.Name = "Hud"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets -- clears Roblox's top bar and device notches
gui.Parent = playerGui

local uiScale = Instance.new("UIScale")
uiScale.Parent = gui
local function rescale()
	local camera = Workspace.CurrentCamera
	local view = if camera then camera.ViewportSize else Vector2.new(1280, 720)
	uiScale.Scale = math.clamp(math.min(view.X / 1280, view.Y / 720), 0.6, 1.3)
end
rescale()
local function watchCamera()
	local camera = Workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
	end
	rescale()
end
watchCamera()
Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)

-- ---------------------------------------------------------------- top-left: you
local VITAL_W = 250
local vitals = panel(gui, "Vitals", UDim2.fromOffset(VITAL_W, 40), UDim2.fromOffset(GAP, GAP), Vector2.zero)
local healthFill = bar(vitals, "Health", UDim2.fromOffset(VITAL_W - 62, 12), UDim2.fromOffset(10, 14), HUD.HEALTH)
local healthText = text(vitals, "HealthValue", UDim2.fromOffset(42, 20), UDim2.fromOffset(VITAL_W - 50, 10),
	Palette.FONT_STRONG, 15, HUD.TEXT, Enum.TextXAlignment.Right)
local staminaFill = bar(vitals, "Stamina", UDim2.fromOffset(VITAL_W - 62, 5), UDim2.fromOffset(10, 32), HUD.STAMINA)
local staminaTrack = staminaFill.Parent :: Frame
staminaTrack.Visible = false

local humanoidConnection: RBXScriptConnection? = nil
local function drawHealth(humanoid: Humanoid)
	local max = math.max(humanoid.MaxHealth, 1)
	setFill(healthFill, humanoid.Health / max)
	healthText.Text = tostring(math.max(0, math.ceil(humanoid.Health)))
	healthFill.BackgroundColor3 = if humanoid.Health / max < 0.3 then HUD.DANGER else HUD.HEALTH
end
local function watchCharacter(character: Model)
	if humanoidConnection then
		humanoidConnection:Disconnect()
	end
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid and humanoid:IsA("Humanoid") then
		drawHealth(humanoid)
		humanoidConnection = humanoid.HealthChanged:Connect(function()
			drawHealth(humanoid)
		end)
	end
end
player.CharacterAdded:Connect(watchCharacter)
if player.Character then
	task.spawn(watchCharacter, player.Character)
end

local function drawStamina()
	local value, max = player:GetAttribute("Stamina"), player:GetAttribute("StaminaMax")
	local has = typeof(value) == "number" and typeof(max) == "number" and max > 0
	staminaTrack.Visible = has
	vitals.Size = UDim2.fromOffset(VITAL_W, if has then 46 else 40)
	if has then
		setFill(staminaFill, (value :: number) / (max :: number))
	end
end
player:GetAttributeChangedSignal("Stamina"):Connect(drawStamina)
player:GetAttributeChangedSignal("StaminaMax"):Connect(drawStamina)
drawStamina()

-- ---------------------------------------------------------------- teams and castles
local function castleTeams(): { Team }
	local found: { Team } = {}
	for _, team in Teams:GetTeams() do
		if team:GetAttribute("Castle") ~= nil then
			table.insert(found, team)
		end
	end
	table.sort(found, function(a, b)
		return tostring(a:GetAttribute("TeamId")) < tostring(b:GetAttribute("TeamId"))
	end)
	return found
end

local function teamOfCastle(castle: Instance): Team?
	for _, team in castleTeams() do
		if team:GetAttribute("Castle") == castle.Name then
			return team
		end
	end
	return nil
end

local function castleOf(team: Team): Instance?
	local castles = Workspace:FindFirstChild("Castles")
	local id = team:GetAttribute("Castle")
	return if castles and typeof(id) == "string" then castles:FindFirstChild(id) else nil
end

-- ---------------------------------------------------------------- the map
-- One drawing routine for the minimap and the full map. North (-Z) is up and the whole
-- island is shown, so the two maps agree and your castle is always where you left it.
type MapView = { frame: Frame, layer: Frame, dots: Frame, me: Frame, big: boolean, mates: { [Player]: Frame } }

local bounds: { x0: number, x1: number, z0: number, z1: number }? = nil

local function findBounds()
	local folder = Workspace:FindFirstChild("Boundary")
	if not folder then
		return nil
	end
	local x0, x1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
	for _, p in folder:GetChildren() do
		if p:IsA("BasePart") then
			x0, x1 = math.min(x0, p.Position.X), math.max(x1, p.Position.X)
			z0, z1 = math.min(z0, p.Position.Z), math.max(z1, p.Position.Z)
		end
	end
	if x0 >= x1 or z0 >= z1 then
		return nil
	end
	-- a little sea round the walls
	local mx, mz = (x1 - x0) * 0.04, (z1 - z0) * 0.04
	return { x0 = x0 - mx, x1 = x1 + mx, z0 = z0 - mz, z1 = z1 + mz }
end

local function toMap(position: Vector3): (number, number)
	local b = bounds :: any
	return (position.X - b.x0) / (b.x1 - b.x0), (position.Z - b.z0) / (b.z1 - b.z0)
end

local function mapShape(parent: Instance, name: string, u: number, v: number, w: number, h: number,
	colour: Color3, alpha: number, radius: number?): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale(u, v)
	f.Size = UDim2.fromScale(w, h)
	f.BackgroundColor3 = colour
	f.BackgroundTransparency = alpha
	f.BorderSizePixel = 0
	if radius then
		corner(f, radius)
	end
	f.Parent = parent
	return f
end

local function dot(parent: Instance, name: string, px: number, colour: Color3): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Size = UDim2.fromOffset(px, px)
	f.BackgroundColor3 = colour
	f.BorderSizePixel = 0
	corner(f, math.ceil(px / 2))
	f.Parent = parent
	return f
end

local function newMapView(parent: Instance, name: string, big: boolean): MapView
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundColor3 = HUD.SEA
	frame.BackgroundTransparency = 0.1
	frame.BorderSizePixel = 0
	frame.ClipsDescendants = true
	corner(frame, HUD.CORNER)
	frame.Parent = parent
	local layer = Instance.new("Frame")
	layer.Name = "Static"
	layer.Size = UDim2.fromScale(1, 1)
	layer.BackgroundTransparency = 1
	layer.Parent = frame
	local dots = Instance.new("Frame")
	dots.Name = "Players"
	dots.Size = UDim2.fromScale(1, 1)
	dots.BackgroundTransparency = 1
	dots.ZIndex = 3
	dots.Parent = frame
	-- you: a light ring with a heading tick, so it never reads as a (white) Wool node
	local me = dot(dots, "You", if big then 13 else 10, HUD.TEXT)
	me.BackgroundTransparency = 1
	me.ZIndex = 5
	local ring = Instance.new("UIStroke")
	ring.Color = HUD.TEXT
	ring.Thickness = 2
	ring.Parent = me
	local tick = Instance.new("Frame")
	tick.Name = "Heading"
	tick.AnchorPoint = Vector2.new(0.5, 1)
	tick.Position = UDim2.fromScale(0.5, 0.5)
	tick.Size = UDim2.new(0, 2, 0, if big then 16 else 11)
	tick.BackgroundColor3 = HUD.TEXT
	tick.BorderSizePixel = 0
	tick.ZIndex = 5
	tick.Parent = me
	return { frame = frame, layer = layer, dots = dots, me = me, big = big, mates = {} }
end

local function drawStatic(view: MapView)
	view.layer:ClearAllChildren()
	if not bounds then
		return
	end
	local b = bounds :: any
	local wall = Workspace:FindFirstChild("Boundary")
	if wall then -- the island: the boundary's rounded rectangle, sea outside
		local inner = { x0 = math.huge, x1 = -math.huge, z0 = math.huge, z1 = -math.huge }
		for _, p in wall:GetChildren() do
			if p:IsA("BasePart") then
				inner.x0, inner.x1 = math.min(inner.x0, p.Position.X), math.max(inner.x1, p.Position.X)
				inner.z0, inner.z1 = math.min(inner.z0, p.Position.Z), math.max(inner.z1, p.Position.Z)
			end
		end
		local u0, v0 = toMap(Vector3.new(inner.x0, 0, inner.z0))
		local u1, v1 = toMap(Vector3.new(inner.x1, 0, inner.z1))
		mapShape(view.layer, "Land", (u0 + u1) / 2, (v0 + v1) / 2, u1 - u0, v1 - v0, HUD.LAND, 0,
			if view.big then 28 else 12)
	end
	local castles = Workspace:FindFirstChild("Castles")
	local gates: { Vector3 } = {}
	if castles then
		for _, castle in castles:GetChildren() do
			if castle:IsA("Model") then
				local team = teamOfCastle(castle)
				local colour = if team then team.TeamColor.Color else HUD.TEXT_DIM
				local cf, size = castle:GetBoundingBox()
				local u, v = toMap(cf.Position)
				local w, h = size.X / (b.x1 - b.x0), size.Z / (b.z1 - b.z0)
				local square = mapShape(view.layer, castle.Name, u, v, w, h, colour, 0.55, 2)
				local stroke = Instance.new("UIStroke")
				stroke.Color = colour
				stroke.Thickness = if view.big then 2 else 1
				stroke.Parent = square
				for _, child in castle:GetChildren() do
					if child:GetAttribute("Kind") == "Gatehouse" and child:IsA("Model") then
						table.insert(gates, child:GetPivot().Position)
					elseif child:GetAttribute("Kind") == "Keep" and child:IsA("Model") then
						local ku, kv = toMap(child:GetPivot().Position)
						local keep = mapShape(view.layer, "Keep", ku, kv, 0, 0, colour, 0)
						keep.Size = UDim2.fromOffset(if view.big then 12 else 7, if view.big then 12 else 7)
						keep.Rotation = 45
						keep.ZIndex = 2
					end
				end
				if view.big and team then
					local label = text(view.layer, "Name", UDim2.fromOffset(120, 20), UDim2.fromScale(u, v - h / 2),
						Palette.FONT_HEADING, 16, HUD.TEXT, Enum.TextXAlignment.Center)
					label.AnchorPoint = Vector2.new(0.5, 1)
					label.Text = team.Name
					label.ZIndex = 2
				end
			end
		end
	end
	if #gates == 2 then -- the road between the two gates
		local u0, v0 = toMap(gates[1])
		local u1, v1 = toMap(gates[2])
		local road = mapShape(view.layer, "Road", (u0 + u1) / 2, (v0 + v1) / 2, math.abs(u1 - u0), 0,
			Color3.fromRGB(150, 128, 98), 0.25)
		road.Size = UDim2.new(math.abs(u1 - u0), 0, 0, if view.big then 5 else 3)
	end
	local nodes = Workspace:FindFirstChild("ResourceNodes")
	if nodes then
		for _, node in nodes:GetChildren() do
			if node:IsA("Model") then
				local resource = node:GetAttribute("Resource")
				local colour = if typeof(resource) == "string" then Palette.GOODS[resource] else nil
				local u, v = toMap(node:GetPivot().Position)
				local d = dot(view.layer, node.Name, if view.big then 9 else 5, colour or HUD.TEXT_DIM)
				d.Position = UDim2.fromScale(u, v)
				d.ZIndex = 2
			end
		end
	end
end

local function drawPlayers(view: MapView)
	if not bounds then
		view.me.Visible = false
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	view.me.Visible = root ~= nil
	if root and root:IsA("BasePart") then
		local u, v = toMap(root.Position)
		view.me.Position = UDim2.fromScale(u, v)
		local look = root.CFrame.LookVector
		view.me.Rotation = math.deg(math.atan2(look.X, -look.Z))
	end
	-- teammates only: the map does not give away the enemy
	local seen: { [Player]: boolean } = {}
	for _, other in Players:GetPlayers() do
		if other ~= player and other.Team ~= nil and other.Team == player.Team then
			local r = other.Character and other.Character:FindFirstChild("HumanoidRootPart")
			if r and r:IsA("BasePart") then
				seen[other] = true
				local d = view.mates[other]
				if not d then
					d = dot(view.dots, other.Name, if view.big then 9 else 6, other.Team.TeamColor.Color)
					view.mates[other] = d
				end
				local u, v = toMap(r.Position)
				d.Position = UDim2.fromScale(u, v)
			end
		end
	end
	for other, d in view.mates do
		if not seen[other] then
			d:Destroy()
			view.mates[other] = nil
		end
	end
end

-- ---------------------------------------------------------------- top-right: map and match
local MAP_W = 230
local topRight = Instance.new("Frame")
topRight.Name = "TopRight"
topRight.AnchorPoint = Vector2.new(1, 0)
topRight.Position = UDim2.new(1, -GAP, 0, GAP)
topRight.Size = UDim2.fromOffset(MAP_W, 0)
topRight.AutomaticSize = Enum.AutomaticSize.Y
topRight.BackgroundTransparency = 1
topRight.Parent = gui
local stack = Instance.new("UIListLayout")
stack.Padding = UDim.new(0, 6)
stack.SortOrder = Enum.SortOrder.LayoutOrder
stack.Parent = topRight

local mini = newMapView(topRight, "Minimap", false)
mini.frame.LayoutOrder = 1
mini.frame.Size = UDim2.fromOffset(MAP_W, 150)
local miniStroke = Instance.new("UIStroke")
miniStroke.Color = HUD.EDGE
miniStroke.Transparency = HUD.EDGE_ALPHA
miniStroke.Parent = mini.frame
local miniButton = Instance.new("TextButton") -- tap or click: the full map
miniButton.Name = "Open"
miniButton.Size = UDim2.fromScale(1, 1)
miniButton.BackgroundTransparency = 1
miniButton.Text = ""
miniButton.ZIndex = 10
miniButton.Parent = mini.frame
local mHint = text(mini.frame, "Hint", UDim2.fromOffset(30, 16), UDim2.new(1, -4, 1, -2), Palette.FONT_STRONG, 11,
	HUD.TEXT_DIM, Enum.TextXAlignment.Right)
mHint.AnchorPoint = Vector2.new(1, 1)
mHint.Text = if TOUCH then "" else "M"
mHint.ZIndex = 6

local matchPanel = panel(topRight, "Match", UDim2.fromOffset(MAP_W, 72), UDim2.new(), Vector2.zero)
matchPanel.LayoutOrder = 2
local phaseText = text(matchPanel, "Phase", UDim2.fromOffset(120, 18), UDim2.fromOffset(10, 6),
	Palette.FONT_HEADING, 13, HUD.TEXT_DIM)
local clockText = text(matchPanel, "Clock", UDim2.fromOffset(90, 22), UDim2.fromOffset(MAP_W - 100, 4),
	Palette.FONT_STRONG, 20, HUD.TEXT, Enum.TextXAlignment.Right)
type CastleRow = { name: TextLabel, fill: Frame, value: TextLabel }
local castleRows: { CastleRow } = {}
for i = 1, 2 do
	local y = 30 + (i - 1) * 19
	local name = text(matchPanel, "Team" .. i, UDim2.fromOffset(44, 16), UDim2.fromOffset(10, y),
		Palette.FONT_LABEL, 12, HUD.TEXT)
	local fill = bar(matchPanel, "Castle" .. i, UDim2.fromOffset(MAP_W - 116, 6), UDim2.fromOffset(56, y + 5), HUD.TEXT_DIM)
	local value = text(matchPanel, "Value" .. i, UDim2.fromOffset(50, 16), UDim2.fromOffset(MAP_W - 60, y),
		Palette.FONT_BODY, 11, HUD.TEXT_DIM, Enum.TextXAlignment.Right)
	castleRows[i] = { name = name, fill = fill, value = value }
end

local function drawMatch()
	local state = Workspace:GetAttribute("MatchState")
	phaseText.Text = if state == "Running" then "The siege"
		elseif state == "Lobby" then "Next siege in"
		elseif state == "Ended" then "Siege over"
		else "Waiting"
	local remaining = Workspace:GetAttribute("MatchClock")
	clockText.Text = if typeof(remaining) == "number" then clockFace(remaining) else "--:--"
	local warn = state == "Running" and typeof(remaining) == "number" and remaining <= 60
	clockText.TextColor3 = if warn then HUD.ACCENT else HUD.TEXT
end
Workspace:GetAttributeChangedSignal("MatchState"):Connect(drawMatch)
Workspace:GetAttributeChangedSignal("MatchClock"):Connect(drawMatch)
drawMatch()

local function drawCastles()
	local teams = castleTeams()
	for i, row in castleRows do
		local team = teams[i]
		local castle = team and castleOf(team)
		row.name.Text = if team then team.Name else ""
		row.fill.Parent.Visible = team ~= nil
		if team then
			row.name.TextColor3 = team.TeamColor.Color:Lerp(HUD.TEXT, 0.35)
			row.fill.BackgroundColor3 = team.TeamColor.Color
			local hp = castle and castle:GetAttribute("StructureHP")
			local max = castle and castle:GetAttribute("StructureMax")
			if typeof(hp) == "number" and typeof(max) == "number" and max > 0 then
				setFill(row.fill, hp / max)
				row.value.Text = if castle and castle:GetAttribute("Fallen") == true then "fallen"
					else ("%d%%"):format(math.floor(hp / max * 100 + 0.5))
			else
				setFill(row.fill, 1)
				row.value.Text = ""
			end
		else
			row.value.Text = ""
		end
	end
end

-- ---------------------------------------------------------------- full map (M)
local fullMap = Instance.new("Frame")
fullMap.Name = "FullMap"
fullMap.AnchorPoint = Vector2.new(0.5, 0.5)
fullMap.Position = UDim2.fromScale(0.5, 0.5)
fullMap.Size = UDim2.fromScale(0.82, 0.78)
fullMap.BackgroundColor3 = HUD.PANEL
fullMap.BackgroundTransparency = 0.06
fullMap.BorderSizePixel = 0
fullMap.Visible = false
fullMap.ZIndex = 20
corner(fullMap, HUD.CORNER)
fullMap.Parent = gui
do
	local stroke = Instance.new("UIStroke")
	stroke.Color = HUD.EDGE
	stroke.Transparency = HUD.EDGE_ALPHA
	stroke.Parent = fullMap
end
local fullTitle = text(fullMap, "Title", UDim2.new(1, -24, 0, 30), UDim2.fromOffset(14, 6),
	Palette.FONT_HEADING, 20, HUD.TEXT)
fullTitle.Text = "The island"
local closeHint = text(fullMap, "Close", UDim2.fromOffset(160, 30), UDim2.new(1, -14, 0, 6),
	Palette.FONT_LABEL, 13, HUD.TEXT_DIM, Enum.TextXAlignment.Right)
closeHint.AnchorPoint = Vector2.new(1, 0)
closeHint.Text = if TOUCH then "Tap to close" else "M to close"
local fullHolder = Instance.new("Frame")
fullHolder.Name = "Holder"
fullHolder.BackgroundTransparency = 1
fullHolder.Position = UDim2.fromOffset(14, 42)
fullHolder.Size = UDim2.new(1, -28, 1, -84)
fullHolder.Parent = fullMap
local full = newMapView(fullHolder, "Map", true)
full.frame.AnchorPoint = Vector2.new(0.5, 0.5)
full.frame.Position = UDim2.fromScale(0.5, 0.5)
full.frame.Size = UDim2.fromScale(1, 1)
local aspect = Instance.new("UIAspectRatioConstraint")
aspect.Parent = full.frame
-- legend: the goods on the map, plus you and your side
local legend = Instance.new("Frame")
legend.Name = "Legend"
legend.BackgroundTransparency = 1
legend.Position = UDim2.new(0, 14, 1, -36)
legend.Size = UDim2.new(1, -28, 0, 28)
legend.Parent = fullMap
local legendRow = Instance.new("UIListLayout")
legendRow.FillDirection = Enum.FillDirection.Horizontal
legendRow.VerticalAlignment = Enum.VerticalAlignment.Center
legendRow.Padding = UDim.new(0, 14)
legendRow.SortOrder = Enum.SortOrder.LayoutOrder
legendRow.Parent = legend
local legendOrder = 0
local function legendItem(name: string, colour: Color3, isRing: boolean?)
	legendOrder += 1
	local item = Instance.new("Frame")
	item.Name = name
	item.LayoutOrder = legendOrder
	item.BackgroundTransparency = 1
	item.Size = UDim2.fromOffset(0, 20)
	item.AutomaticSize = Enum.AutomaticSize.X
	item.Parent = legend
	local d = dot(item, "Dot", 9, colour)
	d.Position = UDim2.fromOffset(5, 10)
	if isRing then
		d.BackgroundTransparency = 1
		local ring = Instance.new("UIStroke")
		ring.Color = colour
		ring.Thickness = 2
		ring.Parent = d
	end
	local t = text(item, "Name", UDim2.fromOffset(0, 20), UDim2.fromOffset(14, 0), Palette.FONT_BODY, 12, HUD.TEXT_DIM)
	t.AutomaticSize = Enum.AutomaticSize.X
	t.Text = name
end
legendItem("You", HUD.TEXT, true)
for _, good in Palette.RAW_ORDER do
	legendItem(good, Palette.GOODS[good])
end

local function setFullMap(open: boolean)
	fullMap.Visible = open
	topRight.Visible = not open
	local goods = gui:FindFirstChild("Goods") -- built further down
	if goods and goods:IsA("GuiObject") then
		goods.Visible = not open
	end
	if open then
		drawStatic(full)
		drawPlayers(full)
	end
end
miniButton.Activated:Connect(function()
	setFullMap(not fullMap.Visible)
end)
local fullCloser = Instance.new("TextButton")
fullCloser.Name = "Closer"
fullCloser.Size = UDim2.fromScale(1, 1)
fullCloser.BackgroundTransparency = 1
fullCloser.Text = ""
fullCloser.ZIndex = 30
fullCloser.Visible = TOUCH -- on touch the whole sheet closes it; with a mouse, M does
fullCloser.Parent = fullMap
fullCloser.Activated:Connect(function()
	setFullMap(false)
end)
UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.M then
		setFullMap(not fullMap.Visible)
	end
end)

local function redrawMaps()
	bounds = findBounds()
	if bounds then
		local b = bounds :: any
		aspect.AspectRatio = (b.x1 - b.x0) / (b.z1 - b.z0)
		mini.frame.Size = UDim2.fromOffset(MAP_W, math.clamp(math.floor(MAP_W / aspect.AspectRatio), 90, 210))
	end
	drawStatic(mini)
	if fullMap.Visible then
		drawStatic(full)
	end
end

-- ---------------------------------------------------------------- bottom-left: goods
-- Rows are goods; columns are what you carry (once a cargo system exists) and the team
-- stockpile, so the two are never confused.
local goodsPanel = panel(gui, "Goods", UDim2.fromOffset(176, 0),
	if TOUCH then UDim2.new(0, GAP, 0.56, 0) else UDim2.new(0, GAP, 1, -GAP), Vector2.new(0, 1))
goodsPanel.AutomaticSize = Enum.AutomaticSize.Y
do
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = goodsPanel
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 1)
	list.Parent = goodsPanel
end
local goodsHeader = Instance.new("Frame")
goodsHeader.Name = "Header"
goodsHeader.BackgroundTransparency = 1
goodsHeader.Size = UDim2.new(1, 0, 0, 20)
goodsHeader.LayoutOrder = 0
goodsHeader.Parent = goodsPanel
local goodsTitle = text(goodsHeader, "Title", UDim2.new(1, 0, 1, 0), UDim2.new(), Palette.FONT_HEADING, 13, HUD.TEXT_DIM)
goodsTitle.Text = "Stockpile"
local carriedHead = text(goodsHeader, "Carried", UDim2.fromOffset(46, 20), UDim2.new(1, -46, 0, 0),
	Palette.FONT_BODY, 10, HUD.TEXT_DIM, Enum.TextXAlignment.Right)
carriedHead.AnchorPoint = Vector2.new(1, 0)
carriedHead.Text = "carried"
carriedHead.Visible = false
local teamHead = text(goodsHeader, "Team", UDim2.fromOffset(40, 20), UDim2.new(1, 0, 0, 0),
	Palette.FONT_BODY, 10, HUD.TEXT_DIM, Enum.TextXAlignment.Right)
teamHead.AnchorPoint = Vector2.new(1, 0)
teamHead.Text = "team"
teamHead.Visible = false

type GoodRow = { row: Frame, name: TextLabel, carried: TextLabel, team: TextLabel }
local goodRows: { [string]: GoodRow } = {}
local order = 0
local function goodRow(good: string, gapAbove: boolean)
	order += 1
	local row = Instance.new("Frame")
	row.Name = good
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, if gapAbove then 24 else 18)
	row.LayoutOrder = order
	row.Parent = goodsPanel
	local y = if gapAbove then 6 else 0
	local d = dot(row, "Dot", 7, Palette.GOODS[good] or HUD.TEXT)
	d.Position = UDim2.fromOffset(4, y + 9)
	local name = text(row, "Name", UDim2.fromOffset(80, 18), UDim2.fromOffset(14, y), Palette.FONT_BODY, 13, HUD.TEXT)
	name.Text = good
	local carried = text(row, "Carried", UDim2.fromOffset(46, 18), UDim2.new(1, -46, 0, y),
		Palette.FONT_STRONG, 13, HUD.TEXT, Enum.TextXAlignment.Right)
	carried.AnchorPoint = Vector2.new(1, 0)
	carried.Visible = false
	local team = text(row, "Team", UDim2.fromOffset(40, 18), UDim2.new(1, 0, 0, y),
		Palette.FONT_STRONG, 13, HUD.TEXT, Enum.TextXAlignment.Right)
	team.AnchorPoint = Vector2.new(1, 0)
	goodRows[good] = { row = row, name = name, carried = carried, team = team }
end
for _, good in Palette.RAW_ORDER do
	goodRow(good, false)
end
for i, good in Palette.CRAFTED_ORDER do
	goodRow(good, i == 1) -- a gap between what is gathered and what can only be made
end

local function countIn(folder: Instance?, good: string): number
	local v = folder and folder:FindFirstChild(good)
	return if v and v:IsA("IntValue") then v.Value else 0
end

local function drawGoods()
	local stock = player.Team and player.Team:FindFirstChild("Goods")
	local cargo = player:FindFirstChild("Cargo")
	local split = cargo ~= nil
	carriedHead.Visible = split
	teamHead.Visible = split
	goodsTitle.Text = if split then "Goods" else "Stockpile"
	for good, r in goodRows do
		local t, c = countIn(stock, good), countIn(cargo, good)
		r.team.Text = tostring(t)
		r.carried.Text = tostring(c)
		r.carried.Visible = split
		local empty = t == 0 and c == 0
		r.name.TextColor3 = if empty then HUD.TEXT_DIM else HUD.TEXT
		r.team.TextColor3 = if t == 0 then HUD.TEXT_DIM else HUD.TEXT
		r.carried.TextColor3 = if c == 0 then HUD.TEXT_DIM else HUD.ACCENT
	end
end

local goodsHooks: { RBXScriptConnection } = {}
local function hookGoods()
	for _, c in goodsHooks do
		c:Disconnect()
	end
	table.clear(goodsHooks)
	for _, folder in { player.Team and player.Team:FindFirstChild("Goods"), player:FindFirstChild("Cargo") } do
		if folder then
			for _, v in folder:GetChildren() do
				if v:IsA("IntValue") then
					table.insert(goodsHooks, v.Changed:Connect(drawGoods))
				end
			end
			table.insert(goodsHooks, folder.ChildAdded:Connect(hookGoods))
		end
	end
	drawGoods()
end
player:GetPropertyChangedSignal("Team"):Connect(hookGoods)
player.ChildAdded:Connect(function(child)
	if child.Name == "Cargo" then
		hookGoods()
	end
end)
player.ChildRemoved:Connect(function(child)
	if child.Name == "Cargo" then
		hookGoods()
	end
end)
hookGoods()

-- ---------------------------------------------------------------- bottom-centre: the prompt
-- Every ProximityPrompt is drawn here instead of over the world. Keyboard and gamepad
-- keep working through the engine; touch presses the panel itself.
local promptPanel = panel(gui, "Prompt", UDim2.fromOffset(0, 44),
	UDim2.new(0.5, 0, 1, if TOUCH then -120 else -GAP - 10), Vector2.new(0.5, 1))
promptPanel.AutomaticSize = Enum.AutomaticSize.X
promptPanel.Visible = false
local promptRow = Instance.new("Frame") -- the laid-out content; the hold bar and touch button sit outside it
promptRow.Name = "Row"
promptRow.BackgroundTransparency = 1
promptRow.Size = UDim2.fromOffset(0, 44)
promptRow.AutomaticSize = Enum.AutomaticSize.X
promptRow.Parent = promptPanel
do
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 14)
	pad.Parent = promptRow
	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.VerticalAlignment = Enum.VerticalAlignment.Center
	row.Padding = UDim.new(0, 10)
	row.SortOrder = Enum.SortOrder.LayoutOrder
	row.Parent = promptRow
end
local keyChip = Instance.new("TextLabel")
keyChip.Name = "Key"
keyChip.Size = UDim2.fromOffset(30, 30)
keyChip.AutomaticSize = Enum.AutomaticSize.X
keyChip.BackgroundColor3 = HUD.ACCENT
keyChip.BackgroundTransparency = 0.1
keyChip.Font = Palette.FONT_STRONG
keyChip.TextSize = 15
keyChip.TextColor3 = HUD.PANEL
keyChip.LayoutOrder = 1
corner(keyChip, 3)
do
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = keyChip
end
keyChip.Parent = promptRow
local promptWords = Instance.new("Frame")
promptWords.Name = "Words"
promptWords.BackgroundTransparency = 1
promptWords.Size = UDim2.fromOffset(0, 36)
promptWords.AutomaticSize = Enum.AutomaticSize.X
promptWords.LayoutOrder = 2
promptWords.Parent = promptRow
local actionText = text(promptWords, "Action", UDim2.fromOffset(0, 20), UDim2.fromOffset(0, 1), Palette.FONT_LABEL, 15, HUD.TEXT)
actionText.AutomaticSize = Enum.AutomaticSize.X
local objectText = text(promptWords, "Object", UDim2.fromOffset(0, 14), UDim2.fromOffset(0, 21), Palette.FONT_BODY, 12, HUD.TEXT_DIM)
objectText.AutomaticSize = Enum.AutomaticSize.X
local holdFill = bar(promptPanel, "Hold", UDim2.new(1, -4, 0, 3), UDim2.new(0, 2, 1, -4), HUD.ACCENT)
local holdTrack = holdFill.Parent :: Frame -- along the bottom edge
holdTrack.BackgroundTransparency = 1
setFill(holdFill, 0)

local promptButton = Instance.new("TextButton") -- touch: the panel is the button
promptButton.Name = "Press"
promptButton.Size = UDim2.fromScale(1, 1)
promptButton.BackgroundTransparency = 1
promptButton.Text = ""
promptButton.ZIndex = 5
promptButton.Visible = TOUCH

local shown: { ProximityPrompt } = {}
local current: ProximityPrompt? = nil
local currentInput: Enum.ProximityPromptInputType = Enum.ProximityPromptInputType.Keyboard
local holdTween: Tween? = nil
local changeHook: RBXScriptConnection? = nil

local function keyName(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType): string
	if inputType == Enum.ProximityPromptInputType.Touch then
		return "Tap"
	elseif inputType == Enum.ProximityPromptInputType.Gamepad then
		return (prompt.GamepadKeyCode.Name:gsub("^Button", ""))
	end
	return prompt.KeyboardKeyCode.Name
end

local function drawPrompt()
	current = shown[#shown]
	if changeHook then
		changeHook:Disconnect()
		changeHook = nil
	end
	local prompt = current
	if not prompt then
		promptPanel.Visible = false
		return
	end
	local hold = prompt.HoldDuration > 0
	-- the server's own words; a hold is said on the key chip ("Hold E")
	keyChip.Text = (if hold then "Hold " else "") .. keyName(prompt, currentInput)
	actionText.Text = if prompt.ActionText ~= "" then prompt.ActionText else "Use"
	objectText.Text = prompt.ObjectText
	objectText.Visible = prompt.ObjectText ~= ""
	promptWords.Size = UDim2.fromOffset(0, if objectText.Visible then 36 else 22)
	holdTrack.Visible = hold
	setFill(holdFill, 0)
	promptPanel.Visible = true
	changeHook = prompt.Changed:Connect(function(property)
		if property == "ActionText" or property == "ObjectText" or property == "HoldDuration" then
			drawPrompt()
		end
	end)
end

local function adopt(prompt: Instance)
	if prompt:IsA("ProximityPrompt") and prompt.Style ~= Enum.ProximityPromptStyle.Custom then
		prompt.Style = Enum.ProximityPromptStyle.Custom
	end
end
for _, d in Workspace:GetDescendants() do
	adopt(d)
end
Workspace.DescendantAdded:Connect(adopt)

ProximityPromptService.PromptShown:Connect(function(prompt, inputType)
	currentInput = inputType
	local i = table.find(shown, prompt)
	if i then
		table.remove(shown, i)
	end
	table.insert(shown, prompt)
	drawPrompt()
end)
ProximityPromptService.PromptHidden:Connect(function(prompt)
	local i = table.find(shown, prompt)
	if i then
		table.remove(shown, i)
	end
	drawPrompt()
end)
ProximityPromptService.PromptButtonHoldBegan:Connect(function(prompt)
	if prompt == current then
		if holdTween then
			holdTween:Cancel()
		end
		setFill(holdFill, 0)
		holdTween = TweenService:Create(holdFill, TweenInfo.new(prompt.HoldDuration, Enum.EasingStyle.Linear),
			{ Size = UDim2.fromScale(1, 1) })
		;(holdTween :: Tween):Play()
	end
end)
ProximityPromptService.PromptButtonHoldEnded:Connect(function(prompt)
	if prompt == current then
		if holdTween then
			holdTween:Cancel()
		end
		setFill(holdFill, 0)
	end
end)
ProximityPromptService.PromptTriggered:Connect(function(prompt)
	if prompt == current then
		keyChip.BackgroundTransparency = 0.6
		TweenService:Create(keyChip, FADE, { BackgroundTransparency = 0.1 }):Play()
	end
end)
promptButton.InputBegan:Connect(function(input)
	local prompt = current
	if prompt and (input.UserInputType == Enum.UserInputType.Touch
		or input.UserInputType == Enum.UserInputType.MouseButton1) then
		prompt:InputHoldBegin()
	end
end)
promptButton.InputEnded:Connect(function(input)
	local prompt = current
	if prompt and (input.UserInputType == Enum.UserInputType.Touch
		or input.UserInputType == Enum.UserInputType.MouseButton1) then
		prompt:InputHoldEnd()
	end
end)
promptButton.Parent = promptPanel

-- ---------------------------------------------------------------- bottom-right: events
local FEED_W = 300
local FEED_LINES = 5
local FEED_SECONDS = 9
local feed = Instance.new("Frame")
feed.Name = "Feed"
feed.AnchorPoint = Vector2.new(1, 1)
feed.Position = if TOUCH then UDim2.new(1, -GAP, 0.58, 0) else UDim2.new(1, -GAP, 1, -GAP)
feed.Size = UDim2.fromOffset(FEED_W, 0)
feed.AutomaticSize = Enum.AutomaticSize.Y
feed.BackgroundTransparency = 1
feed.Parent = gui
do
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.VerticalAlignment = Enum.VerticalAlignment.Bottom
	list.HorizontalAlignment = Enum.HorizontalAlignment.Right
	list.Padding = UDim.new(0, 4)
	list.Parent = feed
end
local feedOrder = 0

local function post(message: string, colour: Color3?)
	feedOrder += 1
	local line = panel(feed, "Event", UDim2.fromOffset(0, 26), UDim2.new(), Vector2.zero)
	line.AutomaticSize = Enum.AutomaticSize.X
	line.LayoutOrder = feedOrder
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = line
	if colour then -- a team or alarm colour as a thin leading mark
		local mark = Instance.new("Frame")
		mark.Name = "Mark"
		mark.Size = UDim2.new(0, 3, 1, -10)
		mark.Position = UDim2.new(0, -6, 0, 5)
		mark.BackgroundColor3 = colour
		mark.BorderSizePixel = 0
		mark.Parent = line
	end
	local t = text(line, "Text", UDim2.fromOffset(0, 26), UDim2.new(), Palette.FONT_LABEL, 13, HUD.TEXT)
	t.AutomaticSize = Enum.AutomaticSize.X
	t.Text = message
	local lines = {}
	for _, child in feed:GetChildren() do
		if child:IsA("Frame") then
			table.insert(lines, child)
		end
	end
	table.sort(lines, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	for i = 1, #lines - FEED_LINES do
		lines[i]:Destroy()
	end
	task.delay(FEED_SECONDS, function()
		if line.Parent then
			TweenService:Create(line, FADE, { BackgroundTransparency = 1 }):Play()
			TweenService:Create(t, FADE, { TextTransparency = 1 }):Play()
			local stroke = line:FindFirstChildOfClass("UIStroke")
			if stroke then
				TweenService:Create(stroke, FADE, { Transparency = 1 }):Play()
			end
			task.wait(FADE.Time)
			line:Destroy()
		end
	end)
end

local function sideNames(): string
	local names = {}
	for _, team in castleTeams() do
		table.insert(names, team.Name)
	end
	return table.concat(names, " against ")
end

-- match: start, result, time warnings
local lastState = Workspace:GetAttribute("MatchState")
Workspace:GetAttributeChangedSignal("MatchState"):Connect(function()
	local state = Workspace:GetAttribute("MatchState")
	if state == lastState then
		return
	end
	if state == "Running" then
		post(("The siege begins: %s"):format(sideNames()), HUD.ACCENT)
	elseif state == "Ended" then
		local result = Workspace:GetAttribute("MatchResult")
		post(if typeof(result) == "string" and result ~= "" then result else "The siege is over", HUD.ACCENT)
	end
	lastState = state
end)
local lastClock: number? = nil
Workspace:GetAttributeChangedSignal("MatchClock"):Connect(function()
	local clock = Workspace:GetAttribute("MatchClock")
	if typeof(clock) ~= "number" or Workspace:GetAttribute("MatchState") ~= "Running" then
		lastClock = nil
		return
	end
	if lastClock then
		for _, mark in { { 300, "Five minutes left" }, { 60, "One minute left" } } do
			if lastClock > mark[1] and clock <= mark[1] then
				post(mark[2] :: string, HUD.ACCENT)
			end
		end
	end
	lastClock = clock
end)

-- siege: a castle or its Keep losing health, a castle falling
local ATTACK_QUIET = 30 -- seconds between "under attack" lines for the same thing
local castleHooks: { RBXScriptConnection } = {}
local function hookCastles()
	for _, c in castleHooks do
		c:Disconnect()
	end
	table.clear(castleHooks)
	local castles = Workspace:FindFirstChild("Castles")
	if not castles then
		return
	end
	for _, castle in castles:GetChildren() do
		local lastHP = castle:GetAttribute("StructureHP")
		local quietUntil = 0
		table.insert(castleHooks, castle:GetAttributeChangedSignal("StructureHP"):Connect(function()
			local hp = castle:GetAttribute("StructureHP")
			if typeof(hp) == "number" and typeof(lastHP) == "number" and hp < lastHP
				and Workspace:GetAttribute("MatchState") == "Running" and os.clock() >= quietUntil then
				quietUntil = os.clock() + ATTACK_QUIET
				local team = teamOfCastle(castle)
				if team then
					post(("%s castle under attack"):format(team.Name), team.TeamColor.Color)
				end
			end
			lastHP = hp
		end))
		table.insert(castleHooks, castle:GetAttributeChangedSignal("Fallen"):Connect(function()
			local team = teamOfCastle(castle)
			if castle:GetAttribute("Fallen") == true and team then
				post(("%s castle has fallen"):format(team.Name), HUD.DANGER)
			end
		end))
		for _, keep in castle:GetDescendants() do
			if keep:GetAttribute("Kind") == "Keep" then
				local lastKeep = keep:GetAttribute("Health")
				local keepQuiet = 0
				table.insert(castleHooks, keep:GetAttributeChangedSignal("Health"):Connect(function()
					local h = keep:GetAttribute("Health")
					if typeof(h) == "number" and typeof(lastKeep) == "number" and h < lastKeep
						and os.clock() >= keepQuiet then
						keepQuiet = os.clock() + ATTACK_QUIET
						local team = teamOfCastle(castle)
						if team then
							post(("%s Keep under attack"):format(team.Name), HUD.DANGER)
						end
					end
					lastKeep = h
				end))
			end
		end
	end
end

-- ---------------------------------------------------------------- wiring
local function worldChanged(child: Instance)
	if child.Name == "Castles" or child.Name == "Boundary" or child.Name == "ResourceNodes" then
		task.defer(function()
			redrawMaps()
			hookCastles()
			drawCastles()
		end)
	end
end
Workspace.ChildAdded:Connect(worldChanged)
Teams.ChildAdded:Connect(function()
	task.defer(redrawMaps)
end)
redrawMaps()
hookCastles()
drawCastles()

-- the only loop: player dots move every frame they can, castle bars refresh a few times a second.
-- The Boundary folder can arrive before its walls replicate, so an empty map retries each second.
local mapClock, castleClock, retryClock = 0, 0, 0
RunService.RenderStepped:Connect(function(dt)
	mapClock += dt
	castleClock += dt
	retryClock += dt
	if not bounds and retryClock >= 1 then
		retryClock = 0
		redrawMaps()
	end
	if mapClock >= 0.1 then
		mapClock = 0
		drawPlayers(mini)
		if fullMap.Visible then
			drawPlayers(full)
		end
	end
	if castleClock >= 0.5 then
		castleClock = 0
		drawCastles()
	end
end)
