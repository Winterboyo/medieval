--!strict
-- Medieval Land - Conquest match lifecycle and the shrinking zone.
-- Lives in ServerScriptService alongside ResourceService.
--
-- DESIGN.md: Conquest is ~12 players, one generated map, one 45-60 minute match,
-- last player/team standing. The playable area shrinks over the timer, which the
-- doc says does two jobs at once - it raises scarcity late without scripted
-- stockpile step-downs, and it forces surviving factions into contact so the
-- match resolves inside the window instead of stalling in mutual turtling.
--
-- This file owns the clock, the boundary, and from Stage 3 the squads and the
-- win condition. It still does NOT own bases or nodes, and it still talks to
-- ResourceService through attributes published on instances rather than a shared
-- module.
--
--   Workspace.MatchState   "Lobby" | "Running" | "Ended"
--   Workspace.MatchClock   seconds left in the current phase
--   Workspace.ZoneHalf     half-extent of the playable square, in studs
--   Player.Eliminated      their keep fell; they are somebody's worker now
--   Player.Squad           which squad they belong to
--
-- ResourceService reads ZoneHalf to stop nodes outside the boundary yielding.
--
-- Elimination needs NO change in ResourceService. It already publishes Fallen on
-- a base the moment its keep is razed, and it already publishes Owner, so this
-- file can watch that one attribute and resolve the rest. The cheapest seam is
-- the one that already exists.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Teams = game:GetService("Teams")

local FoldWeighting = require(ServerScriptService:WaitForChild("FoldWeighting"))

local notifyRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Notify")

-- CLAUDE.md §3/§4: TwoTeam is the game; the squads, the fold and the shrinking zone
-- below are the old free-for-all and stay dormant behind this flag.
local TWO_TEAM = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameMode")).TwoTeam

local LOBBY_SECONDS = 15
-- TwoTeam: a short match with a hard cap (CLAUDE.md §5 placeholder 12-15 min),
-- then a short Ended phase and back to the lobby. Conquest kept its 45 minutes
-- and never came back from Ended; that is part of what stays dormant.
local TWO_TEAM_MATCH_LENGTH = 13 * 60
local ENDED_SECONDS = 12

-- The doc says 45-60 minutes. Overridable by a Workspace attribute set before
-- the server starts, because nobody - including a playtest - wants to sit
-- through three quarters of an hour to find out whether the timer fires.
local DEFAULT_MATCH_LENGTH = 45 * 60

-- The board is a square grid centred on the origin and dead flat, so the
-- boundary is one number rather than a shape.
--
-- The starting extent is READ FROM THE BOARD (build-world publishes BoardHalf)
-- instead of being restated here. It had already drifted twice as a constant -
-- 252 was right for 72 stud tiles, 560 for 160 - and when the tiles grew to 200
-- nobody updated it, so the outer ring of tiles sat outside the boundary from
-- the first second and roughly half the map's nodes never yielded.
--
-- The fallback matches the current board (7 x 200), and follows the same rule as
-- zoneHalf() in ResourceService: a service that has not spoken yet must not
-- shrink the world to nothing.
local FALLBACK_BOARD_HALF = 700

local function boardHalf(): number
	local value = Workspace:GetAttribute("BoardHalf")
	return if typeof(value) == "number" and value > 0 then value else FALLBACK_BOARD_HALF
end

-- The final ring is deliberately wide enough to hold a village or two: closing
-- onto something smaller than a single compound would decide the match by whose
-- walls happened to sit nearest the middle.
local ZONE_FINAL_HALF = 130 -- closes onto the totem at the centre
local ZONE_GRACE = 0.20 -- fraction of the match before it starts closing
local ZONE_CLOSED_BY = 0.90 -- fraction by which it has finished closing

local ZONE_TICK = 1
local ZONE_DAMAGE = 4 -- per tick outside; a push, not an execution
local ZONE_WALL_HEIGHT = 70

local state = "Lobby"
local phaseEndsAt = 0
local matchLength = DEFAULT_MATCH_LENGTH
local zoneHalf = boardHalf()

-- ---------------------------------------------------------------- announcing
local function announce(text: string)
	for _, player in Players:GetPlayers() do
		notifyRemote:FireClient(player, text)
	end
end

-- ---------------------------------------------------------------- the boundary
-- Four slabs rather than one hollow shape: a player has to be able to SEE where
-- the edge is, and a boundary you only discover by taking damage is a bug
-- disguised as a mechanic.
local zoneFolder = Workspace:FindFirstChild("MatchZone")
if zoneFolder then
	zoneFolder:Destroy()
