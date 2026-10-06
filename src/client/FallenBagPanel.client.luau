--!strict
-- Medieval Land - fallen bag prompts and the "Choose goods" panel (DESIGN.md "bag ransacking").
-- FallenBagService owns every bag and every transfer; this only decides which prompt you see,
-- shows what is in the bag, and sends your selection.
--
--   * "Take all" (E, hold 2 s) shows when everything left fits in your free load.
--   * "Choose goods" (E) shows when it does not; it opens this panel. Pick goods and amounts
--     (capped by your free load), press Take, then hold still while the bar fills.
--   * Neither shows if nothing left fits at all.
-- The prompt's label counts down the bag's remaining seconds.
--
-- Functional first pass in the HUD's colours (Palette.HUD); styling is open to rework.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ProximityPromptService = game:GetService("ProximityPromptService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
if not require(Shared:WaitForChild("GameMode")).TwoTeam then
	return
end
local Cargo = require(Shared:WaitForChild("Cargo"))
local Palette = require(Shared:WaitForChild("Palette"))
local HUD = Palette.HUD

local bagRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("FallenBag") :: RemoteEvent
local player = Players.LocalPlayer
local folder = Workspace:WaitForChild("FallenBags")

local ROW_H = 34
local WIDTH = 400
local HEADER = 50

-- ---------------------------------------------------------------- what fits
local function myLoad(): number
	local bag = player:FindFirstChild("Cargo")
	local load = bag and bag:GetAttribute("Load")
	return if typeof(load) == "number" then load else 0
end

local function bagContents(model: Instance): { [string]: number }
	local out = {}
	for _, resource in Cargo.ORDER do
		local n = model:GetAttribute(resource)
		out[resource] = if typeof(n) == "number" then n else 0
	end
	return out
end

local function updatePrompts(model: Instance)
	local anchor = model:FindFirstChild("PromptAnchor")
	local takeAll = anchor and anchor:FindFirstChild("TakeAll")
	local choose = anchor and anchor:FindFirstChild("ChooseGoods")
	if not (takeAll and choose and takeAll:IsA("ProximityPrompt") and choose:IsA("ProximityPrompt")) then
		return
	end
	local contents = bagContents(model)
	local load = myLoad()
	local everything = load + Cargo.loadOf(contents) <= Cargo.MAX_LOAD
	local some = false
	for resource, n in contents do
		if n > 0 and Cargo.fits(load, resource, 1) > 0 then
			some = true
		end
	end
	takeAll.Enabled = everything
	choose.Enabled = some and not everything
end

local function refreshAll()
	for _, model in folder:GetChildren() do
		updatePrompts(model)
	end
end

-- panel state, built further down; declared here so the bag watchers can see it
local gui: ScreenGui
local openModel: Instance? = nil
local holding = false
local refreshPanel: () -> ()

local function watchBag(model: Instance)
	model.AttributeChanged:Connect(function()
		updatePrompts(model)
		-- someone else took goods while my panel is open: keep its numbers honest
		if model == openModel and gui.Enabled and not holding then
			refreshPanel()
		end
	end)
	local anchor = model:WaitForChild("PromptAnchor", 5)
	if anchor then
		anchor:WaitForChild("ChooseGoods", 5)
	end
	updatePrompts(model)
end
for _, model in folder:GetChildren() do
	task.spawn(watchBag, model)
end
folder.ChildAdded:Connect(watchBag)

local function watchMyBag(bag: Instance)
	bag:GetAttributeChangedSignal("Load"):Connect(refreshAll)
	refreshAll()
end
local mine = player:FindFirstChild("Cargo")
if mine then
	watchMyBag(mine)
end
player.ChildAdded:Connect(function(child)
	if child.Name == "Cargo" then
		watchMyBag(child)
	end
end)

