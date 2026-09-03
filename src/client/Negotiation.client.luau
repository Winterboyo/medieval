--!strict
-- Medieval Land - the specialist ransom panel.
-- Runs in StarterPlayerScripts, one copy per player.
--
-- Everything before this was server-authoritative through ProximityPrompt.Triggered
-- and Tool.Activated, which the engine fires on the server: the client never got
-- to say anything, so there was nothing to distrust. A negotiation cannot work
-- that way. Somebody has to choose accept/counter/refuse, and the choice starts
-- on their machine, so this is the first place the client speaks.
--
-- The rule that follows from that: this file decides NOTHING. It draws whatever
-- the last NegotiationState said and it forwards button presses. It does not
-- track whose turn it is, does not decide whether a counter is legal, and does
-- not move the panel forward after a click - it waits for the server to say what
-- happened. Anything this script "knows" between packets is presentation only
-- (which number the stepper is parked on, whether a fade is running).
--
-- The panel has no close button on purpose. DESIGN.md: theft is deliberate, so
-- the engagement is forced - the messenger cannot be refused outright. Refusing
-- is an action with a cost, which is the Refuse button, not the escape key.
--
-- Palette is lifted from scripts/build-world.luau (daub cream, timber brown,
-- slate) so the panel reads as part of the same world. Nothing saturated: this
-- sits on top of a muted map and a bright UI would look like a different game.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

-- Declared in default.project.json rather than created here, same as Notify, so
-- the remotes are version-controlled instead of appearing at runtime.
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local stateRemote = remotes:WaitForChild("NegotiationState") :: RemoteEvent
local actRemote = remotes:WaitForChild("NegotiationAct") :: RemoteEvent

local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

-- World palette.
local DAUB = Color3.fromRGB(226, 218, 200) -- primary text, the plaster cream
local DAUB_DIM = Color3.fromRGB(168, 158, 140) -- secondary text
local TIMBER = Color3.fromRGB(74, 52, 34) -- header beam
local TIMBER_LIGHT = Color3.fromRGB(96, 66, 42) -- button faces
local BOARD = Color3.fromRGB(40, 35, 30) -- panel ground, dark oak in shadow
local SLATE = Color3.fromRGB(84, 78, 76) -- rules and disabled faces
local MOSS = Color3.fromRGB(84, 100, 72) -- accept
local TILED = Color3.fromRGB(112, 62, 48) -- refuse, and the "you are short" red
local SHORT_TEXT = Color3.fromRGB(196, 132, 112) -- that red, lightened to stay legible on BOARD
local DISABLED_TEXT = Color3.fromRGB(126, 118, 108)

local PANEL_W = 440
local PANEL_H = 326
local PAD = 16
local INNER_W = PANEL_W - PAD * 2

-- Counter step. One-at-a-time is correct but unusable once a demand is 40 ore,
-- and a free text box means parsing whatever someone types - "1e9", "-5", "12 "
-- - on the client and again on the server. Five is coarse enough to reach a
-- number in a few clicks, and the server clamps the result regardless.
local COUNTER_STEP = 5

-- If the server goes quiet after we act, the buttons would stay dead forever.
-- They re-arm after this long. This is a fallback for a dropped packet, not a
-- turn timer - the server still owns whose turn it is.
local REPLY_TIMEOUT = 6

local FADE = TweenInfo.new(0.16, Enum.EasingStyle.Quad)
local RISE = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- The last packet we believed. Seeded so the first render has something to draw
-- even if the opening packet is half-empty: every field falls back to what is
-- already here rather than to nil.
type Session = {
	active: boolean,
	role: string,
	otherName: string,
	specialist: string,
	rank: number,
	round: number,
	maxRounds: number,
	resource: string,
	demand: number,
	yourTurn: boolean,
	youHold: number,
	message: string,
}

local session: Session = {
	active = false,
	role = "victim",
	otherName = "Someone",
	specialist = "Specialist",
	rank = 1,
	round = 1,
	maxRounds = 1,
	resource = "Resource",
	demand = 0,
	yourTurn = false,
	youHold = 0,
	message = "",
}

