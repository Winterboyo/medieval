--!strict
-- Medieval Land - the Crossbow: reload, fire, bolt flight and hits (DESIGN.md "Fletcher" and
-- "Controls"). The Tool itself is the ServerStorage.Crossbow template built in Studio; this script
-- only gives it behaviour. CrossbowInput (client) sends the two requests.
--
-- DECIDED (2026-10-05): left click fires, R reloads, each shot consumes one carried Crossbow Bolt.
-- DECIDED: carry limit 16 bolts; no friendly fire; players start a match with no ammunition.
--
-- STATE IS ON INSTANCES, so the HUD can read it without a remote:
--   Player.CrossbowBolts  bolts carried, not counting one already loaded (0..MAX_BOLTS)
--   Tool.Loaded           a bolt sits on the string, ready to fire
--   Tool.Reloading        a reload is in progress
-- Reloading takes the bolt from the pouch when the reload COMPLETES; an interrupted reload
-- (unequip, knockdown) costs nothing. Firing releases the loaded bolt.
--
-- NOT DECIDED, so NOT BUILT HERE:
--   * Structure damage. Bolts should hurt the vault and (inefficiently) walls, but no v2.2
--     structure HP exists yet; a bolt that hits a structure just sticks in it.
--   * How bolts are obtained. Fletcher crafting does not exist yet; nothing grants bolts.
--   * Mobile/gamepad mappings (open). The client adds a placeholder touch button for reload.
-- PLACEHOLDERS: BOLT_DAMAGE (DESIGN: ~1.5-2x a Bow hit; the Bow is not built), RELOAD_TIME
-- (DESIGN: slower than the Bow), and the flight numbers.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

local GameMode = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameMode"))
if not GameMode.TwoTeam then
	return
end

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local notifyRemote = remotes:WaitForChild("Notify") :: RemoteEvent
local fireRemote = remotes:WaitForChild("CrossbowFire") :: RemoteEvent
local reloadRemote = remotes:WaitForChild("CrossbowReload") :: RemoteEvent

local TOOL_NAME = "Crossbow"
local MAX_BOLTS = 16 -- decided carry limit

local BOLT_DAMAGE = 35 -- placeholder: three hits from full health against the sword's 24 base
local RELOAD_TIME = 2.2 -- placeholder, seconds
local BOLT_SPEED = 220 -- placeholder, studs per second
local BOLT_GRAVITY = 0.15 -- placeholder, fraction of Workspace.Gravity: a slight drop over range
local BOLT_LIFETIME = 2.0 -- seconds of flight before the bolt is gone (~440 studs)
local STUCK_SECONDS = 4 -- a landed bolt stays visible this long

local BOLT_COLOUR = Color3.fromRGB(83, 56, 50) -- the crossbow's stock wood

-- ---------------------------------------------------------------- helpers
local function notify(player: Player, text: string)
	notifyRemote:FireClient(player, text)
end

local function bolts(player: Player): number
	local n = player:GetAttribute("CrossbowBolts")
	return if typeof(n) == "number" then n else 0
end

local function setBolts(player: Player, n: number)
	player:SetAttribute("CrossbowBolts", math.clamp(math.floor(n), 0, MAX_BOLTS))
end

local function matchRunning(): boolean
	return Workspace:GetAttribute("MatchState") == "Running"
end