-- countdown on the prompts' label
task.spawn(function()
	while true do
		local now = Workspace:GetServerTimeNow()
		for _, model in folder:GetChildren() do
			local expires = model:GetAttribute("ExpiresAt")
			local anchor = model:FindFirstChild("PromptAnchor")
			if typeof(expires) == "number" and anchor then
				local text = ("Fallen bag  %ds"):format(math.max(0, math.ceil(expires - now)))
				for _, prompt in anchor:GetChildren() do
					if prompt:IsA("ProximityPrompt") then
						prompt.ObjectText = text
					end
				end
			end
		end
		task.wait(0.5)
	end
end)

-- ---------------------------------------------------------------- the panel
local function frame(parent: Instance, name: string, size: UDim2, position: UDim2, colour: Color3, alpha: number): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.Size = size
	f.Position = position
	f.BackgroundColor3 = colour
	f.BackgroundTransparency = alpha
	f.BorderSizePixel = 0
	f.Parent = parent
	return f
end

local function label(parent: Instance, name: string, text: string, size: UDim2, position: UDim2,
	align: Enum.TextXAlignment?): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.Text = text
	t.Size = size
	t.Position = position
	t.BackgroundTransparency = 1
	t.Font = Palette.FONT_LABEL
	t.TextSize = 16
	t.TextColor3 = HUD.TEXT
	t.TextXAlignment = align or Enum.TextXAlignment.Left
	t.Parent = parent
	return t
end

local function button(parent: Instance, name: string, text: string, size: UDim2, position: UDim2): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Text = text
	b.Size = size
	b.Position = position
	b.BackgroundColor3 = HUD.TRACK
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Font = Palette.FONT_STRONG
	b.TextSize = 16
	b.TextColor3 = HUD.TEXT
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Palette.CORNER_BUTTON)
	corner.Parent = b
	b.Parent = parent
	return b
end

gui = Instance.new("ScreenGui")
gui.Name = "FallenBagPanel"
gui.ResetOnSpawn = false
gui.DisplayOrder = 5
gui.Enabled = false
gui.Parent = player:WaitForChild("PlayerGui")

local height = HEADER + 4 + #Cargo.ORDER * ROW_H + 100
local panel = frame(gui, "Panel", UDim2.fromOffset(WIDTH, height), UDim2.fromScale(0.5, 0.5), HUD.PANEL, 0.08)
panel.AnchorPoint = Vector2.new(0.5, 0.5)
local pc = Instance.new("UICorner")
pc.CornerRadius = UDim.new(0, HUD.CORNER)
pc.Parent = panel
local edge = Instance.new("UIStroke")
edge.Color = HUD.EDGE
edge.Transparency = HUD.EDGE_ALPHA
edge.Parent = panel
local scale = Instance.new("UIScale")
scale.Parent = panel
local function fit()
	local camera = Workspace.CurrentCamera
	local view = camera and camera.ViewportSize or Vector2.new(1280, 720)
	scale.Scale = math.min(1, (view.Y - 40) / height, (view.X - 32) / WIDTH)
end

local title = label(panel, "Title", "Fallen bag", UDim2.new(1, -24, 0, 24), UDim2.fromOffset(12, 10))
title.Font = Palette.FONT_HEADING
title.TextSize = 18
local hint = label(panel, "Hint", "in bag", UDim2.fromOffset(60, 16), UDim2.new(1, -264, 0, HEADER - 18), Enum.TextXAlignment.Right)
hint.TextColor3 = HUD.TEXT_DIM
hint.TextSize = 13

type Row = { held: TextLabel, amount: TextLabel }
local rows: { [string]: Row } = {}
local amounts: { [string]: number } = {}

local summary: TextLabel
local takeButton: TextButton
local barTrack: Frame
local barFill: Frame

-- clamp every amount to what the bag holds and to what still fits in my free load
local function clampAmounts()
	if not openModel then
		return
	end
	local inBag = bagContents(openModel)
	local free = Cargo.MAX_LOAD - myLoad()
	for _, resource in Cargo.ORDER do
		amounts[resource] = math.clamp(amounts[resource] or 0, 0, inBag[resource])
	end
	-- if the selection is over budget, trim the last goods first
	for i = #Cargo.ORDER, 1, -1 do
		local resource = Cargo.ORDER[i]
		while Cargo.loadOf(amounts) > free and amounts[resource] > 0 do
			amounts[resource] -= 1
		end
	end
