--!strict
-- Medieval Land - the vault's "Choose amounts" panel (DESIGN.md: Deposit all, or choose goods and
-- amounts). Opens from the ChooseAmounts prompt at your own team's vault, lets you pick how much of
-- each carried good to deposit, and sends that selection to the server, which re-checks all of it
-- (CargoService / CargoStore). Unselected goods stay in your bag for personal crafting.
--
-- Functional first pass in the HUD's colours (Palette.HUD); styling is open to rework.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ProximityPromptService = game:GetService("ProximityPromptService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
if not require(Shared:WaitForChild("GameMode")).TwoTeam then
	return
end
local Cargo = require(Shared:WaitForChild("Cargo"))
local Palette = require(Shared:WaitForChild("Palette"))
local HUD = Palette.HUD

local depositRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("VaultDeposit") :: RemoteEvent
local player = Players.LocalPlayer

local CLOSE_DISTANCE = 14 -- walk this far from the vault and the panel closes
local ROW_H = 34
local WIDTH = 400
local HEADER = 50 -- title, then the column hint on its own line

-- ---------------------------------------------------------------- building blocks
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

-- ---------------------------------------------------------------- the panel
local gui = Instance.new("ScreenGui")
gui.Name = "VaultPanel"
gui.ResetOnSpawn = false
gui.DisplayOrder = 5
gui.Enabled = false
gui.Parent = player:WaitForChild("PlayerGui")

local height = HEADER + 4 + #Cargo.ORDER * ROW_H + 70
local panel = frame(gui, "Panel", UDim2.fromOffset(WIDTH, height), UDim2.fromScale(0.5, 0.5), HUD.PANEL, 0.08)
panel.AnchorPoint = Vector2.new(0.5, 0.5)
local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, HUD.CORNER)
corner.Parent = panel
local edge = Instance.new("UIStroke")
edge.Color = HUD.EDGE
edge.Transparency = HUD.EDGE_ALPHA
edge.Parent = panel
-- shrink to fit small screens
local scale = Instance.new("UIScale")
scale.Parent = panel
local function fit()
	local camera = workspace.CurrentCamera
	local view = camera and camera.ViewportSize or Vector2.new(1280, 720)
	scale.Scale = math.min(1, (view.Y - 40) / height, (view.X - 32) / WIDTH)
end
fit()

local title = label(panel, "Title", "Deposit to vault", UDim2.new(1, -24, 0, 24), UDim2.fromOffset(12, 10))
title.Font = Palette.FONT_HEADING
title.TextSize = 18
local hint = label(panel, "Hint", "carried", UDim2.fromOffset(60, 16), UDim2.new(1, -264, 0, HEADER - 18), Enum.TextXAlignment.Right) -- over the rows' carried column
hint.TextColor3 = HUD.TEXT_DIM
hint.TextSize = 13

local amounts: { [string]: number } = {}
type Row = { carried: TextLabel, amount: TextLabel }
local rows: { [string]: Row } = {}
local openTeam: string? = nil
local openPart: BasePart? = nil

local function carried(): { [string]: number }
	local bag = player:FindFirstChild("Cargo")
	local held = {}
	for _, resource in Cargo.ORDER do
		local v = bag and bag:FindFirstChild(resource)
		held[resource] = if v and v:IsA("IntValue") then v.Value else 0
	end
	return held
end

local summary: TextLabel
local depositButton: TextButton