local counterAmount = 0
local counterAnchor = -1 -- the demand counterAmount was last derived from
local awaitingReply = false
local replyToken = 0
local fadeToken = 0

-- Build ----------------------------------------------------------------------

local screen = Instance.new("ScreenGui")
screen.Name = "Negotiation"
screen.ResetOnSpawn = false -- dying mid-negotiation must not clear the panel
screen.IgnoreGuiInset = true
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
-- Above the notice toast's default 0. They do not overlap today; if they ever
-- do, the panel is the thing being read.
screen.DisplayOrder = 1
screen.Parent = playerGui

-- CanvasGroup rather than a plain Frame so the whole panel fades on one
-- property. Tweening transparency on a dozen labels separately drifts out of
-- sync and doubles the tween count for no gain.
local panel = Instance.new("CanvasGroup")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.new(0.5, 0, 0.46, 0) -- centre-ish, sat slightly high so it clears the hotbar
panel.Size = UDim2.fromOffset(PANEL_W, PANEL_H)
panel.BackgroundColor3 = BOARD
panel.BackgroundTransparency = 0.06
panel.BorderSizePixel = 0
panel.GroupTransparency = 1
panel.Visible = false
panel.Parent = screen

local panelCorner = Instance.new("UICorner")
panelCorner.CornerRadius = UDim.new(0, 8)
panelCorner.Parent = panel

local panelStroke = Instance.new("UIStroke")
panelStroke.Color = TIMBER_LIGHT
panelStroke.Thickness = 2
panelStroke.Parent = panel

-- Small factories. Notifications builds its one label longhand, which is right
-- for one label; there are fourteen instances here and longhand would bury the
-- layout under property assignments.
local function makeLabel(name: string, y: number, height: number, size: number, colour: Color3, font: Enum.Font): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.Position = UDim2.new(0, PAD, 0, y)
	label.Size = UDim2.fromOffset(INNER_W, height)
	label.BackgroundTransparency = 1
	label.TextColor3 = colour
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Font = font
	label.TextSize = size
	label.Text = ""
	label.Parent = panel
	return label
end

local function makeButton(name: string, parent: GuiObject, position: UDim2, size: UDim2, textSize: number): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.Position = position
	button.Size = size
	button.BackgroundColor3 = SLATE
	button.BorderSizePixel = 0
	button.TextColor3 = DAUB
	button.Font = Enum.Font.GothamMedium
	button.TextSize = textSize
	button.Text = name
	-- Driven by hand in render(), so a disabled button does not still light up
	-- under the cursor as though it were pressable.
	button.AutoButtonColor = false
	button.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 5)
	corner.Parent = button
	return button
end

-- Header beam.
local header = Instance.new("Frame")
header.Name = "Header"
header.Size = UDim2.new(1, 0, 0, 42)
header.BackgroundColor3 = TIMBER
header.BorderSizePixel = 0
header.Parent = panel

local headerCorner = Instance.new("UICorner")
headerCorner.CornerRadius = UDim.new(0, 8)
headerCorner.Parent = header

-- UICorner rounds all four corners; this squares off the bottom two so the beam
-- meets the panel body flush instead of showing two notches of the ground.
local headerFoot = Instance.new("Frame")
headerFoot.Name = "Foot"
headerFoot.AnchorPoint = Vector2.new(0, 1)
headerFoot.Position = UDim2.new(0, 0, 1, 0)
headerFoot.Size = UDim2.new(1, 0, 0, 8)
headerFoot.BackgroundColor3 = TIMBER
headerFoot.BorderSizePixel = 0
headerFoot.Parent = header

local title = Instance.new("TextLabel")
title.Name = "Title"
title.Position = UDim2.new(0, PAD, 0, 0)
title.Size = UDim2.new(1, -PAD * 2, 1, 0)
title.BackgroundTransparency = 1
title.TextColor3 = DAUB
title.TextXAlignment = Enum.TextXAlignment.Left
-- The one serif in the file: this line is flavour, everything below it is
-- numbers and wants a plainer face.
title.Font = Enum.Font.Merriweather
title.TextSize = 17
title.Text = ""
title.ZIndex = 2
title.Parent = header