end

refreshPanel = function()
	if not openModel then
		return
	end
	clampAmounts()
	local inBag = bagContents(openModel :: Instance)
	for _, resource in Cargo.ORDER do
		local row = rows[resource]
		row.held.Text = tostring(inBag[resource])
		row.held.TextColor3 = if inBag[resource] > 0 then HUD.TEXT else HUD.TEXT_DIM
		row.amount.Text = tostring(amounts[resource])
		row.amount.TextColor3 = if amounts[resource] > 0 then HUD.ACCENT else HUD.TEXT_DIM
	end
	local moving = Cargo.loadOf(amounts)
	summary.Text = ("Taking %d load  |  room for %d"):format(moving, Cargo.MAX_LOAD - myLoad())
	takeButton.TextColor3 = if moving > 0 and not holding then HUD.TEXT else HUD.TEXT_DIM
end

for i, resource in Cargo.ORDER do
	local y = HEADER + (i - 1) * ROW_H
	local row = frame(panel, resource, UDim2.new(1, -24, 0, ROW_H - 4), UDim2.fromOffset(12, y), HUD.TRACK, 0.6)
	local rc = Instance.new("UICorner")
	rc.CornerRadius = UDim.new(0, Palette.CORNER_CHIP)
	rc.Parent = row
	local dot = frame(row, "Dot", UDim2.fromOffset(8, 8), UDim2.new(0, 10, 0.5, -4), Palette.GOODS[resource] or HUD.TEXT_DIM, 0)
	local dc = Instance.new("UICorner")
	dc.CornerRadius = UDim.new(1, 0)
	dc.Parent = dot
	label(row, "Name", Cargo.LABEL[resource], UDim2.fromOffset(112, ROW_H - 4), UDim2.fromOffset(26, 0))
	local held = label(row, "InBag", "0", UDim2.fromOffset(40, ROW_H - 4), UDim2.new(1, -232, 0, 0), Enum.TextXAlignment.Right)
	local minus = button(row, "Less", "-", UDim2.fromOffset(28, 24), UDim2.new(1, -180, 0.5, -12))
	local amount = label(row, "Amount", "0", UDim2.fromOffset(36, ROW_H - 4), UDim2.new(1, -150, 0, 0), Enum.TextXAlignment.Center)
	local plus = button(row, "More", "+", UDim2.fromOffset(28, 24), UDim2.new(1, -112, 0.5, -12))
	local all = button(row, "All", "Max", UDim2.fromOffset(44, 24), UDim2.new(1, -76, 0.5, -12))
	local none = button(row, "None", "0", UDim2.fromOffset(24, 24), UDim2.new(1, -28, 0.5, -12))
	rows[resource] = { held = held, amount = amount }
	minus.Activated:Connect(function()
		if holding then return end
		amounts[resource] = (amounts[resource] or 0) - 1
		refreshPanel()
	end)
	plus.Activated:Connect(function()
		if holding then return end
		local free = Cargo.MAX_LOAD - myLoad() - Cargo.loadOf(amounts)
		if free >= Cargo.WEIGHT[resource] then
			amounts[resource] = (amounts[resource] or 0) + 1
		end
		refreshPanel()
	end)
	all.Activated:Connect(function()
		if holding then return end
		amounts[resource] = 0
		local free = Cargo.MAX_LOAD - myLoad() - Cargo.loadOf(amounts)
		amounts[resource] = math.min(bagContents(openModel :: Instance)[resource], math.floor(free / Cargo.WEIGHT[resource]))
		refreshPanel()
	end)
	none.Activated:Connect(function()
		if holding then return end
		amounts[resource] = 0
		refreshPanel()
	end)
end

