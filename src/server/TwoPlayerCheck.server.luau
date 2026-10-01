--!strict
-- Medieval Land - the two-player verification harness.
--
-- WHY THIS EXISTS. A pile of behaviour can only be exercised with two real
-- players in the server: per-player notice isolation, PvP and knockdown, the
-- stockpile loot transfer (the snapshot reads the OWNER's counters, so with one
-- player there is no owner), specialist theft, the fourth elimination gate's
-- blocking case, and the squad fold. None of it is reachable solo.
--
-- It also cannot be driven from outside. Studio's "Start Server and Players"
-- runs the server and each client as SEPARATE processes, and the Studio plugin
-- only registers in the editor - so an external tool can see the place but not
-- the running test. The harness therefore runs INSIDE the server and prints its
-- own report.
--
-- HOW TO USE
--   1. In the editor, set Workspace.TwoPlayerCheck = true  (it is opt-in so it
--      can never fire during ordinary play - it hands out resources).
--   2. Test tab -> Players: 2 -> Start.
--   3. Follow the instructions it prints in the SERVER window's Output.
--   4. Copy the report back.
--
-- It drives both characters from the server, which works for everything except
-- ProximityPrompt, whose Triggered event must be raised by a real client. So
-- the one manual step is building a village; everything after that is automatic.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- This harness tests the old free-for-all (villages, squads, the fold). In TwoTeam
-- it would fail every check and hand out resources, so it stays off until it is
-- rewritten for two teams (Phase 5).
if require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameMode")).TwoTeam then
	return
end

if Workspace:GetAttribute("TwoPlayerCheck") ~= true then
	return
end

local RAID_TOOL = "Pickaxe"
local SWING_GAP = 1.06 -- one swing per second, plus headroom

local report: { string } = {}
local passes, failures = 0, 0

local function say(line: string)
	print("[2P] " .. line)
end

