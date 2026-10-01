--!strict
-- Medieval Land - the heads-up display.
--
-- WHY THIS EXISTS. The server has always known a great deal that the player
-- could not see. The match clock was published once a second and read by
-- literally nothing. The zone extent was known only as four translucent walls on
-- the horizon and a toast that fired every single second while you stood
-- outside it. Your keep's health had no readout anywhere - not even prompt text.
-- Your specialists, your reputation, your village's build stage: all published,
-- none drawn.
--
-- NO NEW REMOTES. Attributes on Workspace, on a Player, and on models in
-- Workspace all replicate to clients for free, and every number below is already
-- published as one. So this whole file is a reader: it opens no channel, asks
-- the server for nothing, and cannot desync from what the server believes,
-- because it is displaying the server's own values rather than a copy.
--
-- The one thing it computes for itself is whether you are inside the boundary,
-- because that depends on where your character is standing this frame. It uses
-- the same radial rule the server uses in inZone().

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")

local Palette = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Palette"))
-- TwoTeam: goods are the TEAM's (a Goods folder on your Team), and the bottom-right
-- panel is your castle rather than a village. Conquest drawing stays as it was.
local TWO_TEAM = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameMode")).TwoTeam

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local POLL = 0.2 -- only the zone test needs this; everything else is event driven
local FADE = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- ---------------------------------------------------------------- helpers
local function corner(into: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = into
	return c
end

local function panel(name: string, size: UDim2, position: UDim2, anchor: Vector2): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Size = size
	frame.Position = position
	frame.AnchorPoint = anchor
	frame.BackgroundColor3 = Palette.BOARD
	frame.BackgroundTransparency = 0.18
	frame.BorderSizePixel = 0
	corner(frame, Palette.CORNER_PANEL)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Palette.TIMBER_LIGHT
	stroke.Thickness = 1.5
	stroke.Transparency = 0.25
	stroke.Parent = frame
	return frame
end

local function label(parent: Instance, name: string, size: UDim2, position: UDim2,
	font: Enum.Font, textSize: number, colour: Color3, align: Enum.TextXAlignment): TextLabel
	local text = Instance.new("TextLabel")
	text.Name = name
	text.Size = size
	text.Position = position
	text.BackgroundTransparency = 1
	text.Font = font
	text.TextSize = textSize
	text.TextColor3 = colour
	text.TextXAlignment = align
	text.Text = ""
	text.Parent = parent
	return text
end

-- A thin filled bar. Used for wall and keep, which are the two numbers a
-- besieged player most needs at a glance.
local function meter(parent: Instance, name: string, position: UDim2, width: number)
	local track = Instance.new("Frame")
	track.Name = name
	track.Size = UDim2.fromOffset(width, 6)
	track.Position = position
	track.BackgroundColor3 = Palette.SLATE
	track.BackgroundTransparency = 0.35
	track.BorderSizePixel = 0
	corner(track, 3)
	track.Parent = parent

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Palette.DAUB_DIM
	fill.BorderSizePixel = 0
	corner(fill, 3)
	fill.Parent = track
	return fill
end

-- ---------------------------------------------------------------- the screen
local gui = Instance.new("ScreenGui")
gui.Name = "Hud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 0
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

-- ---- the edge alarm ------------------------------------------------
-- Four gradient strips rather than one image, because the project has no image
-- assets and this needs none. It replaces a toast that fired once a second and
-- drowned out every other message in the game.
local alarm = Instance.new("Frame")
alarm.Name = "ZoneAlarm"
alarm.Size = UDim2.fromScale(1, 1)
alarm.BackgroundTransparency = 1
alarm.Visible = false
alarm.Parent = gui

local alarmStrips: { Frame } = {}
do
	local edges = {
		{ size = UDim2.new(1, 0, 0, 90), pos = UDim2.fromScale(0, 0), rot = 90 },
		{ size = UDim2.new(1, 0, 0, 90), pos = UDim2.new(0, 0, 1, -90), rot = 270 },
		{ size = UDim2.new(0, 120, 1, 0), pos = UDim2.fromScale(0, 0), rot = 0 },
		{ size = UDim2.new(0, 120, 1, 0), pos = UDim2.new(1, -120, 0, 0), rot = 180 },
	}
	for index, edge in edges do
		local strip = Instance.new("Frame")
		strip.Name = ("Edge%d"):format(index)
		strip.Size = edge.size
		strip.Position = edge.pos
		strip.BackgroundColor3 = Palette.ALARM
		strip.BackgroundTransparency = 1
		strip.BorderSizePixel = 0
		local gradient = Instance.new("UIGradient")
		gradient.Rotation = edge.rot
		gradient.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(1, 1),
		})
		gradient.Parent = strip
		strip.Parent = alarm
		alarmStrips[#alarmStrips + 1] = strip
	end
end

-- ---- top centre: the match ------------------------------------------
local matchBar = panel("Match", UDim2.fromOffset(300, 62), UDim2.new(0.5, 0, 0, 12), Vector2.new(0.5, 0))
matchBar.Parent = gui

local phaseText = label(matchBar, "Phase", UDim2.new(1, -20, 0, 16), UDim2.fromOffset(10, 8),
	Palette.FONT_LABEL, 13, Palette.DAUB_DIM, Enum.TextXAlignment.Center)
local clockText = label(matchBar, "Clock", UDim2.new(1, -20, 0, 26), UDim2.fromOffset(10, 24),
	Palette.FONT_STRONG, 24, Palette.DAUB, Enum.TextXAlignment.Center)
local zoneText = label(matchBar, "Zone", UDim2.new(1, -20, 0, 14), UDim2.fromOffset(10, 46),
	Palette.FONT_BODY, 12, Palette.DAUB_DIM, Enum.TextXAlignment.Center)

-- ---- bottom left: what you are carrying ------------------------------
local CHIP_W, CHIP_H, CHIP_GAP, ROW_GAP = 88, 26, 4, 4
local perRow = math.max(#Palette.RAW_ORDER, #Palette.CRAFTED_ORDER)
local goodsBar = panel("Goods",
	UDim2.fromOffset(perRow * (CHIP_W + CHIP_GAP) - CHIP_GAP + 16, CHIP_H * 2 + ROW_GAP + 16),
	UDim2.new(0, 12, 1, -12), Vector2.new(0, 1))
goodsBar.Parent = gui

local goodsText: { [string]: TextLabel } = {}
do
	-- Every good is NAMED. The first cut showed a coloured dot and a number and
	-- nothing else, and eight goods cannot be told apart by colour alone -
	-- Timber and Wood are both browns, Ingot and Stone both greys. A dot is a
	-- nice accent and a terrible label.
	--
	-- Two rows, raw above refined. That split is the one that matters, since the
	-- bottom row can only be MADE, and giving it its own line says so without
	-- needing a caption.
	local function addChip(name: string, column: number, row: number)
		local chip = Instance.new("Frame")
		chip.Name = name
		chip.Size = UDim2.fromOffset(CHIP_W, CHIP_H)
		chip.Position = UDim2.fromOffset(
			8 + column * (CHIP_W + CHIP_GAP), 8 + row * (CHIP_H + ROW_GAP))
		chip.BackgroundColor3 = Palette.TIMBER
		chip.BackgroundTransparency = 0.35
		chip.BorderSizePixel = 0
		corner(chip, Palette.CORNER_CHIP)
		chip.Parent = goodsBar

		local dot = Instance.new("Frame")
		dot.Name = "Dot"
		dot.Size = UDim2.fromOffset(8, 8)
		dot.Position = UDim2.fromOffset(7, 9)
		dot.BackgroundColor3 = Palette.GOODS[name] or Palette.DAUB
		dot.BorderSizePixel = 0
		corner(dot, 4)
		dot.Parent = chip

		local caption = label(chip, "Name", UDim2.fromOffset(46, CHIP_H), UDim2.fromOffset(20, 0),
			Palette.FONT_BODY, 11, Palette.DAUB_DIM, Enum.TextXAlignment.Left)
		caption.Text = name

		goodsText[name] = label(chip, "Value", UDim2.fromOffset(22, CHIP_H),
			UDim2.fromOffset(CHIP_W - 30, 0), Palette.FONT_STRONG, 13, Palette.DAUB,
			Enum.TextXAlignment.Right)
	end

	for index, name in Palette.RAW_ORDER do
		addChip(name, index - 1, 0)
	end
	for index, name in Palette.CRAFTED_ORDER do
		addChip(name, index - 1, 1)
	end
end

-- ---- bottom right: your village and your people ----------------------
local villageBar = panel("Village", UDim2.fromOffset(240, 126),
	UDim2.new(1, -12, 1, -12), Vector2.new(1, 1))
villageBar.Parent = gui

local villageTitle = label(villageBar, "Title", UDim2.new(1, -20, 0, 18), UDim2.fromOffset(10, 8),
	Palette.FONT_HEADING, 15, Palette.DAUB, Enum.TextXAlignment.Left)
local villageNext = label(villageBar, "Next", UDim2.new(1, -20, 0, 14), UDim2.fromOffset(10, 28),
	Palette.FONT_BODY, 12, Palette.DAUB_DIM, Enum.TextXAlignment.Left)

local wallLabel = label(villageBar, "WallLabel", UDim2.new(1, -20, 0, 12), UDim2.fromOffset(10, 48),
	Palette.FONT_BODY, 11, Palette.DAUB_DIM, Enum.TextXAlignment.Left)
local wallFill = meter(villageBar, "WallMeter", UDim2.fromOffset(10, 62), 220)

local keepLabel = label(villageBar, "KeepLabel", UDim2.new(1, -20, 0, 12), UDim2.fromOffset(10, 74),
	Palette.FONT_BODY, 11, Palette.DAUB_DIM, Enum.TextXAlignment.Left)
local keepFill = meter(villageBar, "KeepMeter", UDim2.fromOffset(10, 88), 220)

local peopleText = label(villageBar, "People", UDim2.new(1, -20, 0, 14), UDim2.fromOffset(10, 100),
	Palette.FONT_BODY, 12, Palette.DAUB_DIM, Enum.TextXAlignment.Left)

-- ---------------------------------------------------------------- reading
local function attr(name: string): any
	return Workspace:GetAttribute(name)
end

local function clockFace(seconds: number): string
	local whole = math.max(0, math.floor(seconds))
	return ("%d:%02d"):format(math.floor(whole / 60), whole % 60)
end

local function myBase(): Model?
	local sites = Workspace:FindFirstChild("BuildSites")
	if not sites then
		return nil
	end
	for _, base in sites:GetChildren() do
		if base:GetAttribute("Owner") == player.UserId then
			return base :: Model
		end
	end
	return nil
end

-- The server's rule, restated: the world is an island centred on the origin, so
-- the boundary is a circle and "outside" is plain radial distance.
local function outsideBy(position: Vector3, half: number): number
	return math.max(0, Vector3.new(position.X, 0, position.Z).Magnitude - half)
end

local alarmShown = false
local function setAlarm(on: boolean)
	if on == alarmShown then
		return
	end
	alarmShown = on
	alarm.Visible = true
	for _, strip in alarmStrips do
		TweenService:Create(strip, FADE, { BackgroundTransparency = if on then 0.45 else 1 }):Play()
	end
	if not on then
		task.delay(FADE.Time, function()
			if not alarmShown then
				alarm.Visible = false
			end
		end)
	end
end

local function drawMatch()
	local state = attr("MatchState")
	local phase = if typeof(state) == "string" then state else "Waiting"
	phaseText.Text = (
		if phase == "Lobby" then "GATHERING"
		elseif phase == "Running" then "THE MATCH"
		elseif phase == "Ended" then "OVER"
		else "WAITING"
	)

	local remaining = attr("MatchClock")
	clockText.Text = if typeof(remaining) == "number" then clockFace(remaining) else "--:--"

	local half = attr("ZoneHalf")
	local board = attr("BoardHalf")
	if TWO_TEAM then
		zoneText.Text = ""
	elseif typeof(half) == "number" and typeof(board) == "number" and board > 0 then
		local closed = math.clamp(1 - (half / board), 0, 1)
		zoneText.Text = if closed <= 0.001
			then "the whole island is open"
			else ("the sea has closed %d%%"):format(math.floor(closed * 100 + 0.5))
	else
		zoneText.Text = ""
	end
end

local function goodsSource(): Instance?
	if TWO_TEAM then
		return player.Team and player.Team:FindFirstChild("Goods")
	end
	return player:FindFirstChild("leaderstats")
end

local function myCastle(): Instance?
	local castles = Workspace:FindFirstChild("Castles")
	local id = player.Team and player.Team:GetAttribute("Castle")
	return if castles and typeof(id) == "string" then castles:FindFirstChild(id) else nil
end

local function drawCastle()
	local team = player.Team
	local castle = myCastle()
	villageTitle.Text = if team then ("%s castle"):format(team.Name) else "No side yet"
	keepLabel.Visible = false
	keepFill.Parent.Visible = false
	if not castle then
		villageNext.Text = "Waiting for the castles"
		wallLabel.Visible = false
		wallFill.Parent.Visible = false
		peopleText.Text = ""
		return
	end
	local breached = castle:GetAttribute("Breached") == true
	villageNext.Text = if castle:GetAttribute("Fallen") == true then "Fallen"
		elseif breached then "Breached - defend the keep"
		else "Walls holding"
	local hp, max = castle:GetAttribute("StructureHP"), castle:GetAttribute("StructureMax")
	wallLabel.Visible = true
	wallFill.Parent.Visible = true
	if typeof(hp) == "number" and typeof(max) == "number" and max > 0 then
		wallLabel.Text = ("Castle  %d / %d"):format(hp, max)
		wallFill.Size = UDim2.fromScale(math.clamp(hp / max, 0, 1), 1)
		wallFill.BackgroundColor3 = if breached then Palette.ALARM else Palette.DAUB_DIM
	else
		wallLabel.Text = "Castle"
		wallFill.Size = UDim2.fromScale(1, 1)
	end
	peopleText.Text = if team then ("%d on your side"):format(#team:GetPlayers()) else ""
end

local function drawGoods()
	local stats = goodsSource()
	for name, text in goodsText do
		local counter = stats and stats:FindFirstChild(name)
		text.Text = if counter and counter:IsA("IntValue") then tostring(counter.Value) else "0"
	end
end

local function drawVillage()
	if TWO_TEAM then
		drawCastle()
		return
	end
	local base = myBase()
	if not base then
		local eliminated = player:GetAttribute("Eliminated") == true
		villageTitle.Text = if eliminated then "No house of your own" else "No village yet"
		villageNext.Text = if eliminated
			then ("You serve %s"):format(tostring(player:GetAttribute("Squad") or "another"))
			else "Claim an empty plot to begin"
		-- Hide the meters outright rather than emptying them. Two grey tracks
		-- with no labels above them read as "something is broken", not as
		-- "you do not have one of these yet".
		wallLabel.Visible = false
		keepLabel.Visible = false
		wallFill.Parent.Visible = false
		keepFill.Parent.Visible = false
	else
		wallLabel.Visible = true
		keepLabel.Visible = true
		wallFill.Parent.Visible = true
		keepFill.Parent.Visible = true

		local stage = base:GetAttribute("Stage")
		local stageName = base:GetAttribute("StageName")
		villageTitle.Text = ("Your village  %d/10"):format(if typeof(stage) == "number" then stage else 0)
		villageNext.Text = if typeof(stageName) == "string" and stageName ~= "Complete"
			then ("Next: %s"):format(stageName)
			else "Complete"

		local wall = base:GetAttribute("Wall")
		-- Ceilings come from the server too, so retuning WALL_MAX_HP or KEEP_HP
		-- cannot quietly desync the meters from what they are measuring.
		local publishedWallMax = base:GetAttribute("WallMax")
		local wallMax = if typeof(publishedWallMax) == "number" and publishedWallMax > 0
			then publishedWallMax else 600
		if typeof(wall) == "number" then
			wallLabel.Text = ("Wall  %d"):format(wall)
			wallFill.Size = UDim2.fromScale(math.clamp(wall / wallMax, 0, 1), 1)
			wallFill.BackgroundColor3 = if wall <= 0 then Palette.ALARM else Palette.DAUB_DIM
		else
			wallLabel.Text = "Wall  none"
			wallFill.Size = UDim2.fromScale(0, 1)
		end

		local keep = base:GetAttribute("KeepHealth")
		local hasKeep = base:FindFirstChild("Keep") ~= nil
		if hasKeep and typeof(keep) == "number" then
			keepLabel.Text = ("Keep  %d"):format(keep)
			local publishedKeepMax = base:GetAttribute("KeepMax")
			local keepMax = if typeof(publishedKeepMax) == "number" and publishedKeepMax > 0
				then publishedKeepMax else 200
			keepFill.Size = UDim2.fromScale(math.clamp(keep / keepMax, 0, 1), 1)
			keepFill.BackgroundColor3 = if keep <= 0 then Palette.ALARM else Palette.MOSS
		else
			keepLabel.Text = "Keep  not built"
			keepFill.Size = UDim2.fromScale(0, 1)
		end
	end

	local roster = player:GetAttribute("Specialists")
	local reputation = player:GetAttribute("Reputation")
	local people = if typeof(roster) == "string" and roster ~= "" then roster else "no specialists"
	peopleText.Text = ("%s   ·   standing %d"):format(
		people, if typeof(reputation) == "number" then reputation else 0)
end

-- ---------------------------------------------------------------- wiring
-- Event driven wherever the value is pushed, which is everything except where
-- the character is standing.
for _, name in { "MatchState", "MatchClock", "ZoneHalf", "BoardHalf" } do
	Workspace:GetAttributeChangedSignal(name):Connect(drawMatch)
end
for _, name in { "Specialists", "Reputation", "Eliminated", "Squad" } do
	player:GetAttributeChangedSignal(name):Connect(drawVillage)
end

local function watchStats()
	if TWO_TEAM then
		-- Follow whichever team you are on; teams are dealt at every match start.
		local hooked: Instance? = nil
		local connections: { RBXScriptConnection } = {}
		local function rehook()
			local goods = goodsSource()
			if goods == hooked then
				drawGoods()
				return
			end
			for _, c in connections do
				c:Disconnect()
			end
			table.clear(connections)
			hooked = goods
			if goods then
				for _, counter in goods:GetChildren() do
					if counter:IsA("IntValue") then
						table.insert(connections, counter.Changed:Connect(drawGoods))
					end
				end
			end
			drawGoods()
			drawVillage()
		end
		player:GetPropertyChangedSignal("Team"):Connect(rehook)
		rehook()
		return
	end
	local stats = player:WaitForChild("leaderstats", 10)
	if not stats then
		return
	end
	for _, counter in stats:GetChildren() do
		if counter:IsA("IntValue") then
			counter.Changed:Connect(drawGoods)
		end
	end
	stats.ChildAdded:Connect(function(child)
		if child:IsA("IntValue") then
			child.Changed:Connect(drawGoods)
		end
		drawGoods()
	end)
	drawGoods()
end
task.spawn(watchStats)

drawMatch()
drawVillage()

-- The only loop. It does one distance comparison and a cheap village redraw;
-- base attributes are on instances this client does not own, and watching
-- sixteen of them for six attributes each is more machinery than a 5 Hz redraw
-- of two short strings is worth.
task.spawn(function()
	while true do
		task.wait(POLL)

		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local half = attr("ZoneHalf")
		local running = attr("MatchState") == "Running"
		if running and root and root:IsA("BasePart") and typeof(half) == "number" then
			setAlarm(outsideBy(root.Position, half) > 0)
		else
			setAlarm(false)
		end

		drawVillage()
	end
end)