-- The crossbow the player is holding right now, if they are alive and holding one.
local function heldCrossbow(player: Player): (Tool?, Model?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not (character and humanoid and humanoid.Health > 0) then
		return nil, nil
	end
	local tool = character:FindFirstChild(TOOL_NAME)
	if tool and tool:IsA("Tool") then
		return tool, character
	end
	return nil, nil
end

local function isFiniteVector(v: any): boolean
	return typeof(v) == "Vector3" and v == v and math.abs(v.X) < 1e6 and math.abs(v.Y) < 1e6 and math.abs(v.Z) < 1e6
end

-- ---------------------------------------------------------------- reload
local reloadToken: { [Tool]: number } = {}

local function cancelReload(tool: Tool)
	if tool:GetAttribute("Reloading") then
		tool:SetAttribute("Reloading", false)
	end
	reloadToken[tool] = (reloadToken[tool] or 0) + 1
end

local function watchTool(tool: Tool)
	if reloadToken[tool] then
		return
	end
	reloadToken[tool] = 0
	tool:SetAttribute("Loaded", tool:GetAttribute("Loaded") == true)
	tool:SetAttribute("Reloading", false)
	-- leaving the hand (holstered, dropped, character gone) interrupts a reload
	tool.AncestryChanged:Connect(function()
		local parent = tool.Parent
		if not (parent and parent:IsA("Model") and parent:FindFirstChildOfClass("Humanoid")) then
			cancelReload(tool)
		end
	end)
	tool.Destroying:Connect(function()
		reloadToken[tool] = nil
	end)
end

reloadRemote.OnServerEvent:Connect(function(player: Player)
	local tool, character = heldCrossbow(player)
	if not (tool and character) then
		return
	end
	watchTool(tool)
	if tool:GetAttribute("Loaded") then
		notify(player, "Already loaded")
		return
	end
	if tool:GetAttribute("Reloading") then
		return
	end
	if bolts(player) <= 0 then
		notify(player, "No crossbow bolts")
		return
	end

	tool:SetAttribute("Reloading", true)
	reloadToken[tool] += 1
	local token = reloadToken[tool]
	local humanoid = character:FindFirstChildOfClass("Humanoid")

	task.delay(RELOAD_TIME, function()
		if reloadToken[tool] ~= token or not tool:GetAttribute("Reloading") then
			return -- interrupted
		end
		tool:SetAttribute("Reloading", false)
		if tool.Parent ~= character or not humanoid or humanoid.Health <= 0 or player.Character ~= character then
			return
		end
		if bolts(player) <= 0 then
			return
		end
		setBolts(player, bolts(player) - 1)
		tool:SetAttribute("Loaded", true)
	end)
end)

-- ---------------------------------------------------------------- bolt flight
local function makeBolt(at: CFrame): BasePart
	local bolt = Instance.new("Part")
	bolt.Name = "CrossbowBolt"
	bolt.Size = Vector3.new(0.12, 0.12, 1.4)
	bolt.Color = BOLT_COLOUR
	bolt.Material = Enum.Material.Wood
	bolt.Anchored = true
	bolt.CanCollide = false
	bolt.CanQuery = false
	bolt.CanTouch = false
	bolt.CastShadow = false
	bolt.CFrame = at
	bolt.Parent = Workspace
	return bolt
end

local function hitPerson(shooter: Player, instance: Instance): boolean
	local model = instance:FindFirstAncestorOfClass("Model")
	local humanoid = model and model:FindFirstChildOfClass("Humanoid")
	if not (model and humanoid) then
		return false
	end
	local victim = Players:GetPlayerFromCharacter(model)
	if not victim or victim == shooter or humanoid.Health <= 0 then
		return true -- a body (or a dead one) still stops the bolt
	end
	if victim.Team ~= nil and victim.Team == shooter.Team then
		return true -- no friendly fire; the teammate still blocks the shot
	end
	if not matchRunning() then
		return true
	end
	humanoid:TakeDamage(BOLT_DAMAGE)
	local killed = humanoid.Health <= 0
	notify(shooter, if killed then ("You killed %s"):format(victim.Name) else ("Hit %s"):format(victim.Name))
	notify(victim, if killed then ("%s killed you"):format(shooter.Name) else ("%s shot you"):format(shooter.Name))
	return true
end

local function launch(shooter: Player, character: Model, origin: Vector3, direction: Vector3)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }

	local position = origin
	local velocity = direction * BOLT_SPEED
	local bolt = makeBolt(CFrame.lookAt(position, position + velocity))
	local age = 0
	local connection: RBXScriptConnection
	connection = RunService.Heartbeat:Connect(function(dt)
		age += dt
		local nextVelocity = velocity - Vector3.new(0, Workspace.Gravity * BOLT_GRAVITY * dt, 0)
		local step = (velocity + nextVelocity) * 0.5 * dt
		local hit = Workspace:Raycast(position, step, params)
		if hit then
			connection:Disconnect()
			hitPerson(shooter, hit.Instance)
			-- stick, nose a little into whatever it struck
			bolt.CFrame = CFrame.lookAt(hit.Position - step.Unit * 0.5, hit.Position + step.Unit)
			Debris:AddItem(bolt, STUCK_SECONDS)
			return
		end
		position += step
		velocity = nextVelocity
		bolt.CFrame = CFrame.lookAt(position, position + velocity)
		if age >= BOLT_LIFETIME then
			connection:Disconnect()
			bolt:Destroy()
		end
	end)
end

-- The client sends where it is aiming (a world point under the cursor). Everything else is
-- decided here: the bolt leaves from the shooter's head, so a client cannot fire from elsewhere.
fireRemote.OnServerEvent:Connect(function(player: Player, aim: any)
	if not isFiniteVector(aim) then
		return
	end
	local tool, character = heldCrossbow(player)
	if not (tool and character) then
		return
	end
	watchTool(tool)
	if tool:GetAttribute("Reloading") then
		return
	end
	if not tool:GetAttribute("Loaded") then
		notify(player, if bolts(player) > 0 then "Press R to reload" else "No crossbow bolts")
		return
	end
	local head = character:FindFirstChild("Head")
	if not (head and head:IsA("BasePart")) then
		return
	end
	local offset = (aim :: Vector3) - head.Position
	if offset.Magnitude < 1 then
		return
	end
	tool:SetAttribute("Loaded", false)
	local direction = offset.Unit
	launch(player, character, head.Position + direction * 1.5, direction)
end)

-- ---------------------------------------------------------------- players and match
local function prepare(player: Player)
	if player:GetAttribute("CrossbowBolts") == nil then
		setBolts(player, 0)
	end
end
for _, player in Players:GetPlayers() do
	prepare(player)
end
Players.PlayerAdded:Connect(prepare)

-- Players start every match with no ammunition (DESIGN.md "starting and respawn equipment").
local lastState = Workspace:GetAttribute("MatchState")
Workspace:GetAttributeChangedSignal("MatchState"):Connect(function()
	local now = Workspace:GetAttribute("MatchState")
	if (now == "Running" and lastState ~= "Running") or now == "Lobby" then
		for _, player in Players:GetPlayers() do
			setBolts(player, 0)
		end
	end
	lastState = now
end)