local footY = HEADER + 4 + #Cargo.ORDER * ROW_H
summary = label(panel, "Summary", "", UDim2.new(1, -24, 0, 20), UDim2.fromOffset(12, footY))
summary.TextColor3 = HUD.TEXT_DIM
summary.TextSize = 14
barTrack = frame(panel, "HoldBar", UDim2.new(1, -24, 0, 8), UDim2.fromOffset(12, footY + 24), HUD.TRACK, 0.2)
barTrack.Visible = false
barFill = frame(barTrack, "Fill", UDim2.fromScale(0, 1), UDim2.fromScale(0, 0), HUD.ACCENT, 0)
takeButton = button(panel, "Take", "Take", UDim2.fromOffset(150, 32), UDim2.new(1, -312, 0, footY + 42))
takeButton.BackgroundColor3 = HUD.ACCENT
takeButton.BackgroundTransparency = 0.35
local cancel = button(panel, "Cancel", "Close", UDim2.fromOffset(150, 32), UDim2.new(1, -162, 0, footY + 42))

local function close()
	if holding then
		bagRemote:FireServer("cancel")
	end
	holding = false
	barTrack.Visible = false
	gui.Enabled = false
	openModel = nil
end

local function open(model: Instance)
	openModel = model
	holding = false
	barTrack.Visible = false
	for _, resource in Cargo.ORDER do
		amounts[resource] = 0
	end
	local owner = model:GetAttribute("OwnerName")
	title.Text = if typeof(owner) == "string" then ("%s's fallen bag"):format(owner) else "Fallen bag"
	fit()
	refreshPanel()
	gui.Enabled = true
end

takeButton.Activated:Connect(function()
	if holding or not openModel then
		return
	end
	local selection = {}
	for _, resource in Cargo.ORDER do
		if (amounts[resource] or 0) > 0 then
			selection[resource] = amounts[resource]
		end
	end
	if next(selection) == nil then
		return
	end
	local id = (openModel :: Instance):GetAttribute("BagId")
	if typeof(id) == "string" then
		bagRemote:FireServer("take", id, selection)
	end
end)
cancel.Activated:Connect(close)
UserInputService.InputBegan:Connect(function(input)
	if gui.Enabled and input.KeyCode == Enum.KeyCode.Escape then
		close()
	end
end)

-- the server times the hold; show it and close when it reports back
bagRemote.OnClientEvent:Connect(function(kind: string, a: any, b: any)
	if kind == "hold" and gui.Enabled then
		holding = true
		barTrack.Visible = true
		barFill.Size = UDim2.fromScale(0, 1)
		local seconds = if typeof(a) == "number" then a else 2
		local started = os.clock()
		task.spawn(function()
			while holding and gui.Enabled do
				barFill.Size = UDim2.fromScale(math.clamp((os.clock() - started) / seconds, 0, 1), 1)
				RunService.Heartbeat:Wait()
			end
		end)
		summary.Text = "Hold still..."
		takeButton.TextColor3 = HUD.TEXT_DIM
	elseif kind == "end" then
		holding = false
		barTrack.Visible = false
		if a == true then
			-- success: the server's notification line says what was taken
			gui.Enabled = false
			openModel = nil
		else
			refreshPanel()
			if typeof(b) == "string" then
				summary.Text = b
			end
		end
	end
end)

ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, who: Player)
	if who ~= player or prompt.Name ~= "ChooseGoods" then
		return
	end
	local model = prompt.Parent and prompt.Parent.Parent
	if model and model.Parent == folder then
		open(model)
	end
end)

-- close if the bag disappears or you walk away; keep numbers live while open
folder.ChildRemoved:Connect(function(model)
	if model == openModel then
		close()
	end
end)
RunService.Heartbeat:Connect(function()
	if not (gui.Enabled and openModel) then
		return
	end
	local anchor = (openModel :: Instance):FindFirstChild("PromptAnchor")
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (anchor and anchor:IsA("BasePart") and root and root:IsA("BasePart"))
		or (root.Position - anchor.Position).Magnitude > 9 then
		close()
	end
end)
