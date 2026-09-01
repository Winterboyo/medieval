--!strict
-- Medieval Land - Tier 3 per-player notices.
-- Runs in StarterPlayerScripts, one copy per player.
--
-- This exists because of a bug that only appears once there are two people in
-- the world. The wall's ProximityPrompt used to say "Need 10 Stone" by writing
-- its own ActionText, which is ONE property on ONE instance that every player
-- sees. A broke player standing at the wall changed the label for everyone,
-- including someone who could afford it.
--
-- Shared world state belongs on the shared instance - the wall's "Wall 6/24"
-- count is genuinely the same for everybody and still lives on the prompt.
-- Anything that is true of one player and not another has to be sent to that
-- player, which is what the Notify RemoteEvent is for.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local NOTICE_TIME = 2.2
local FADE = TweenInfo.new(0.18, Enum.EasingStyle.Quad)

local notify = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Notify")
local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

local screen = Instance.new("ScreenGui")
screen.Name = "Notices"
screen.ResetOnSpawn = false -- a notice should survive respawning mid-message
screen.IgnoreGuiInset = true
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.Parent = playerGui

local label = Instance.new("TextLabel")
label.Name = "Notice"
label.AnchorPoint = Vector2.new(0.5, 1)
label.Position = UDim2.new(0.5, 0, 0.82, 0)
label.Size = UDim2.fromOffset(0, 34)
label.AutomaticSize = Enum.AutomaticSize.X
label.BackgroundColor3 = Color3.fromRGB(24, 24, 26)
label.BackgroundTransparency = 1
label.TextColor3 = Color3.fromRGB(240, 238, 232)
label.TextTransparency = 1
label.Font = Enum.Font.GothamMedium
label.TextSize = 16
label.Text = ""
label.Parent = screen

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 6)
corner.Parent = label

local padding = Instance.new("UIPadding")
padding.PaddingLeft = UDim.new(0, 14)
padding.PaddingRight = UDim.new(0, 14)
padding.Parent = label

local hideAt = 0

notify.OnClientEvent:Connect(function(text: unknown)
	-- The server is the only thing that should ever fire this, but a client
	-- reading its own remotes is not a reason to trust the payload's shape.
	if type(text) ~= "string" or text == "" then
		return
	end

	label.Text = text
	TweenService:Create(label, FADE, {
		TextTransparency = 0,
		BackgroundTransparency = 0.25,
	}):Play()
	hideAt = os.clock() + NOTICE_TIME
end)

-- One timer rather than one per message: a burst of notices should push the
-- deadline out, not start several fades fighting each other.
task.spawn(function()
	while true do
		task.wait(0.1)
		if hideAt > 0 and os.clock() >= hideAt then
			hideAt = 0
			TweenService:Create(label, FADE, {
				TextTransparency = 1,
				BackgroundTransparency = 1,
			}):Play()
		end
	end
end)