local roundLabel = Instance.new("TextLabel")
roundLabel.Name = "Round"
roundLabel.Position = UDim2.new(0, PAD, 0, 0)
roundLabel.Size = UDim2.new(1, -PAD * 2, 1, 0)
roundLabel.BackgroundTransparency = 1
roundLabel.TextColor3 = DAUB_DIM
roundLabel.TextXAlignment = Enum.TextXAlignment.Right
roundLabel.Font = Enum.Font.GothamMedium
roundLabel.TextSize = 14
roundLabel.Text = ""
roundLabel.ZIndex = 2
roundLabel.Parent = header

local subjectLabel = makeLabel("Subject", 56, 22, 15, DAUB, Enum.Font.Gotham)
local demandLabel = makeLabel("Demand", 84, 28, 21, DAUB, Enum.Font.GothamBold)
local holdLabel = makeLabel("Hold", 114, 20, 14, DAUB_DIM, Enum.Font.Gotham)

local rule = Instance.new("Frame")
rule.Name = "Rule"
rule.Position = UDim2.new(0, PAD, 0, 144)
rule.Size = UDim2.fromOffset(INNER_W, 1)
rule.BackgroundColor3 = SLATE
rule.BorderSizePixel = 0
rule.Parent = panel

-- Counter stepper row.
local counterRow = Instance.new("Frame")
counterRow.Name = "CounterRow"
counterRow.Position = UDim2.new(0, PAD, 0, 158)
counterRow.Size = UDim2.fromOffset(INNER_W, 32)
counterRow.BackgroundTransparency = 1
counterRow.Parent = panel

local counterCaption = Instance.new("TextLabel")
counterCaption.Name = "Caption"
counterCaption.Size = UDim2.fromOffset(200, 32)
counterCaption.BackgroundTransparency = 1
counterCaption.TextColor3 = DAUB_DIM
counterCaption.TextXAlignment = Enum.TextXAlignment.Left
counterCaption.Font = Enum.Font.Gotham
counterCaption.TextSize = 14
counterCaption.Text = "Your counter-offer"
counterCaption.Parent = counterRow

local minusButton = makeButton("Minus", counterRow, UDim2.fromOffset(INNER_W - 172, 0), UDim2.fromOffset(34, 32), 18)
minusButton.Text = "-"
minusButton.BackgroundColor3 = TIMBER

local counterValue = Instance.new("TextLabel")
counterValue.Name = "Value"
counterValue.Position = UDim2.fromOffset(INNER_W - 130, 0)
counterValue.Size = UDim2.fromOffset(96, 32)
counterValue.BackgroundColor3 = TIMBER
counterValue.BackgroundTransparency = 0.35
counterValue.BorderSizePixel = 0
counterValue.TextColor3 = DAUB
counterValue.Font = Enum.Font.GothamBold
counterValue.TextSize = 16
counterValue.Text = "0"
counterValue.Parent = counterRow

local valueCorner = Instance.new("UICorner")
valueCorner.CornerRadius = UDim.new(0, 5)
valueCorner.Parent = counterValue

local plusButton = makeButton("Plus", counterRow, UDim2.fromOffset(INNER_W - 34, 0), UDim2.fromOffset(34, 32), 18)
plusButton.Text = "+"
plusButton.BackgroundColor3 = TIMBER

local messageLabel = makeLabel("Message", 200, 52, 14, DAUB_DIM, Enum.Font.Gotham)
messageLabel.TextWrapped = true
messageLabel.TextYAlignment = Enum.TextYAlignment.Top

-- Action row. Three fixed-width buttons rather than a UIListLayout: the panel is
-- a fixed size, so the arithmetic is done once here and never reflows.
local ACTION_Y = PANEL_H - PAD - 42
local ACTION_W = 129
local acceptButton = makeButton("Accept", panel, UDim2.fromOffset(PAD, ACTION_Y), UDim2.fromOffset(ACTION_W, 42), 15)
local counterButton = makeButton("Counter", panel, UDim2.fromOffset(PAD + 139, ACTION_Y), UDim2.fromOffset(ACTION_W, 42), 15)
local refuseButton = makeButton("Refuse", panel, UDim2.fromOffset(PAD + 278, ACTION_Y), UDim2.fromOffset(ACTION_W, 42), 15)

