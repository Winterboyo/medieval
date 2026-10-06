--!strict
-- Medieval Land - Crossbow input (DESIGN.md "Controls", decided 2026-10-05): with the Crossbow
-- equipped, left click fires and R reloads. The server (CrossbowService) owns bolts, reload and
-- hits; this only sends the two requests and turns the character toward the shot.
--
-- PLACEHOLDER: mobile/gamepad mappings are open in DESIGN.md. Tapping fires through the Tool's
-- normal activation, and ContextActionService adds an on-screen Reload button on touch screens.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")

if not require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameMode")).TwoTeam then
	return
end

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local fireRemote = remotes:WaitForChild("CrossbowFire") :: RemoteEvent
local reloadRemote = remotes:WaitForChild("CrossbowReload") :: RemoteEvent

local TOOL_NAME = "Crossbow"
local RELOAD_ACTION = "CrossbowReload"
local AIM_RANGE = 1000

local player = Players.LocalPlayer

-- The world point under the cursor (or the last touch), ignoring your own character.
local function aimPoint(character: Model): Vector3
	local camera = workspace.CurrentCamera
	local screen = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(screen.X, screen.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	local hit = workspace:Raycast(ray.Origin, ray.Direction * AIM_RANGE, params)
	return if hit then hit.Position else ray.Origin + ray.Direction * AIM_RANGE
end

-- Face the shot so the bolt leaves the way the crossbow points (yaw only).
local function faceToward(character: Model, point: Vector3)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return
	end
	local flat = Vector3.new(point.X, root.Position.Y, point.Z)
	if (flat - root.Position).Magnitude > 0.5 then
		root.CFrame = CFrame.lookAt(root.Position, flat)
	end
end

local function onReload(_: string, state: Enum.UserInputState)
	if state == Enum.UserInputState.Begin then
		reloadRemote:FireServer()
	end
	return Enum.ContextActionResult.Sink
end

local bound: { [Tool]: boolean } = {}

local function bindTool(tool: Tool)
	if bound[tool] then
		return
	end
	bound[tool] = true
	tool.Equipped:Connect(function()
		ContextActionService:BindAction(RELOAD_ACTION, onReload, true, Enum.KeyCode.R)
		ContextActionService:SetTitle(RELOAD_ACTION, "Reload")
	end)
	tool.Unequipped:Connect(function()
		ContextActionService:UnbindAction(RELOAD_ACTION)
	end)
	tool.Activated:Connect(function()
		local character = player.Character
		if not character then
			return
		end
		local point = aimPoint(character)
		faceToward(character, point)
		fireRemote:FireServer(point)
	end)
	tool.Destroying:Connect(function()
		bound[tool] = nil
	end)
end

local function watch(container: Instance)
	for _, child in container:GetChildren() do
		if child:IsA("Tool") and child.Name == TOOL_NAME then
			bindTool(child)
		end
	end
	container.ChildAdded:Connect(function(child)
		if child:IsA("Tool") and child.Name == TOOL_NAME then
			bindTool(child)
		end
	end)
end

local function onCharacter(character: Model)
	ContextActionService:UnbindAction(RELOAD_ACTION)
	watch(character)
end

watch(player:WaitForChild("Backpack"))
player.ChildAdded:Connect(function(child)
	if child:IsA("Backpack") then
		watch(child)
	end
end)
if player.Character then
	onCharacter(player.Character)
end
player.CharacterAdded:Connect(onCharacter)