local function refresh()
	local held = carried()
	local chosen = {}
	for _, resource in Cargo.ORDER do
		amounts[resource] = math.clamp(amounts[resource] or 0, 0, held[resource])
		chosen[resource] = amounts[resource]
		local row = rows[resource]
		row.carried.Text = tostring(held[resource])
		row.carried.TextColor3 = if held[resource] > 0 then HUD.TEXT else HUD.TEXT_DIM
		row.amount.Text = tostring(amounts[resource])
		row.amount.TextColor3 = if amounts[resource] > 0 then HUD.ACCENT else HUD.TEXT_DIM
	end
	local moving = Cargo.loadOf(chosen)
	summary.Text = ("Depositing %d of %d load"):format(moving, Cargo.loadOf(held))
	depositButton.AutoButtonColor = moving > 0
	depositButton.TextColor3 = if moving > 0 then HUD.TEXT else HUD.TEXT_DIM
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
	local held = label(row, "Carried", "0", UDim2.fromOffset(40, ROW_H - 4), UDim2.new(1, -232, 0, 0), Enum.TextXAlignment.Right)
	local minus = button(row, "Less", "-", UDim2.fromOffset(28, 24), UDim2.new(1, -180, 0.5, -12))
	local amount = label(row, "Amount", "0", UDim2.fromOffset(36, ROW_H - 4), UDim2.new(1, -150, 0, 0), Enum.TextXAlignment.Center)
	local plus = button(row, "More", "+", UDim2.fromOffset(28, 24), UDim2.new(1, -112, 0.5, -12))
	local all = button(row, "All", "All", UDim2.fromOffset(44, 24), UDim2.new(1, -76, 0.5, -12))
	local none = button(row, "None", "0", UDim2.fromOffset(24, 24), UDim2.new(1, -28, 0.5, -12))
	rows[resource] = { carried = held, amount = amount }
	minus.Activated:Connect(function()
		amounts[resource] = (amounts[resource] or 0) - 1
		refresh()
	end)
	plus.Activated:Connect(function()
		amounts[resource] = (amounts[resource] or 0) + 1
		refresh()
	end)
	all.Activated:Connect(function()
		amounts[resource] = carried()[resource]
		refresh()
	end)
	none.Activated:Connect(function()
		amounts[resource] = 0
		refresh()
	end)
end

local footY = HEADER + 4 + #Cargo.ORDER * ROW_H
summary = label(panel, "Summary", "", UDim2.new(1, -24, 0, 20), UDim2.fromOffset(12, footY))
summary.TextColor3 = HUD.TEXT_DIM
summary.TextSize = 14
depositButton = button(panel, "Deposit", "Deposit", UDim2.fromOffset(150, 32), UDim2.new(1, -312, 0, footY + 26))
depositButton.BackgroundColor3 = HUD.ACCENT
depositButton.BackgroundTransparency = 0.35
local cancel = button(panel, "Cancel", "Cancel", UDim2.fromOffset(150, 32), UDim2.new(1, -162, 0, footY + 26))

-- ---------------------------------------------------------------- open, send, close
local function close()
	gui.Enabled = false
	openTeam = nil
	openPart = nil
end

local function open(part: BasePart, teamId: string)
	openTeam = teamId
	openPart = part
	for _, resource in Cargo.ORDER do
		amounts[resource] = 0
	end
	fit()
	refresh()
	gui.Enabled = true
end

depositButton.Activated:Connect(function()
	if not openTeam then
		return
	end
	local selection = {}
	local any = false
	for _, resource in Cargo.ORDER do
		if (amounts[resource] or 0) > 0 then
			selection[resource] = amounts[resource]
			any = true
		end
	end
	if any then
		depositRemote:FireServer(openTeam, selection)
		close()
	end
end)
cancel.Activated:Connect(close)
UserInputService.InputBegan:Connect(function(input)
	if gui.Enabled and input.KeyCode == Enum.KeyCode.Escape then
		close()
	end
end)

ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, who: Player)
	if who ~= player or prompt.Name ~= "ChooseAmounts" then
		return
	end
	local part = prompt.Parent
	local teamId = part and part:GetAttribute("TeamId")
	if not (part and part:IsA("BasePart") and typeof(teamId) == "string") then
		return
	end
	if not player.Team or player.Team:GetAttribute("TeamId") ~= teamId then
		return -- the enemy's vault: the server says so
	end
	open(part, teamId)
end)

-- keep the numbers live while open (gathering elsewhere cannot happen, but a reset can)
local function watchBag(bag: Instance)
	for _, v in bag:GetChildren() do
		if v:IsA("IntValue") then
			v.Changed:Connect(function()
				if gui.Enabled then
					refresh()
				end
			end)
		end
	end
end
local bag = player:FindFirstChild("Cargo")
if bag then
	watchBag(bag)
end
player.ChildAdded:Connect(function(child)
	if child.Name == "Cargo" then
		watchBag(child)
	end
end)

RunService.Heartbeat:Connect(function()
	if not gui.Enabled then
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (openPart and root and root:IsA("BasePart"))
		or (root.Position - openPart.Position).Magnitude > CLOSE_DISTANCE then
		close()
	end
end)
