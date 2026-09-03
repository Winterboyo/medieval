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
-- This file owns the clock and the boundary. It does NOT own bases, nodes or
-- elimination. It talks to ResourceService the way ResourceService already talks
-- to itself: through attributes published on instances, not a shared module.
--
--   Workspace.MatchState   "Lobby" | "Running" | "Ended"
--   Workspace.MatchClock   seconds left in the current phase
--   Workspace.ZoneHalf     half-extent of the playable square, in studs
--
-- ResourceService reads ZoneHalf to stop nodes outside the boundary yielding.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local notifyRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Notify")

local LOBBY_SECONDS = 15

-- The doc says 45-60 minutes. Overridable by a Workspace attribute set before
-- the server starts, because nobody - including a playtest - wants to sit
-- through three quarters of an hour to find out whether the timer fires.
local DEFAULT_MATCH_LENGTH = 45 * 60

-- The board is a 7x7 grid of 72-stud tiles centred on the origin and dead flat,
-- so the boundary is one number rather than a shape.
-- Both scale with the board, which is now 7 x 160 rather than 7 x 72. The final
-- ring is deliberately wide enough to hold a village or two: closing onto
-- something smaller than a single compound would decide the match by whose
-- walls happened to sit nearest the middle.
local ZONE_START_HALF = 560 -- the whole board
local ZONE_FINAL_HALF = 130 -- closes onto the totem at the centre
local ZONE_GRACE = 0.20 -- fraction of the match before it starts closing
local ZONE_CLOSED_BY = 0.90 -- fraction by which it has finished closing

local ZONE_TICK = 1
local ZONE_DAMAGE = 4 -- per tick outside; a push, not an execution
local ZONE_WALL_HEIGHT = 70

local state = "Lobby"
local phaseEndsAt = 0
local matchLength = DEFAULT_MATCH_LENGTH
local zoneHalf = ZONE_START_HALF

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
		return ZONE_START_HALF
	end
	if progress >= ZONE_CLOSED_BY then
		return ZONE_FINAL_HALF
	end
	local through = (progress - ZONE_GRACE) / (ZONE_CLOSED_BY - ZONE_GRACE)
	return ZONE_START_HALF + (ZONE_FINAL_HALF - ZONE_START_HALF) * through
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
local function beginMatch()
	matchLength = Workspace:GetAttribute("MatchLength") or DEFAULT_MATCH_LENGTH
	zoneHalf = ZONE_START_HALF
	drawZone(zoneHalf)
	setZoneVisible(true)
	enter("Running", matchLength)
	announce(("The match has begun - %d minutes"):format(math.floor(matchLength / 60)))
end

local function endMatch(reason: string)
	enter("Ended", math.huge)
	setZoneVisible(false)
	announce(reason)
end

task.spawn(function()
	zoneHalf = ZONE_START_HALF
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
				-- Stage 3 replaces this with last-team-standing. Until then the
				-- clock is the only way a match can end.
				endMatch("Time. The match is over.")
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
							notifyRemote:FireClient(player, "Outside the zone")
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
