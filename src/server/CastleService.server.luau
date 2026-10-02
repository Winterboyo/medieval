--!strict
-- Medieval Land - the two castles, the teams that hold them, and the world they
-- stand in, all built from layout.json (CLAUDE.md §4, §6).
--
-- WHAT THIS OWNS
--   * the two Teams, each with a Goods folder: the team's POOLED stockpile. Every
--     good a player gathers, spends or loots goes through ResourceService's
--     counterFor, which in TwoTeam mode reads these instead of leaderstats.
--   * Workspace.Castles: both castles, structure by structure, named by their
--     layout.json ids (A_Wall_F1, A_Tower_FN, A_Gate_Door, A_Keep, ...). Every
--     destructible structure carries Kind, Health, MaxHealth and State
--     attributes; the castle carries the totals. Phase 3 makes them take damage.
--   * team spawn points inside each barracks.
--   * Workspace.ResourceNodes: one node per layout slot, the slot's first
--     allowed type (both halves of a mirrored pair always match).
--   * Workspace.BuildSites, empty: ResourceService waits for it at startup and
--     the old player-built villages that lived there are out of scope.
--   * the boundary: invisible walls on the beach and a kill height.
--
-- PLACEHOLDER ART. Everything here is plain parts at the layout's real sizes.
-- CLAUDE.md §7: playtests use grey placeholder art and art never gates a
-- playtest. The Blender kit (assets/castle/castle_kit.fbx) replaces these once it
-- has been import-tested in Studio (§12); each structure keeps its name and
-- attributes, so only its look changes.
--
-- RESET. A finished match goes back to the lobby; entering the lobby from Ended
-- rebuilds both castles whole, and the start of a match empties both stockpiles.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Teams = game:GetService("Teams")
local Workspace = game:GetService("Workspace")

local GameMode = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameMode"))
local Palette = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Palette"))

if not GameMode.TwoTeam then
	return
end

local Layout = require(ServerStorage:WaitForChild("Layout")) :: any

-- ---------------------------------------------------------------- numbers
-- CLAUDE.md §5 placeholders, to be tuned in a playtest.
local HEALTH = {
	GateDoor = 600,
	WallSection = 300,
	Tower = 500,
	Cannon = 150,
	Workshop = 300,
	Barracks = 400,
}

-- From the castle kit (assets/castle/build_castle.py), so placeholders stand
-- where the real meshes will.
local BAY = 20.4
local WALL_T = 4.0
local WALL_TOP = 14.4 -- walk at 11, merlons to 14.4
local TOWER_W = 15.2 -- across the upper drum
local TOWER_TOP = 27.6 -- the battlement band; gun towers carry their cannon here
local GATE_W, GATE_D, GATE_TOP = 24.0, 10.0, 21.4 -- gatehouse; its roof walk carries two cannons
local GATE_OPEN_W, GATE_OPEN_H = 10.0, 14.0
local KEEP_WALL = 20.0
local KEEP_DOOR_W, KEEP_DOOR_H = 6.0, 7.4
local HALL_WALL = 8.0 -- barracks and workshop eaves
local KILL_Y = -30

local STONE = Color3.fromRGB(193, 185, 166)
local STONE_DARK = Color3.fromRGB(129, 126, 117)
local SLATE = Color3.fromRGB(106, 111, 117)
local TIMBER = Color3.fromRGB(159, 137, 114)
local IRON = Color3.fromRGB(61, 61, 61)

-- ---------------------------------------------------------------- helpers
local function hex(s: string): Color3
	local r, g, b = s:match("#?(%x%x)(%x%x)(%x%x)")
	return Color3.fromRGB(tonumber(r, 16) or 128, tonumber(g, 16) or 128, tonumber(b, 16) or 128)
end