-- Reading the packet ---------------------------------------------------------

-- Every field is read against a fallback, and the fallback is the value already
-- on screen. A packet that arrives with `demand` as a string leaves the old
-- demand up rather than blanking the line or erroring halfway through a render.
local function readString(packet: { [string]: unknown }, key: string, fallback: string): string
	local value = packet[key]
	if type(value) == "string" and value ~= "" then
		return value
	end
	return fallback
end

local function readNumber(packet: { [string]: unknown }, key: string, fallback: number): number
	local value = packet[key]
	if type(value) ~= "number" then
		return fallback
	end
	-- NaN fails every comparison it takes part in, so a NaN demand would make
	-- the affordability check quietly wrong instead of loudly broken.
	-- Infinities render as "inf". Neither is a ransom.
	if value ~= value or value == math.huge or value == -math.huge then
		return fallback
	end
	-- The contract says these are integers. Floor rather than trust it - a
	-- demand of 12.5 would otherwise print as "12.5 Ore".
	return math.floor(value)
end

local function readBool(packet: { [string]: unknown }, key: string, fallback: boolean): boolean
	local value = packet[key]
	if type(value) == "boolean" then
		return value
	end
	return fallback
end

-- Drawing --------------------------------------------------------------------

local function setButtonState(button: TextButton, enabled: boolean, face: Color3)
	button.AutoButtonColor = enabled
	button.BackgroundColor3 = if enabled then face else SLATE
	button.BackgroundTransparency = if enabled then 0 else 0.5
	button.TextColor3 = if enabled then DAUB else DISABLED_TEXT
end

local function render()
	local rank = math.clamp(session.rank, 1, 5)
	local round = math.max(1, session.round)
	local maxRounds = math.max(round, session.maxRounds)
	local demand = math.max(0, session.demand)
	local hold = math.max(0, session.youHold)

	if session.role == "thief" then
		title.Text = "Your Messenger Waits"
		subjectLabel.Text = string.format("You hold %s's %s (Rank %d)", session.otherName, session.specialist, rank)
	else
		-- Anything that is not "thief" is drawn as the victim's side. Guessing
		-- wrong here shows the wrong sentence; drawing nothing shows a blank
		-- panel, which is worse.
		title.Text = "A Messenger Arrives"
		subjectLabel.Text = string.format("%s holds your %s (Rank %d)", session.otherName, session.specialist, rank)
	end

	roundLabel.Text = string.format("Round %d of %d", round, maxRounds)
	demandLabel.Text = string.format("%d %s demanded", demand, session.resource)

	local short = hold < demand
	holdLabel.Text = string.format("You hold %d %s", hold, session.resource)
	holdLabel.TextColor3 = if short then SHORT_TEXT else DAUB_DIM

	counterValue.Text = tostring(counterAmount)
	messageLabel.Text = session.message

	local canAct = session.active and session.yourTurn and not awaitingReply

	-- Accept stays clickable while short. The server refuses it anyway, and a
	-- button that is dead for two different reasons - not your turn, cannot
	-- afford it - is unreadable. Short is shown in the label and the face
	-- colour instead, so the player can see why before they click.
	if canAct and short then
		acceptButton.Text = string.format("Accept (%d short)", demand - hold)
		setButtonState(acceptButton, true, TILED)
	else
		acceptButton.Text = "Accept"
		setButtonState(acceptButton, canAct, MOSS)
	end

	counterButton.Text = if canAct then string.format("Counter %d", counterAmount) else "Counter"
	setButtonState(counterButton, canAct, TIMBER_LIGHT)
	setButtonState(refuseButton, canAct, TILED)

	if session.active and not session.yourTurn then
		counterCaption.Text = string.format("Waiting on %s", session.otherName)
	else
		counterCaption.Text = "Your counter-offer"
	end
end