end
zoneFolder = Instance.new("Folder")
zoneFolder.Name = "MatchZone"
zoneFolder.Parent = Workspace

-- A RING, not four slabs. The world used to be a square board and the boundary
-- squared off to match; it is an island now, so a square boundary would cut the
-- coast at four arbitrary places and leave corners of open sea inside the
-- "safe" area. Enough segments that the curve reads as a curve.
local ZONE_SEGMENTS = 48

local zoneWalls: { BasePart } = {}
for i = 1, ZONE_SEGMENTS do
	local wall = Instance.new("Part")
	wall.Name = ("ZoneWall%02d"):format(i)
	wall.Anchored = true
	wall.CanCollide = false -- it pushes with damage, not with collision
	wall.CanQuery = false
	wall.CanTouch = false
	wall.Material = Enum.Material.Neon
	wall.Color = Color3.fromRGB(214, 132, 96)
	wall.Transparency = 0.72
	wall.Size = Vector3.new(1, ZONE_WALL_HEIGHT, 1)
	wall.Parent = zoneFolder
	table.insert(zoneWalls, wall)
end

local function drawZone(half: number)
	-- Each segment is a chord of the circle, turned to face the centre and made
	-- a little wider than the exact arc so neighbours overlap and the ring has
	-- no gaps to walk through.
	local chord = (2 * math.pi * math.max(half, 1)) / ZONE_SEGMENTS * 1.08
	local y = ZONE_WALL_HEIGHT / 2 - 6
	for index, wall in zoneWalls do
		local angle = (index - 1) / ZONE_SEGMENTS * math.pi * 2
		wall.Size = Vector3.new(chord, ZONE_WALL_HEIGHT, 1.5)
		wall.CFrame = CFrame.new(math.cos(angle) * half, y, math.sin(angle) * half)
			* CFrame.Angles(0, -angle + math.pi / 2, 0)
	end
end

local function setZoneVisible(visible: boolean)
	for _, wall in zoneWalls do
		wall.Transparency = if visible then 0.72 else 1
	end
end

-- Hold at full size through the grace period, close linearly, then hold at the
-- final size. A boundary that starts closing on the first second gives nobody
-- time to establish, and one still closing at the whistle never forces contact.
local function zoneHalfAt(progress: number): number
	if progress <= ZONE_GRACE then
		return boardHalf()
	end
	if progress >= ZONE_CLOSED_BY then
		return ZONE_FINAL_HALF
	end
	local through = (progress - ZONE_GRACE) / (ZONE_CLOSED_BY - ZONE_GRACE)
	local start = boardHalf()
	return start + (ZONE_FINAL_HALF - start) * through
end

-- The zone is a square centred on the origin, so "outside" is the larger of the
-- two axis distances rather than a radius.
-- Radial now. The island has no corners, so neither does the boundary.
local function outsideBy(position: Vector3, half: number): number
	local flat = Vector3.new(position.X, 0, position.Z)
	return math.max(0, flat.Magnitude - half)
end

-- ---------------------------------------------------------------- publishing
local function publish()
	Workspace:SetAttribute("MatchState", state)
	-- Never publish infinity: Conquest's Ended phase lasted math.huge, and the HUD's
	-- "%d" clock cannot format it.
	local left = phaseEndsAt - os.clock()
	Workspace:SetAttribute("MatchClock", if left == left and left < 1e9 then math.max(0, math.floor(left)) else 0)
	-- No zone in TwoTeam (layout.json zone: null). Unset means "no boundary" to
	-- ResourceService's inZone and to the HUD.
	Workspace:SetAttribute("ZoneHalf", if TWO_TEAM then nil else zoneHalf)
end

local function enter(nextState: string, seconds: number)
	state = nextState
	phaseEndsAt = os.clock() + seconds
	publish()
end

-- ---------------------------------------------------------------- the match
-- A short test match announcing "0 minutes" is a small thing that reads as a
-- bug, and the override exists precisely so matches can be short.
local function describeLength(seconds: number): string
	if seconds < 90 then
		return ("%d seconds"):format(math.floor(seconds))
	end
	return ("%d minutes"):format(math.floor(seconds / 60))
end

local function endMatch(reason: string)
	-- the HUD's event feed reads the result from here; set before the state flips to Ended
	Workspace:SetAttribute("MatchResult", reason)
	enter("Ended", if TWO_TEAM then ENDED_SECONDS else math.huge)
	setZoneVisible(false)
	announce(reason)
end