local function record(label: string, ok: boolean, detail: string)
	if ok then
		passes += 1
	else
		failures += 1
	end
	local line = ("%-4s %-38s %s"):format(if ok then "PASS" else "FAIL", label, detail)
	report[#report + 1] = line
	say(line)
end

local function note(label: string, detail: string)
	report[#report + 1] = ("%-4s %-38s %s"):format("EYE", label, detail)
	say(("%-4s %-38s %s"):format("EYE", label, detail))
end

-- ---------------------------------------------------------------- helpers
local function counter(player: Player, name: string): IntValue?
	local stats = player:FindFirstChild("leaderstats")
	local value = stats and stats:FindFirstChild(name)
	return if value and value:IsA("IntValue") then value else nil
end

local function held(player: Player, name: string): number
	local value = counter(player, name)
	return if value then value.Value else 0
end

local function grant(player: Player, bundle: { [string]: number })
	for name, amount in bundle do
		local value = counter(player, name)
		if value then
			value.Value = amount
		end
	end
end

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude

-- Place a character on whatever surface is actually there and confirm it stayed.
-- Guessing a height, or landing on a roof and being shoved off, has produced
-- false failures in this project before.
local function place(player: Player, at: Vector3, lookAt: Vector3?): number
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return math.huge
	end
	groundParams.FilterDescendantsInstances = { character }
	local hit = Workspace:Raycast(at + Vector3.new(0, 240, 0), Vector3.new(0, -480, 0), groundParams)
	local y = (if hit then hit.Position.Y else at.Y) + 3.4
	local target = Vector3.new(at.X, y, at.Z)
	root.CFrame = if lookAt
		then CFrame.lookAt(target, Vector3.new(lookAt.X, y, lookAt.Z))
		else CFrame.new(target)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = 0
	end
	task.wait(1.1)
	return (Vector3.new(root.Position.X, 0, root.Position.Z) - Vector3.new(at.X, 0, at.Z)).Magnitude
end

local function equip(player: Player, toolName: string): Tool?
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local tool = character:FindFirstChild(toolName)
	if not tool then
		local packed = player.Backpack:FindFirstChild(toolName)
		if packed and humanoid then
			humanoid:EquipTool(packed)
			task.wait(0.4)
			tool = character:FindFirstChild(toolName)
		end
	end
	return if tool and tool:IsA("Tool") then tool else nil
end

local function swing(player: Player, times: number, toolName: string?)
	local tool = equip(player, toolName or RAID_TOOL)
	if not tool then
		return
	end
	for _ = 1, times do
		tool:Activate()
		task.wait(SWING_GAP)
	end
end

local function baseOwnedBy(player: Player): Model?
	for _, base in Workspace.BuildSites:GetChildren() do
		if base:GetAttribute("Owner") == player.UserId then
			return base :: Model
		end
	end
	return nil
end

-- ---------------------------------------------------------------- the run
task.spawn(function()
	say("harness armed - waiting for two players")
	while #Players:GetPlayers() < 2 do
		task.wait(1)
	end
	for _, player in Players:GetPlayers() do
		while not player.Character do
			task.wait(0.5)
		end
		grant(player, { Wood = 900, Grain = 900, Wool = 900, Stone = 900, Ore = 900,
			Timber = 40, Ingot = 40, Tonic = 20 })
	end

	say("")
	say("=========== DO THIS NOW, IN THE TWO CLIENT WINDOWS ===========")
	say("It does not matter which window does which. The harness works the")
	say("roles out from who actually built what.")
	say("")
	say("  ONE of you: walk to an empty plot and hold E until it reads")
	say("              'Village complete'. Ten presses. That makes you the")
	say("              VICTIM - the village that gets besieged.")
	say("  The OTHER:  walk to a DIFFERENT plot and build as far as the")
	say("              Blacksmith, six presses, so you hold a specialist.")
	say("              The theft test needs one to compare against. That")
	say("              makes you the RAIDER.")
	say("")
	say("Then leave both characters alone. The rest is automatic.")
	say("==============================================================")
	say("")

	-- Roles are read from the WORLD, not from join order. Assuming
	-- GetPlayers()[1] was the raider left the harness waiting forever the first
	-- time it ran, because join order is not something the person running the
	-- test picks, sees, or can predict. Whoever finished a village is the
	-- victim; the other one is the raider.
	local foundVictim: Player? = nil
	local victimBase: Model? = nil
	repeat
		task.wait(2)
		for _, player in Players:GetPlayers() do
			local candidate = baseOwnedBy(player)
			if candidate and (candidate:GetAttribute("Stage") or 0) >= 10 then
				foundVictim, victimBase = player, candidate
			end
		end
	until victimBase and foundVictim

	local foundRaider: Player? = nil
	for _, player in Players:GetPlayers() do
		if player ~= foundVictim then
			foundRaider = player
		end
	end
	if not foundRaider then
		say("FAIL: only one player present, cannot run the two-player checks")
		return
	end

	local victim: Player = foundVictim :: Player
	local raider: Player = foundRaider :: Player
	say(("roles from the world: victim = %s (built the village), raider = %s"):format(
		victim.Name, raider.Name))
	say(("%s's village is ready: %s"):format(victim.Name, (victimBase :: Model).Name))
	task.wait(2)

	local base = victimBase :: Model
	local foundation = base:FindFirstChild("Foundation") :: BasePart
	local gate = base:FindFirstChild("Gate") :: BasePart
	local keep = base:FindFirstChild("Keep") :: BasePart

	-- ---- 1. per-player notices -----------------------------------
	local notify = game:GetService("ReplicatedStorage"):WaitForChild("Remotes"):WaitForChild("Notify")
	;(notify :: RemoteEvent):FireClient(raider, "NOTICE TEST: this line is for the RAIDER only")
	;(notify :: RemoteEvent):FireClient(victim, "NOTICE TEST: this line is for the VICTIM only")
	note("per-player notice isolation",
		"check each client window shows only ITS line, not both")

	-- ---- 2. PvP damage -------------------------------------------
	-- Roblox gives every character a "Health" script that regenerates about 1%
	-- a second. Over the ~2.1s two swings take that is ~2 HP, which is why the
	-- first run measured 38 against an expected 40 and reported a failure that
	-- was not one. Stop the regen so the measurement is of the swing alone.
	local regen = (victim.Character :: Model):FindFirstChild("Health")
	if regen then
		regen:Destroy()
		task.wait(0.3)
	end
	local victimRoot = (victim.Character :: Model):FindFirstChild("HumanoidRootPart") :: BasePart
	local drift = place(raider, victimRoot.Position + Vector3.new(0, 0, 6), victimRoot.Position)
	local victimHumanoid = (victim.Character :: Model):FindFirstChildOfClass("Humanoid") :: Humanoid
	local healthBefore = victimHumanoid.Health
	swing(raider, 2)
	local dealt = healthBefore - victimHumanoid.Health
	record("PvP damage (2 swings, want 40)", dealt == 40,
		("dealt %d, drift %.1f, regen script %s"):format(
			dealt, drift, if regen then "removed" else "absent"))

	-- ---- 3. knockdown and revive at own keep ----------------------
	local diedAt = victimRoot.Position
	victimHumanoid.Health = 0
	task.wait(11)
	local newRoot = victim.Character and (victim.Character :: Model):FindFirstChild("HumanoidRootPart")
	if newRoot and newRoot:IsA("BasePart") then
		local toKeep = (newRoot.Position - keep.Position).Magnitude
		record("knockdown revives at own keep", toKeep < 40,
			("%.0f studs from keep, died %.0f away"):format(toKeep, (diedAt - keep.Position).Magnitude))
	else
		record("knockdown revives at own keep", false, "no character after 11s")
	end

	-- ---- 4. gate battering against a real owner -------------------
	local outward = (gate.Position - foundation.Position)
	outward = Vector3.new(outward.X, 0, outward.Z).Unit
	place(raider, gate.Position + outward * 10, gate.Position)
	local wallBefore = base:GetAttribute("Wall") :: number
	swing(raider, 3)
	local wallDropped = wallBefore - (base:GetAttribute("Wall") :: number)
	record("gate battering (3 swings, want 75)", wallDropped == 75,
		("wall %d -> %d"):format(wallBefore, base:GetAttribute("Wall") :: number))

	-- Trim the victim to a small, KNOWN holding before the breach.
	--
	-- The stockpile snapshot is 20% of whatever they hold at the moment the
	-- wall falls. Twenty percent of a 900-unit test grant is hundreds of units,
	-- and at four per swing that is minutes of battering - so loot would still
	-- be sitting on the pile when the keep gate is tested, and a "keep is
	-- immune" result could then be caused by the loot clause rather than the
	-- specialist clause it is meant to prove. A small holding makes the drain
	-- quick and the gate test unambiguous.
	grant(victim, { Wood = 20, Grain = 20, Wool = 20, Stone = 20, Ore = 20,
		Timber = 5, Ingot = 5, Tonic = 5 })
	task.wait(0.5)

	-- breach it fully
	local guard = 0
	while (base:GetAttribute("Wall") :: number) > 0 and guard < 40 do
		swing(raider, 4)
		guard += 4
	end
	record("wall breaches", base:GetAttribute("Breached") == true,
		("wall %s after %d more swings"):format(tostring(base:GetAttribute("Wall")), guard))

	-- ---- 5. the loot snapshot actually moves goods ----------------
	-- This is the one that cannot be tested alone at all: the snapshot reads
	-- the OWNERs counters, and solo there is no owner to read.
	local lootAtBreach = base:GetAttribute("LootLeft")
	local stockpile = base:FindFirstChild("Stockpile") :: BasePart
	-- Clear of the pallet, not on its edge. At exactly half-depth the placement
	-- raycast lands the raider ON the pallet, which is a legitimate place to
	-- stand but a terrible place to measure from.
	local lootDrift = place(raider,
		stockpile.Position + Vector3.new(0, 0, (stockpile.Size.Z / 2) + 6),
		stockpile.Position)

	local victimTotalBefore, raiderTotalBefore = 0, 0
	local GOODS = { "Wood", "Grain", "Wool", "Stone", "Ore", "Timber", "Ingot", "Tonic" }
	for _, name in GOODS do
		victimTotalBefore += held(victim, name)
		raiderTotalBefore += held(raider, name)
	end

	-- Swing first, then check. The old loop read LootLeft before any swing had
	-- landed; it was nil at that point, so the loop never ran once and every
	-- check downstream of an empty stockpile failed for the wrong reason.
	local drained = 0
	repeat
		swing(raider, 2)
		drained += 2
	until ((base:GetAttribute("LootLeft") :: number?) or 0) <= 0 or drained >= 60

	local victimTotalAfter, raiderTotalAfter = 0, 0
	for _, name in GOODS do
		victimTotalAfter += held(victim, name)
		raiderTotalAfter += held(raider, name)
	end
	local victimDelta = victimTotalAfter - victimTotalBefore
	local raiderGained = raiderTotalAfter - raiderTotalBefore
	local lootAfter = (base:GetAttribute("LootLeft") :: number?) or -1
	local moved = ((lootAtBreach :: number?) or 0) - lootAfter

	-- Assert on the POT, not on the victim's total. Both villages have
	-- cottages, and a cottage trickles a resource every 12 seconds, so over a
	-- minute of looting the victim can easily gain more from labour than the
	-- raid takes off them - the previous run reported the victim ending up 20
	-- UP while being robbed. The pot only moves one way, so it is the honest
	-- measure; the victim's net is printed as information, not judged.
	record("loot moves owner -> raider", moved > 0 and raiderGained >= moved,
		("pot %s -> %d (moved %d), raider +%d, victim net %+d incl. labour, %d swings, drift %.1f"):format(
			tostring(lootAtBreach), lootAfter, moved, raiderGained, victimDelta, drained, lootDrift))
	record("stockpile drains to empty", lootAfter == 0,
		("LootLeft = %d"):format(lootAfter))

	-- ---- 6. the fourth gate BLOCKS while specialists remain -------
	local specialistsNow = victim:GetAttribute("SpecialistCount")
	place(raider, keep.Position + Vector3.new(0, 0, (keep.Size.Z / 2) + 4), keep.Position)
	local keepBefore = base:GetAttribute("KeepHealth") :: number
	swing(raider, 3)
	local keepAfter = base:GetAttribute("KeepHealth") :: number
	record("keep immune while specialists remain",
		specialistsNow ~= nil and (specialistsNow :: number) > 0 and keepAfter == keepBefore,
		("victim holds %s specialists, keep %d -> %d"):format(
			tostring(specialistsNow), keepBefore, keepAfter))

	-- ---- 7. specialist theft at 85% -------------------------------
	local benches: { [string]: BasePart } = {}
	for _, thing in base:GetDescendants() do
		if thing:IsA("ProximityPrompt") and thing.Name == "CraftPrompt" then
			local role = thing:GetAttribute("Recipe")
			local host = thing.Parent
			if typeof(role) == "string" and host and host:IsA("BasePart") then
				benches[role] = host
			end
		end
	end
	local stolenAny = false
	for role, bench in benches do
		local before = victim:GetAttribute("Specialists")
		place(raider, bench.Position + Vector3.new(0, 0, 7), bench.Position)
		swing(raider, 2)
		if victim:GetAttribute("Specialists") ~= before then
			stolenAny = true
			record(("theft: %s"):format(role), true,
				("victim '%s' -> '%s'   raider now '%s'"):format(
					tostring(before), tostring(victim:GetAttribute("Specialists")),
					tostring(raider:GetAttribute("Specialists"))))
		end
	end
	if not stolenAny then
		record("specialist theft", false, "no specialist changed hands")
	end
	record("victim stripped of specialists", (victim:GetAttribute("SpecialistCount") :: number) == 0,
		("count = %s"):format(tostring(victim:GetAttribute("SpecialistCount"))))

	-- ---- 8. the theft forces a negotiation ------------------------
	-- The panel itself needs a human clicking it, so what is checked here is
	-- the half that does not: that a theft opens a session at all, and that the
	-- doc's escalation - killing the messenger - actually costs the killer.
	task.wait(1.5)
	local messengers = Workspace:FindFirstChild("Messengers")
	local messenger: Model? = nil
	if messengers then
		for _, thing in messengers:GetChildren() do
			if thing:IsA("Model") and thing.PrimaryPart then
				messenger = thing
			end
		end
	end
	record("theft sends a messenger", messenger ~= nil,
		("messengers standing: %d"):format(if messengers then #messengers:GetChildren() else 0))

	if messenger then
		local anchor = (messenger :: Model).PrimaryPart :: BasePart
		local pausedBefore = raider:GetAttribute("LabourPausedUntil")
		place(raider, anchor.Position + Vector3.new(0, 0, 7), anchor.Position)
		swing(raider, 2)
		task.wait(1)
		local pausedAfter = raider:GetAttribute("LabourPausedUntil")
		record("killing the messenger enrages your own people",
			typeof(pausedAfter) == "number" and pausedAfter ~= pausedBefore,
			("LabourPausedUntil %s -> %s, messenger removed = %s"):format(
				tostring(pausedBefore), tostring(pausedAfter),
				tostring((messenger :: Model).Parent == nil)))
	end

	-- ---- 9. keep falls, elimination, fold, win --------------------
	place(raider, keep.Position + Vector3.new(0, 0, (keep.Size.Z / 2) + 4), keep.Position)
	local keepStart = base:GetAttribute("KeepHealth") :: number

	-- Swing until it falls, not a fixed count. Roughly one swing in seven does
	-- not land - the gate phase needed 24 to do 21 swings of work - so a keep
	-- needing exactly 8 hits got 7 out of a hardcoded 10 and stopped at 25 HP.
	-- Loop to the OUTCOME and let the cap catch a genuine refusal.
	local keepSwings = 0
	repeat
		swing(raider, 3)
		keepSwings += 3
	until base:GetAttribute("Fallen") == true or keepSwings >= 27
	record("keep razed once every gate is met", base:GetAttribute("Fallen") == true,
		("keep %d -> %s after %d swings"):format(
			keepStart, tostring(base:GetAttribute("KeepHealth")), keepSwings))

	task.wait(2)
	record("victim eliminated", victim:GetAttribute("Eliminated") == true,
		("Eliminated=%s"):format(tostring(victim:GetAttribute("Eliminated"))))
	record("victim folded into the raider's squad",
		victim:GetAttribute("Squad") == raider:GetAttribute("Squad"),
		("victim squad '%s', raider squad '%s'"):format(
			tostring(victim:GetAttribute("Squad")), tostring(raider:GetAttribute("Squad"))))
	record("match resolves to one squad",
		Workspace:GetAttribute("MatchState") == "Ended",
		("MatchState=%s"):format(tostring(Workspace:GetAttribute("MatchState"))))

	-- ---- report ---------------------------------------------------
	say("")
	say("================== COPY FROM HERE ==================")
	for _, line in report do
		print(line)
	end
	print(("[2P] %d passed, %d failed"):format(passes, failures))
	say("=================== TO HERE ========================")
end)