local function show()
	fadeToken += 1
	panel.Visible = true
	panel.Position = UDim2.new(0.5, 0, 0.48, 0)
	TweenService:Create(panel, RISE, { Position = UDim2.new(0.5, 0, 0.46, 0) }):Play()
	TweenService:Create(panel, FADE, { GroupTransparency = 0 }):Play()
end

local function hide()
	fadeToken += 1
	local token = fadeToken
	TweenService:Create(panel, FADE, { GroupTransparency = 1 }):Play()
	task.delay(FADE.Time, function()
		-- A second session can open while this fade is still running. The token
		-- says whether a show() has happened since; if it has, this delayed
		-- cleanup is stale and must leave the panel alone.
		if fadeToken == token then
			panel.Visible = false
		end
	end)
end

-- Acting ---------------------------------------------------------------------

local function act(action: string, amount: number?)
	if not session.active or not session.yourTurn or awaitingReply then
		return
	end

	-- Locked until the next NegotiationState. Nothing here assumes the action
	-- landed - the panel does not advance the round or clear the demand. This
	-- only stops the same action being fired three times while the round trip
	-- is still in flight.
	awaitingReply = true
	replyToken += 1
	local token = replyToken
	render()

	actRemote:FireServer(action, amount)

	task.delay(REPLY_TIMEOUT, function()
		if awaitingReply and replyToken == token then
			awaitingReply = false
			render()
		end
	end)
end

acceptButton.Activated:Connect(function()
	act("accept", nil)
end)

counterButton.Activated:Connect(function()
	act("counter", counterAmount)
end)

refuseButton.Activated:Connect(function()
	act("refuse", nil)
end)

-- The steppers stay live even when it is not your turn. Picking a number is a
-- local decision with no packet behind it, and lining up an offer while the
-- other side is still thinking is most of the point of showing it early.
minusButton.Activated:Connect(function()
	counterAmount = math.max(0, counterAmount - COUNTER_STEP)
	render()
end)

plusButton.Activated:Connect(function()
	counterAmount += COUNTER_STEP
	render()
end)

-- Receiving ------------------------------------------------------------------

stateRemote.OnClientEvent:Connect(function(payload: unknown)
	-- The server is the only thing that should ever fire this, but a client
	-- reading its own remotes is not a reason to trust the payload's shape.
	if type(payload) ~= "table" then
		return
	end
	local packet = payload :: { [string]: unknown }

	local wasActive = session.active

	session = {
		active = readBool(packet, "active", session.active),
		role = readString(packet, "role", session.role),
		otherName = readString(packet, "otherName", session.otherName),
		specialist = readString(packet, "specialist", session.specialist),
		rank = readNumber(packet, "rank", session.rank),
		round = readNumber(packet, "round", session.round),
		maxRounds = readNumber(packet, "maxRounds", session.maxRounds),
		resource = readString(packet, "resource", session.resource),
		demand = readNumber(packet, "demand", session.demand),
		yourTurn = readBool(packet, "yourTurn", session.yourTurn),
		youHold = readNumber(packet, "youHold", session.youHold),
		-- The only field allowed to arrive empty: a packet with nothing to say
		-- should clear the last line rather than leave a stale one sitting
		-- under a new round. readString rejects "", so this is read directly.
		message = if type(packet.message) == "string" then packet.message :: string else session.message,
	}

	-- Any state from the server ends the wait, whatever it says. If the action
	-- was rejected the buttons come back; if it was taken, yourTurn will be
	-- false and they stay dark for the right reason.
	awaitingReply = false
	replyToken += 1

	-- Park the stepper on the demand whenever the demand moves, so the first
	-- click on + or - adjusts the number under discussion rather than a stale
	-- one from two rounds ago.
	if session.demand ~= counterAnchor then
		counterAnchor = session.demand
		counterAmount = math.max(0, session.demand)
	end

	if session.active then
		render() -- before show(), so the panel never fades in wearing the last session
		if not wasActive then
			show()
		end
	else
		if wasActive then
			hide()
		end
		-- The next session starts from a clean stepper rather than inheriting a
		-- number nobody chose for it.
		counterAnchor = -1
	end
end)

render()