-- ---------------------------------------------------------------- two teams
-- The two Teams are made by CastleService from layout.json and carry TeamId and
-- Castle attributes; this file only assigns people to them and decides results.
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

local function castleOf(team: Team): Instance?
	local castles = Workspace:FindFirstChild("Castles")
	local id = team:GetAttribute("Castle")
	return if castles and typeof(id) == "string" then castles:FindFirstChild(id) else nil
end

local function stockpileOf(team: Team): number
	local total = 0
	local goods = team:FindFirstChild("Goods")
	if goods then
		for _, counter in goods:GetChildren() do
			if counter:IsA("IntValue") then
				total += counter.Value
			end
		end
	end
	return total
end

-- Even sides at the start of every match: shuffle, then deal alternately.
local function balanceTeams()
	local sides = castleTeams()
	if #sides < 2 then
		return
	end
	local everyone = Players:GetPlayers()
	local rng = Random.new()
	for i = #everyone, 2, -1 do
		local j = rng:NextInteger(1, i)
		everyone[i], everyone[j] = everyone[j], everyone[i]
	end
	for index, player in everyone do
		player.Team = sides[((index - 1) % #sides) + 1]
	end
end

-- A castle that falls ends the match for the other side (CLAUDE.md §4). The
-- Fallen attribute is set by whatever runs the siege (Phase 3); this only listens.
local function watchCastles()
	local function hook(castle: Instance)
		castle:GetAttributeChangedSignal("Fallen"):Connect(function()
			if castle:GetAttribute("Fallen") ~= true or state ~= "Running" then
				return
			end
			local loser = castle:GetAttribute("Team")
			for _, team in castleTeams() do
				if team.Name ~= loser then
					endMatch(("%s has fallen. %s takes the field."):format(tostring(loser), team.Name))
					return
				end
			end
			endMatch(("%s has fallen."):format(tostring(loser)))
		end)
	end
	-- Castles are rebuilt whole between matches, so watch the folder, not one set.
	task.spawn(function()
		local folder = Workspace:WaitForChild("Castles")
		local function rewatch(f: Instance)
			for _, castle in f:GetChildren() do
				hook(castle)
			end
			f.ChildAdded:Connect(hook)
		end
		rewatch(folder)
		Workspace.ChildAdded:Connect(function(child)
			if child.Name == "Castles" then
				rewatch(child)
			end
		end)
	end)
end

-- At the cap: highest total structure HP, then the largest stockpile (CLAUDE.md
-- §5, placeholder tiebreaker).
local function endTwoTeamByTimer()
	local sides = castleTeams()
	local function score(team: Team): (number, number)
		local castle = castleOf(team)
		local hp = castle and castle:GetAttribute("StructureHP")
		return (if typeof(hp) == "number" then hp else 0), stockpileOf(team)
	end
	table.sort(sides, function(a, b)
		local ha, sa = score(a)
		local hb, sb = score(b)
		if ha ~= hb then
			return ha > hb
		end
		return sa > sb
	end)
	if #sides < 2 then
		endMatch("Time.")
		return
	end
	local h1, s1 = score(sides[1])
	local h2, s2 = score(sides[2])
	if h1 == h2 and s1 == s2 then
		endMatch("Time. Neither castle gave ground - a draw.")
	elseif h1 ~= h2 then
		endMatch(("Time. %s held more of its castle."):format(sides[1].Name))
	else
		endMatch(("Time. Walls even; %s held the bigger stockpile."):format(sides[1].Name))
	end
end

-- Everyone back to their own barracks at the start of a match.
local function respawnAll()
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			player:LoadCharacter()
		end)
	end
end

-- ---------------------------------------------------------------- squads
-- DESIGN.md wants "last player or team standing", and v1 takes the minimal
-- reading of that: a squad is an ORIGINAL PLAYER plus whoever has been folded
-- into them. There is no alliance system and nothing to agree to - you do not
-- negotiate a team, you acquire one by taking somebody's keep.
--
-- Roblox's Teams service does the grouping, which puts squads in the player list
-- for free. Same reasoning as leaderstats carrying the resource columns.
type Squad = {
	leader: Player,
	members: { Player },
	team: Team,
	out: boolean,
}

local squads: { Squad } = {}
local foldRng = Random.new()

local SQUAD_COLOURS = {
	"Bright red", "Bright blue", "Bright green", "Bright yellow",
	"Bright violet", "Bright orange", "Cyan", "Magenta",
	"Lime green", "Br. yellowish orange", "Teal", "Pink",
}

local function squadLedBy(player: Player): Squad?
	for _, squad in squads do
		if squad.leader == player then
			return squad
		end
	end
	return nil
end

local function livingSquads(): { Squad }
	local alive: { Squad } = {}
	for _, squad in squads do
		if not squad.out then
			alive[#alive + 1] = squad
		end
	end
	return alive
end

local function newSquad(player: Player): Squad
	local team = Instance.new("Team")
	team.Name = player.Name
	team.TeamColor = BrickColor.new(SQUAD_COLOURS[(#squads % #SQUAD_COLOURS) + 1])
	team.AutoAssignable = false
	team.Parent = Teams

	local squad: Squad = { leader = player, members = { player }, team = team, out = false }
	squads[#squads + 1] = squad

	player.Team = team
	player:SetAttribute("Eliminated", false)
	player:SetAttribute("Squad", team.Name)
	return squad
end

local function startSquads()
	for _, squad in squads do
		squad.team:Destroy()
	end
	table.clear(squads)
	for _, player in Players:GetPlayers() do
		newSquad(player)
	end
end

-- How much a squad is actually holding, used only to break a tie at the whistle.
-- Wall plus keep across every base its members own: the closest thing to "who
-- was winning" that does not need a whole scoring system.
local function strengthOf(squad: Squad): number
	local sites = Workspace:FindFirstChild("BuildSites")
	if not sites then
		return 0
	end
	local total = 0
	for _, base in sites:GetChildren() do
		local owner = base:GetAttribute("Owner")
		if typeof(owner) == "number" then
			for _, member in squad.members do
				if member.UserId == owner then
					total += (base:GetAttribute("Wall") or 0) :: number
					total += (base:GetAttribute("KeepHealth") or 0) :: number
				end
			end
		end
	end
	return total
end

local function describeSquad(squad: Squad): string
	if #squad.members <= 1 then
		return squad.leader.Name
	end
	return ("%s and %d in their service"):format(squad.leader.Name, #squad.members - 1)
end

local function resolveWin()
	if state ~= "Running" then
		return
	end
	local alive = livingSquads()
	if #alive > 1 then
		return
	end
	if #alive == 1 then
		endMatch(("%s holds the field. The match is over."):format(describeSquad(alive[1])))
	else
		endMatch("Nobody is left standing. The match is over.")
	end
end

-- A squad falls when its LEADER's keep is razed, and the whole squad falls with
-- it: the squad exists because the leader held a keep, so there is nothing left
-- to belong to once it is gone. Everyone on it - leader and workers alike - is
-- dealt back out to the survivors.
local function eliminate(leader: Player)
	local squad = squadLedBy(leader)
	if not squad or squad.out then
		return
	end
	squad.out = true

	local displaced = table.clone(squad.members)
	table.clear(squad.members)

	-- Their keep is gone whether or not anyone is left to serve, so the flag
	-- goes up before the fold rather than inside it. Otherwise the last squad
	-- standing to fall reads as un-eliminated, which is exactly backwards.
	for _, person in displaced do
		person:SetAttribute("Eliminated", true)
	end

	local hosts = livingSquads()
	if #hosts == 0 then
		announce(("%s has fallen."):format(leader.Name))
		resolveWin()
		return
	end

	for _, person in displaced do
		hosts = livingSquads()
		if #hosts == 0 then
			break
		end
		-- Sizes out, index back. The weighting itself lives in FoldWeighting so
		-- it can be checked without a server full of players.
		local sizes: { number } = {}
		for index, host in hosts do
			sizes[index] = #host.members
		end
		local pick = FoldWeighting.choose(sizes, foldRng:NextNumber())
		local host = if pick then hosts[pick] else nil
		if host then
			host.members[#host.members + 1] = person
			person.Team = host.team
			person:SetAttribute("Squad", host.team.Name)
			notifyRemote:FireClient(person, ("Your keep is gone. You serve %s now."):format(host.leader.Name))
			notifyRemote:FireClient(host.leader, ("%s now works for you"):format(person.Name))
		end
	end

	announce(("%s has fallen."):format(leader.Name))
	resolveWin()
end

-- ResourceService sets Fallen the moment a keep reaches zero. That is the whole
-- hook: no new remote, no new module, no change on the other side.
local function watchForFallenKeeps()
	local sites = Workspace:FindFirstChild("BuildSites")
	if not sites then
		return
	end
	for _, base in sites:GetChildren() do
		base:GetAttributeChangedSignal("Fallen"):Connect(function()
			if base:GetAttribute("Fallen") ~= true or state ~= "Running" then
				return
			end
			local owner = base:GetAttribute("Owner")
			if typeof(owner) ~= "number" then
				return
			end
			local player = Players:GetPlayerByUserId(owner)
			if player then
				eliminate(player)
			end
		end)
	end
end

-- At the whistle the largest surviving squad takes it, because the fold means
-- size IS the record of how many keeps a squad has taken. Ties go to whoever is
-- still holding the most wall and keep.
local function endByTimer()
	local alive = livingSquads()
	if #alive == 0 then
		endMatch("Time. Nobody is left standing.")
		return
	end
	local best = alive[1]
	for _, squad in alive do
		if #squad.members > #best.members
			or (#squad.members == #best.members and strengthOf(squad) > strengthOf(best))
		then
			best = squad
		end
	end
	endMatch(("Time. %s holds the most ground."):format(describeSquad(best)))
end

local function beginMatch()
	if TWO_TEAM then
		matchLength = Workspace:GetAttribute("MatchLength") or TWO_TEAM_MATCH_LENGTH
		balanceTeams()
		enter("Running", matchLength)
		respawnAll()
		announce(("The siege has begun - %s"):format(describeLength(matchLength)))
		return
	end
	matchLength = Workspace:GetAttribute("MatchLength") or DEFAULT_MATCH_LENGTH
	zoneHalf = boardHalf()
	drawZone(zoneHalf)
	setZoneVisible(true)
	startSquads()
	enter("Running", matchLength)
	announce(("The match has begun - %s"):format(describeLength(matchLength)))
end

-- Someone arriving mid-match gets their own squad rather than being dropped into
-- one. Joining should not silently hand an existing player a worker.
-- (TwoTeam needs nothing here: the castle Teams are AutoAssignable, so Roblox puts
-- a mid-match arrival on the shorter side by itself.)
Players.PlayerAdded:Connect(function(player)
	if not TWO_TEAM and state == "Running" and not squadLedBy(player) then
		newSquad(player)
	end
end)

Players.PlayerRemoving:Connect(function(player)
	if TWO_TEAM then
		return
	end
	for _, squad in squads do
		local index = table.find(squad.members, player)
		if index then
			table.remove(squad.members, index)
		end
		-- A squad whose last member has quit is gone, whatever its keep says.
		if not squad.out and #squad.members == 0 then
			squad.out = true
		end
	end
	resolveWin()
end)

if TWO_TEAM then
	watchCastles()
else
	watchForFallenKeeps()
end

task.spawn(function()
	zoneHalf = boardHalf()
	drawZone(zoneHalf)
	setZoneVisible(false)
	enter("Lobby", LOBBY_SECONDS)

	while true do
		task.wait(ZONE_TICK)
		local remaining = phaseEndsAt - os.clock()

		if state == "Lobby" then
			-- One player is enough to start. Conquest wants ~12, but a lobby that
			-- refuses to begin is untestable and unplayable alone.
			if #Players:GetPlayers() == 0 then
				phaseEndsAt = os.clock() + LOBBY_SECONDS
			elseif remaining <= 0 then
				beginMatch()
			end
			publish()

		elseif state == "Running" and TWO_TEAM then
			if remaining <= 0 then
				endTwoTeamByTimer()
			end
			publish()

		elseif state == "Ended" and TWO_TEAM then
			if remaining <= 0 then
				enter("Lobby", LOBBY_SECONDS) -- CastleService rebuilds both castles on this
				announce("Back to the lobby. The next siege starts soon.")
			end
			publish()

		elseif state == "Running" then
			if remaining <= 0 then
				endByTimer()
			else
				local progress = 1 - (remaining / matchLength)
				zoneHalf = zoneHalfAt(progress)
				drawZone(zoneHalf)

				for _, player in Players:GetPlayers() do
					local character = player.Character
					local humanoid = character and character:FindFirstChildOfClass("Humanoid")
					local root = character and character:FindFirstChild("HumanoidRootPart")
					if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
						if outsideBy(root.Position, zoneHalf) > 0 then
							humanoid:TakeDamage(ZONE_DAMAGE)
							-- No notice. This used to fire a toast EVERY SECOND
							-- for as long as you stood outside, which drowned
							-- out every other message in the game - and the
							-- toast is a single shared line, so a raid warning
							-- or a theft could not get a word in.
							--
							-- The HUD draws a red edge instead: permanent while
							-- it is true, silent while it is not, and it costs
							-- the notice channel nothing.
						end
					end
				end
				publish()
			end
		else
			publish()
		end
	end
end)
