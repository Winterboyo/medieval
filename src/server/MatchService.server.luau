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

local LOBBY_SECONDS = 15

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

local zoneWalls: { BasePart } = {}
for i = 1, 4 do
	local wall = Instance.new("Part")
	wall.Name = ("ZoneWall%d"):format(i)
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
	local span = half * 2
	local y = ZONE_WALL_HEIGHT / 2 - 6
	-- two walls on X, two on Z
	zoneWalls[1].Size = Vector3.new(1.5, ZONE_WALL_HEIGHT, span)
	zoneWalls[1].Position = Vector3.new(half, y, 0)
	zoneWalls[2].Size = Vector3.new(1.5, ZONE_WALL_HEIGHT, span)
	zoneWalls[2].Position = Vector3.new(-half, y, 0)
	zoneWalls[3].Size = Vector3.new(span, ZONE_WALL_HEIGHT, 1.5)
	zoneWalls[3].Position = Vector3.new(0, y, half)
	zoneWalls[4].Size = Vector3.new(span, ZONE_WALL_HEIGHT, 1.5)
	zoneWalls[4].Position = Vector3.new(0, y, -half)
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
local function outsideBy(position: Vector3, half: number): number
	local worst = math.max(math.abs(position.X), math.abs(position.Z))
	return math.max(0, worst - half)
end

-- ---------------------------------------------------------------- publishing
local function publish()
	Workspace:SetAttribute("MatchState", state)
	Workspace:SetAttribute("MatchClock", math.max(0, math.floor(phaseEndsAt - os.clock())))
	Workspace:SetAttribute("ZoneHalf", zoneHalf)
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
	enter("Ended", math.huge)
	setZoneVisible(false)
	announce(reason)
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
Players.PlayerAdded:Connect(function(player)
	if state == "Running" and not squadLedBy(player) then
		newSquad(player)
	end
end)

Players.PlayerRemoving:Connect(function(player)
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

watchForFallenKeeps()

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
