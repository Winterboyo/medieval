--!strict
-- Medieval Land - carried bags and the team vault deposit (DESIGN.md "Gather -> carry -> craft or
-- deposit loop"). The rules live in Shared/Cargo, the transfers in CargoStore; this script wires
-- them to players, the match clock and the two vault rooms.
--
-- WHAT THIS OWNS
--   * every player's bag (Player.Cargo), emptied when a match starts and when it returns to lobby.
--   * Workspace.Vaults: one deposit point per castle, at the vault room's interaction spot from
--     layout.json (keep.stockpile_room.interaction; DESIGN.md keeps that room's geometry for the
--     vault). Two prompts: "Deposit all" (E) and "Choose amounts" (F, opens VaultPanel on the
--     client, which sends its selection back through Remotes.VaultDeposit).
--
-- Only a team's own players can deposit at its vault. Nobody can withdraw, and the enemy cannot
-- take anything out: no code path moves goods out of a vault.
--
-- KNOCKDOWN keeps the bag (DESIGN.md, decided 2026-10-05). The bag is a Player child, not a
-- Character child, so respawning leaves it untouched; nothing here may empty it on death.
--
-- OPEN in DESIGN.md, so deliberately NOT decided here:
--   * OVERLOAD SLOWDOWN. Above Cargo.NORMAL_LOAD the bag publishes Overloaded = true, but no speed
--     change is applied: the amount and its interaction with sprint are open.
--   * DEPOSIT TIMING. Deposits are instant (no hold).
-- PLACEHOLDER: VAULT_RANGE, the deposit prompt's reach.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local GameMode = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameMode"))
if not GameMode.TwoTeam then
	return
end

local Cargo = require(ReplicatedStorage.Shared:WaitForChild("Cargo"))
local CargoStore = require(ServerScriptService:WaitForChild("CargoStore"))
local Layout = require(ServerStorage:WaitForChild("Layout")) :: any

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local notifyRemote = remotes:WaitForChild("Notify") :: RemoteEvent
local depositRemote = remotes:WaitForChild("VaultDeposit") :: RemoteEvent

local VAULT_RANGE = 8 -- studs, placeholder
local KEEP_FLOOR_Y = 11.2 -- the imported Keep's raised floor (CastleInteriors), above layout y 10
local REQUEST_GAP = 0.25 -- seconds between deposit requests from one player

-- ---------------------------------------------------------------- deposit points
local vaultAt: { [string]: Vector3 } = {} -- team id -> interaction point

local function describe(goods: { [string]: number }): string
	local parts = {}
	for _, resource in Cargo.ORDER do
		local n = goods[resource]
		if n and n > 0 then
			table.insert(parts, ("%d %s"):format(n, Cargo.LABEL[resource]))
		end
	end
	return table.concat(parts, ", ")
end

local function nearOwnVault(player: Player, teamId: string): (boolean, string?)
	local team = player.Team
	if not team or team:GetAttribute("TeamId") ~= teamId then
		return false, "This is the enemy vault"
	end
	local at = vaultAt[teamId]
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not (at and root and root:IsA("BasePart") and humanoid and humanoid.Health > 0) then
		return false, nil
	end
	-- a little slack over the prompt's reach for latency
	if (root.Position - at).Magnitude > VAULT_RANGE + 4 then
		return false, "Too far from the vault"
	end
	return true, nil
end

local lastRequest: { [Player]: number } = {}

local function tryDeposit(player: Player, teamId: string, selection: any?)
	local now = os.clock()
	if lastRequest[player] and now - lastRequest[player] < REQUEST_GAP then
		return
	end
	lastRequest[player] = now
	local state = Workspace:GetAttribute("MatchState")
	if state ~= nil and state ~= "Running" then
		notifyRemote:FireClient(player, "The vault opens when the match starts")
		return
	end
	local ok, why = nearOwnVault(player, teamId)
	if not ok then
		if why then
			notifyRemote:FireClient(player, why)
		end
		return
	end
	local credited, reason = CargoStore.deposit(player, selection)
	if credited then
		notifyRemote:FireClient(player, "Deposited " .. describe(credited))
	elseif reason then
		notifyRemote:FireClient(player, "Nothing deposited: " .. reason)
	end
end

local function buildVaults()
	local folder = Workspace:FindFirstChild("Vaults")
	if folder then
		folder:Destroy()
	end
	folder = Instance.new("Folder")
	folder.Name = "Vaults"
	for _, castle in Layout.castles do
		local spot = castle.interior and castle.interior.keep.stockpile_room.interaction
		if spot then
			local teamId = castle.team :: string
			local at = Vector3.new(spot.x, KEEP_FLOOR_Y, spot.z)
			vaultAt[teamId] = at

			local p = Instance.new("Part")
			p.Name = teamId .. "_VaultDeposit"
			p.Anchored = true
			p.CanCollide = false
			p.CanTouch = false
			p.CanQuery = false
			p.Transparency = 1
			p.Size = Vector3.new(2, 2, 2)
			p.Position = at + Vector3.new(0, 2.5, 0)
			p:SetAttribute("TeamId", teamId)

			for _, spec in {
				{ name = "DepositAll", action = "Deposit all", key = Enum.KeyCode.E, gamepad = Enum.KeyCode.ButtonX },
				{ name = "ChooseAmounts", action = "Choose amounts", key = Enum.KeyCode.F, gamepad = Enum.KeyCode.ButtonY },
			} do
				local prompt = Instance.new("ProximityPrompt")
				prompt.Name = spec.name
				prompt.ObjectText = "Vault"
				prompt.ActionText = spec.action
				prompt.KeyboardKeyCode = spec.key
				prompt.GamepadKeyCode = spec.gamepad
				prompt.HoldDuration = 0
				prompt.MaxActivationDistance = VAULT_RANGE
				prompt.RequiresLineOfSight = false
				prompt.Parent = p
				if spec.name == "DepositAll" then
					prompt.Triggered:Connect(function(player)
						tryDeposit(player, teamId, nil)
					end)
				else
					-- the client opens its panel only at its own vault; say why nothing happens here
					prompt.Triggered:Connect(function(player)
						if not player.Team or player.Team:GetAttribute("TeamId") ~= teamId then
							notifyRemote:FireClient(player, "This is the enemy vault")
						end
					end)
				end
			end
			p.Parent = folder
		end
	end
	folder.Parent = Workspace
end

-- "Choose amounts": the client panel sends (teamId, { [good] = count }). Every field is checked
-- here and in CargoStore; nothing from the client is trusted.
depositRemote.OnServerEvent:Connect(function(player: Player, teamId: any, selection: any)
	if typeof(teamId) ~= "string" or vaultAt[teamId] == nil then
		return
	end
	if selection == nil then
		return -- the panel always sends a table; "Deposit all" goes through its own prompt
	end
	tryDeposit(player, teamId, selection)
end)

-- ---------------------------------------------------------------- players and match
for _, player in Players:GetPlayers() do
	CargoStore.bag(player)
end
Players.PlayerAdded:Connect(function(player)
	CargoStore.bag(player)
end)
Players.PlayerRemoving:Connect(function(player)
	lastRequest[player] = nil
end)

-- Give each vault a counter for every carriable good up front (CastleService's older list lacks
-- Smelted Iron), so readers see the full set before the first deposit.
local Teams = game:GetService("Teams")
local function prepareVault(team: Instance)
	if team:IsA("Team") then
		if team:FindFirstChild("Goods") then
			CargoStore.vault(team)
		end
		team.ChildAdded:Connect(function(child)
			if child.Name == "Goods" then
				CargoStore.vault(team)
			end
		end)
	end
end
for _, team in Teams:GetChildren() do
	prepareVault(team)
end
Teams.ChildAdded:Connect(prepareVault)

-- Players start every match with no carried materials (DESIGN.md "starting and respawn
-- equipment"); CastleService empties the vaults at the same moment.
local lastState = Workspace:GetAttribute("MatchState")
Workspace:GetAttributeChangedSignal("MatchState"):Connect(function()
	local now = Workspace:GetAttribute("MatchState")
	if (now == "Running" and lastState ~= "Running") or now == "Lobby" then
		CargoStore.emptyAll()
	end
	lastState = now
end)

buildVaults()