local function part(parent: Instance, name: string, size: Vector3, cframe: CFrame, colour: Color3,
	collide: boolean?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cframe
	p.Color = colour
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = collide ~= false
	p.Parent = parent
	return p
end

-- A structure that can be damaged: its own Model, so Phase 3 can swap its look
-- (intact / damaged / rubble) without its identity or attributes moving.
local function structure(parent: Instance, id: string, kind: string): Model
	local m = Instance.new("Model")
	m.Name = id
	m:SetAttribute("Kind", kind)
	local max = HEALTH[kind]
	if max then
		m:SetAttribute("MaxHealth", max)
		m:SetAttribute("Health", max)
		m:SetAttribute("State", "Intact")
	end
	m.Parent = parent
	return m
end

-- ---------------------------------------------------------------- teams
local teamByLayoutId: { [string]: Team } = {}

local ALL_GOODS: { string } = {}
for _, good in Palette.RAW_ORDER do
	table.insert(ALL_GOODS, good)
end
for _, good in Palette.CRAFTED_ORDER do
	table.insert(ALL_GOODS, good)
end

local TEAM_NAMES = { A = "Red", B = "Blue" } -- CLAUDE.md §4: team names, never usernames

local function setupTeams()
	for _, entry in Layout.teams do
		local name = TEAM_NAMES[entry.id] or ("Team " .. entry.id)
		local team = Teams:FindFirstChild(name) :: Team?
		if not team then
			team = Instance.new("Team")
			team.Name = name
			team.Parent = Teams
		end
		assert(team)
		team.TeamColor = BrickColor.new(hex(entry.banner_color_placeholder))
		-- New arrivals land on whichever side is shorter; Roblox does the counting.
		team.AutoAssignable = true
		team:SetAttribute("TeamId", entry.id)
		team:SetAttribute("Castle", entry.castle)
		team:SetAttribute("Side", entry.side)

		local goods = team:FindFirstChild("Goods") or Instance.new("Folder")
		goods.Name = "Goods"
		for _, good in ALL_GOODS do
			local counter = goods:FindFirstChild(good) :: IntValue?
			if not counter then
				local made = Instance.new("IntValue")
				made.Name = good
				made.Parent = goods
			end
		end
		goods.Parent = team
		teamByLayoutId[entry.id] = team
	end
end

local function emptyStockpiles()
	for _, team in teamByLayoutId do
		local goods = team:FindFirstChild("Goods")
		if goods then
			for _, counter in goods:GetChildren() do
				if counter:IsA("IntValue") then
					counter.Value = 0
				end
			end
		end
	end
end

-- ---------------------------------------------------------------- one castle
-- The layout is in world studs. Each castle is authored around its centre with
-- "forward" (f) pointing at its gate; team B's is team A's mirrored, which the
-- layout already did, so here everything is placed straight from world numbers.
local buildInterior: (Model, any, (number, number, number) -> CFrame, (number, number) -> CFrame, number) -> ()

local function buildCastle(into: Instance, c: any, team: Team)
	local castle = Instance.new("Model")
	castle.Name = c.id
	castle:SetAttribute("TeamId", c.team)
	castle:SetAttribute("Team", team.Name)
	castle:SetAttribute("Breached", false)
	castle:SetAttribute("Fallen", false)
	castle.Parent = into

	local y = c.pad.y
	local cx, cz = c.center.x, c.center.z
	local fx = c.gate_facing.x -- +1 for A (gate east), -1 for B
	local at = function(x: number, z: number, up: number): CFrame
		return CFrame.new(x, y + up, z)
	end
	-- Rotation that turns local +X (the castle-kit "forward") toward a facing.
	local facingRot = function(dx: number, dz: number): CFrame
		return CFrame.Angles(0, math.atan2(-dz, dx), 0)
	end

	-- A flat, invisible floor over the whole pad. The imported terrain's collision
	-- is approximated and bumpy at tile seams; the castle should not be.
	local floor = part(castle, "Floor", Vector3.new(c.pad.size, 1, c.pad.size), at(cx, cz, -0.45),
		STONE_DARK)
	floor.Transparency = 1

	-- wall sections: one bay each, named by the layout
	for _, s in c.wall_sections do
		local m = structure(castle, s.id, "WallSection")
		local alongZ = math.abs(s.facing.x) > 0.5 -- front/rear walls run along z
		local size = if alongZ then Vector3.new(WALL_T, WALL_TOP, BAY) else Vector3.new(BAY, WALL_TOP, WALL_T)
		part(m, "Body", size, at(s.x, s.z, WALL_TOP / 2), STONE)
	end

	-- towers: front two are open gun platforms, rear two keep a slate roof
	for _, t in c.towers do
		local m = structure(castle, t.id, "Tower")
		m:SetAttribute("TowerKind", t.kind)
		part(m, "Body", Vector3.new(TOWER_W, TOWER_TOP, TOWER_W), at(t.x, t.z, TOWER_TOP / 2), STONE)
		if t.kind ~= "gun" then
			part(m, "Roof", Vector3.new(TOWER_W - 3, 14, TOWER_W - 3), at(t.x, t.z, TOWER_TOP + 7), SLATE)
		end
	end

	-- gatehouse: two piers and a lintel, so the opening is really open; the door
	-- that fills it is its own destructible structure
	local g = c.gate
	local gx = g.x - fx * (WALL_T / 2) -- on the wall's centre line, like the kit
	local gate = Instance.new("Model")
	gate.Name = g.id
	gate:SetAttribute("Kind", "Gatehouse")
	gate.Parent = castle
	local pierW = (GATE_W - GATE_OPEN_W) / 2
	for _, side in { -1, 1 } do
		part(gate, "Pier", Vector3.new(GATE_D, GATE_TOP, pierW),
			at(gx, g.z + side * (GATE_OPEN_W / 2 + pierW / 2), GATE_TOP / 2), STONE)
	end
	part(gate, "Lintel", Vector3.new(GATE_D, GATE_TOP - GATE_OPEN_H, GATE_OPEN_W),
		at(gx, g.z, GATE_OPEN_H + (GATE_TOP - GATE_OPEN_H) / 2), STONE)
	local door = structure(castle, g.door_id, "GateDoor")
	part(door, "Body", Vector3.new(0.8, GATE_OPEN_H, GATE_OPEN_W - 0.2), at(gx + fx * 1.5, g.z, GATE_OPEN_H / 2), TIMBER)

	-- layout.json v2.1 has approved interior coordinates. The old v1.1 interior
	-- placeholder builder below still expects an obsolete workshop/cannon schema;
	-- the new geometry is for art generation until that builder is redesigned.
	if c.keep then
		buildInterior(castle, c, at, facingRot, fx)
	end

	-- The approved barracks markers replace the old front-courtyard preview spawns.
	local spawnPoints = if c.interior then c.interior.spawn_points else (c.spawn_points or c.temporary_preview_spawns or {})
	for _, sp in spawnPoints do
		local spawn = Instance.new("SpawnLocation")
		spawn.Name = sp.id
		spawn.Anchored = true
		spawn.Size = Vector3.new(4, 0.4, 4)
		spawn.CFrame = at(sp.x, sp.z, 0.2)
		spawn.Neutral = false
		spawn.AllowTeamChangeOnTouch = false
		spawn.TeamColor = team.TeamColor
		spawn.Color = team.TeamColor.Color
		spawn.Transparency = 0.4
		spawn.Duration = 3
		spawn.Material = Enum.Material.SmoothPlastic
		spawn:SetAttribute("Temporary", c.interior == nil and c.spawn_points == nil)
		spawn.Parent = castle
	end

	-- The imported battlefield (Workspace.Battlefield, assets/map/battlefield.fbx) carries
	-- the castle's look and collision. When it is present the grey placeholders stay as
	-- invisible, non-colliding stand-ins that keep the structure names and HP attributes.
	if Workspace:FindFirstChild("Battlefield") then
		for _, d in castle:GetDescendants() do
			if d:IsA("BasePart") and not d:IsA("SpawnLocation") and d.Name ~= "Floor" then
				d.Transparency = 1
				d.CanCollide = false
			end
		end
	end

	-- totals the HUD and the tiebreaker read
	local total, max = 0, 0
	for _, child in castle:GetChildren() do
		local h, m = child:GetAttribute("Health"), child:GetAttribute("MaxHealth")
		if typeof(h) == "number" and typeof(m) == "number" then
			total += h
			max += m
		end
	end
	castle:SetAttribute("StructureHP", total)
	castle:SetAttribute("StructureMax", max)
	return castle
end

-- The 2026-09-30 interior (layout.json v1.1): keep with the king's storage, barracks,
-- workshop and cannon mounts. Dormant: layout.json v2.1 uses c.interior with four
-- specialists and a ballista; do not connect this old builder to that schema.
buildInterior = function(castle: Model, c: any, at: (number, number, number) -> CFrame,
	facingRot: (number, number) -> CFrame, fx: number)
	-- the king's keep: hollow, door toward the gate; cannot be destroyed
	local k = c.keep
	local keep = Instance.new("Model")
	keep.Name = k.id
	keep:SetAttribute("Kind", "Keep")
	keep.Parent = castle
	local kx0, kx1, kz0, kz1 = k.min_x, k.max_x, k.min_z, k.max_z
	local kcx, kcz = (kx0 + kx1) / 2, (kz0 + kz1) / 2
	local kdx, kdz = kx1 - kx0, kz1 - kz0
	local wt = 1.6
	local doorX = k.door.x -- the face with the door
	local backX = if math.abs(doorX - kx0) < 0.01 then kx1 else kx0
	part(keep, "Back", Vector3.new(wt, KEEP_WALL, kdz), at(backX - math.sign(backX - kcx) * wt / 2, kcz, KEEP_WALL / 2), STONE)
	for _, side in { -1, 1 } do
		part(keep, "Side", Vector3.new(kdx, KEEP_WALL, wt), at(kcx, kcz + side * (kdz / 2 - wt / 2), KEEP_WALL / 2), STONE)
		local w = (kdz - KEEP_DOOR_W) / 2
		part(keep, "Front", Vector3.new(wt, KEEP_WALL, w),
			at(doorX - math.sign(doorX - kcx) * wt / 2, kcz + side * (KEEP_DOOR_W / 2 + w / 2), KEEP_WALL / 2), STONE)
	end
	part(keep, "OverDoor", Vector3.new(wt, KEEP_WALL - KEEP_DOOR_H, KEEP_DOOR_W),
		at(doorX - math.sign(doorX - kcx) * wt / 2, kcz, KEEP_DOOR_H + (KEEP_WALL - KEEP_DOOR_H) / 2), STONE)
	part(keep, "Roof", Vector3.new(kdx + 1.4, 1.4, kdz + 1.4), at(kcx, kcz, KEEP_WALL + 0.7), STONE_DARK)
	local st = k.storage
	local storage = part(keep, "King_Storage", Vector3.new(st.max_x - st.min_x, 1.2, st.max_z - st.min_z),
		at((st.min_x + st.max_x) / 2, (st.min_z + st.max_z) / 2, 0.6), TIMBER)
	storage:SetAttribute("Kind", "Storage")
	-- where the heap of goods will stand, and what a raider aims at (Phase 3)
	local heap = Instance.new("Attachment")
	heap.Name = "HeapOrigin"
	heap.Position = Vector3.new(0, 0.6, 0)
	heap.Parent = storage

	-- barracks and workshop: hollow halls with a doorway onto the courtyard
	local function hall(id: string, kind: string, r: any, openFront: boolean)
		local m = structure(castle, id, kind)
		local x0, x1, z0, z1 = r.min_x, r.max_x, r.min_z, r.max_z
		local hx, hz = (x0 + x1) / 2, (z0 + z1) / 2
		local dx, dz = x1 - x0, z1 - z0
		local w = 1.2
		local doorZ = r.door.z -- the long face with the door
		local backZ = if math.abs(doorZ - z0) < 0.01 then z1 else z0
		part(m, "Back", Vector3.new(dx, HALL_WALL, w), at(hx, backZ - math.sign(backZ - hz) * w / 2, HALL_WALL / 2), STONE)
		for _, side in { -1, 1 } do
			part(m, "End", Vector3.new(w, HALL_WALL, dz), at(hx + side * (dx / 2 - w / 2), hz, HALL_WALL / 2), STONE)
		end
		local frontZ = doorZ - math.sign(doorZ - hz) * w / 2
		if openFront then
			for _, x in { x0 + 0.6, (x0 + x1) / 2, x1 - 0.6 } do
				part(m, "Post", Vector3.new(0.7, HALL_WALL, 0.7), at(x, frontZ, HALL_WALL / 2), TIMBER)
			end
		else
			local doorW = 5
			local leftW = r.door.x - doorW / 2 - x0
			local rightW = x1 - (r.door.x + doorW / 2)
			part(m, "Front", Vector3.new(leftW, HALL_WALL, w), at(x0 + leftW / 2, frontZ, HALL_WALL / 2), STONE)
			part(m, "Front", Vector3.new(rightW, HALL_WALL, w), at(x1 - rightW / 2, frontZ, HALL_WALL / 2), STONE)
			part(m, "OverDoor", Vector3.new(doorW, HALL_WALL - 7.5, w), at(r.door.x, frontZ, 7.5 + (HALL_WALL - 7.5) / 2), STONE)
		end
		part(m, "Roof", Vector3.new(dx + 1.6, 1.0, dz + 2.4), at(hx, hz, HALL_WALL + 0.5), SLATE)
		return m
	end
	hall(c.barracks.id, "Barracks", c.barracks, false)
	local workshop = hall(c.workshop.id, "Workshop", c.workshop, true)
	local wcx = (c.workshop.min_x + c.workshop.max_x) / 2
	local wcz = (c.workshop.min_z + c.workshop.max_z) / 2
	part(workshop, "Hearth", Vector3.new(4, 2, 3), at(wcx - fx * 7, wcz - math.sign(c.workshop.door.z - wcz) * 4.5, 1), STONE_DARK)
	part(workshop, "Anvil", Vector3.new(2, 2.7, 1.4), at(wcx - fx * 2, wcz - math.sign(c.workshop.door.z - wcz) * 2, 1.35), IRON)

	-- cannons: placeholder barrels on their mounts, aimed at the enemy
	for _, cm in c.cannon_mounts do
		local m = structure(castle, cm.id, "Cannon")
		m:SetAttribute("On", cm.on)
		local rot = facingRot(cm.aim.x, cm.aim.z)
		part(m, "Carriage", Vector3.new(3.2, 1.2, 2), at(cm.x, cm.z, cm.height + 0.6) * rot, TIMBER)
		part(m, "Barrel", Vector3.new(4.5, 1.2, 1.2), at(cm.x, cm.z, cm.height + 1.75) * rot * CFrame.new(0.6, 0, 0), IRON)
	end

end

local function buildCastles()
	local old = Workspace:FindFirstChild("Castles")
	if old then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "Castles"
	for _, c in Layout.castles do
		local team = teamByLayoutId[c.team]
		if team then
			buildCastle(folder, c, team)
		end
	end
	folder.Parent = Workspace
end

-- ---------------------------------------------------------------- resource nodes
-- Placeholders: a block in the resource's colour with a few wearable chunks on top,
-- which ResourceService erodes as the node is worked down. The slot's FIRST
-- allowed type is used, so both halves of a mirrored pair always match;
-- per-match variation (CLAUDE.md §6.4) is a later task.
local function buildNodes()
	if Workspace:FindFirstChild("ResourceNodes") then
		return -- ResourceService registered these once; rebuilding would orphan its table
	end
	local folder = Instance.new("Folder")
	folder.Name = "ResourceNodes"
	for _, slot in Layout.resource_node_slots do
		local resource = slot.allowed_types[1]
		local model = Instance.new("Model")
		model.Name = slot.id
		model:SetAttribute("Resource", resource)
		model:SetAttribute("Slot", slot.id)
		local colour = Palette.GOODS[resource] or STONE
		local p = slot.position
		local core = part(model, "Core", Vector3.new(7, 5, 7), CFrame.new(p.x, p.y + 2.5, p.z), colour)
		model.PrimaryPart = core
		for i, offset in { Vector3.new(-1.6, 0, -1.6), Vector3.new(1.6, 0, 1.4), Vector3.new(0, 1.4, 0) } do
			local chunk = part(model, "Chunk" .. i, Vector3.new(2.6, 2.2, 2.6),
				CFrame.new(p.x + offset.X, p.y + 6.1 + offset.Y, p.z + offset.Z), colour:Lerp(Color3.new(1, 1, 1), 0.15))
			chunk:SetAttribute("Wears", true)
		end
		model.Parent = folder
	end
	folder.Parent = Workspace
end

-- ---------------------------------------------------------------- the boundary
-- layout.json: an invisible wall standing on the beach, a rounded rectangle offset
-- outside map_bounds, and a kill height below the sea as the safety net.
local function buildBoundary()
	local old = Workspace:FindFirstChild("Boundary")
	if old then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "Boundary"
	local b, bd = Layout.map_bounds, Layout.boundary
	local hx = (b.max_x - b.min_x) / 2 + bd.offset_outside_bounds
	local hz = (b.max_z - b.min_z) / 2 + bd.offset_outside_bounds
	local cx, cz = (b.max_x + b.min_x) / 2, (b.max_z + b.min_z) / 2
	local r = bd.corner_radius
	local pts: { Vector2 } = {}
	for _, q in { { 1, 1, 0 }, { -1, 1, 90 }, { -1, -1, 180 }, { 1, -1, 270 } } do
		local ox, oz = cx + q[1] * (hx - r), cz + q[2] * (hz - r)
		for k = 0, 8 do
			local a = math.rad(q[3] + k * 90 / 8)
			pts[#pts + 1] = Vector2.new(ox + math.cos(a) * r, oz + math.sin(a) * r)
		end
	end
	for i = 1, #pts do
		local p0, p1 = pts[i], pts[(i % #pts) + 1]
		local len = (p1 - p0).Magnitude
		if len > 0.01 then
			local mid = (p0 + p1) / 2
			local wall = part(folder, "Wall", Vector3.new(len + 0.6, bd.height, 2),
				CFrame.new(mid.X, bd.height / 2 - 10, mid.Y) * CFrame.Angles(0, -math.atan2(p1.Y - p0.Y, p1.X - p0.X), 0),
				STONE_DARK)
			wall.Transparency = 1
			wall.CanQuery = false
		end
	end
	folder.Parent = Workspace
end

task.spawn(function()
	while true do
		task.wait(0.5)
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 and root.Position.Y < KILL_Y then
				humanoid.Health = 0
			end
		end
	end
end)

-- Anyone without a side goes to the shorter one. Covers players who were in
-- before the Teams existed (Studio playtests start the player very early) and any
-- arrival Roblox's auto-assignment missed.
local function assignSide(player: Player)
	if player.Team and player.Team:GetAttribute("Castle") ~= nil then
		return
	end
	local best: Team? = nil
	for _, team in teamByLayoutId do
		if not best or #team:GetPlayers() < #(best :: Team):GetPlayers() then
			best = team
		end
	end
	if best then
		player.Team = best
	end
end

-- ---------------------------------------------------------------- startup and reset
setupTeams()
for _, player in Players:GetPlayers() do
	assignSide(player)
end
Players.PlayerAdded:Connect(function(player)
	task.defer(assignSide, player) -- after Roblox's own auto-assignment has had its go
end)
buildCastles()
buildNodes()
buildBoundary()
if not Workspace:FindFirstChild("BuildSites") then
	local sites = Instance.new("Folder")
	sites.Name = "BuildSites"
	sites.Parent = Workspace
end

local lastState = Workspace:GetAttribute("MatchState")
Workspace:GetAttributeChangedSignal("MatchState"):Connect(function()
	local now = Workspace:GetAttribute("MatchState")
	if now == "Lobby" and lastState == "Ended" then
		buildCastles() -- whole again for the next match
	elseif now == "Running" and lastState ~= "Running" then
		emptyStockpiles() -- everyone starts from nothing
	end
	lastState = now
end)
