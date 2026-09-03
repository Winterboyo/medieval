--!strict
-- Medieval Land - negotiation over a stolen specialist.
--
-- DESIGN.md: theft of a specialist triggers negotiation between the two
-- players, capped at a fixed number of rounds. The messenger cannot be refused
-- outright, because the theft was deliberate and engagement is forced. Either
-- side can escalate by killing the messenger, which enrages the killer's own
-- people and damages their reputation. Hitting the round cap with no resolution
-- costs the thief.
--
-- WHY THE CAP HAS TO COST BOTH SIDES
--
-- The doc says only the thief pays for hitting the cap. On its own that makes
-- stalling strictly optimal for the victim: they lose nothing by running the
-- clock out, so no victim would ever settle and the whole negotiation is
-- theatre with a timer on it.
--
-- That is precisely the flaw the doc itself identifies two sections earlier, in
-- the rebellious flag - "as designed, it has no real cost, meaning flagging
-- everyone rebellious is strictly optimal". Worth not repeating it.
--
-- So the cap costs BOTH, asymmetrically. The thief takes the reputation hit the
-- doc asks for AND the specialist sours a rank, because nobody works well for
-- someone who took them by force and would not deal. The victim loses the
-- specialist permanently - there is no second messenger. The thief loses more,
-- which is the doc's intent, but the victim now has a real reason to settle
-- rather than wait.
--
-- The same resolution covers a refusal by either side. Refusing is just ending
-- it early; the outcome is identical, so nobody gains by dragging it out.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local notifyRemote = remotes:WaitForChild("Notify") :: RemoteEvent
local stateRemote = remotes:WaitForChild("NegotiationState") :: RemoteEvent
local actRemote = remotes:WaitForChild("NegotiationAct") :: RemoteEvent

local events = ServerStorage:WaitForChild("Events")
local specialistStolenSignal = events:WaitForChild("SpecialistStolen") :: BindableEvent
local messengerStruckSignal = events:WaitForChild("MessengerStruck") :: BindableEvent
local reputationDeltaSignal = events:WaitForChild("ReputationDelta") :: BindableEvent
-- The roster lives in ResourceService. Asking it to move somebody is a signal,
-- for the same reason the theft is: it is an event with a payload, not a fact
-- about the world that an attribute could describe.
local specialistSetSignal = events:WaitForChild("SpecialistSet") :: BindableEvent

local MAX_ROUNDS = 3

-- The opening demand, per rank. A rank 5 specialist is worth five times a rank
-- 1 to whoever lost them, so the ask scales with what was actually taken.
local RANSOM_PER_RANK = 12

-- A counter cannot be sillier than this multiple of the opening ask. Without a
-- ceiling a client could propose a demand of 2^31 and the panel would dutifully
-- render it.
local COUNTER_CEILING = 3

-- How long a side has to move before the session resolves itself. A negotiation
-- that hangs because somebody walked away from the keyboard would otherwise pin
-- a specialist in limbo for the rest of the match.
local TURN_SECONDS = 45

local CAP_REPUTATION_PENALTY = -15
local MESSENGER_REPUTATION_PENALTY = -30
local MESSENGER_LABOUR_PAUSE = 90

local RAW_GOODS = { "Wood", "Grain", "Wool", "Stone", "Ore" }

type Session = {
	id: number,
	thief: Player,
	victim: Player,
	role: string,
	rank: number,
	resource: string,
	demand: number,
	opening: number,
	round: number,
	turn: Player,
	messenger: Model?,
	message: string,
	over: boolean,
	deadline: number,
}

local sessions: { [number]: Session } = {}
local sessionByPlayer: { [Player]: Session } = {}
local nextId = 0

-- ---------------------------------------------------------------- helpers
local function counterFor(player: Player, resource: string): IntValue?
	local stats = player:FindFirstChild("leaderstats")
	local value = stats and stats:FindFirstChild(resource)
	return if value and value:IsA("IntValue") then value else nil
end

local function held(player: Player, resource: string): number
	local value = counterFor(player, resource)
	return if value then value.Value else 0
end

-- A session can outlive one of its parties by a frame or two - somebody quits
-- mid-negotiation and the resolution still has things to say. Firing at a
-- player who has left throws, so both channels check they are still here.
local function stillHere(player: Player): boolean
	return player ~= nil and player.Parent ~= nil
end

local function notify(player: Player, text: string)
	if stillHere(player) then
		notifyRemote:FireClient(player, text)
	end
end

-- Paid in whatever the victim has most of. A ransom they cannot physically pay
-- is not a negotiation, it is a countdown.
local function ransomCurrency(victim: Player): string
	local best, most = RAW_GOODS[1], -1
	for _, name in RAW_GOODS do
		local amount = held(victim, name)
		if amount > most then
			best, most = name, amount
		end
	end
	return best
end

-- ---------------------------------------------------------------- the panel
local function pushTo(session: Session, player: Player)
	if not stillHere(player) then
		return
	end
	stateRemote:FireClient(player, {
		active = not session.over,
		role = if player == session.thief then "thief" else "victim",
		otherName = if player == session.thief then session.victim.Name else session.thief.Name,
		specialist = session.role,
		rank = session.rank,
		round = session.round,
		maxRounds = MAX_ROUNDS,
		resource = session.resource,
		demand = session.demand,
		yourTurn = (not session.over) and session.turn == player,
		youHold = held(player, session.resource),
		message = session.message,
	})
end

local function push(session: Session)
	pushTo(session, session.thief)
	pushTo(session, session.victim)
end

-- ---------------------------------------------------------------- endings
local function clearSession(session: Session)
	session.over = true
	if session.messenger then
		session.messenger:Destroy()
		session.messenger = nil
	end
	sessions[session.id] = nil
	if sessionByPlayer[session.thief] == session then
		sessionByPlayer[session.thief] = nil
	end
	if sessionByPlayer[session.victim] == session then
		sessionByPlayer[session.victim] = nil
	end
	push(session)
end

-- Nobody settled: the thief keeps a soured specialist and wears the cost.
local function resolveUnsettled(session: Session, why: string)
	if session.over then
		return
	end
	session.message = why
	reputationDeltaSignal:Fire(session.thief, CAP_REPUTATION_PENALTY,
		("would not settle over %s's %s"):format(session.victim.Name, session.role))

	-- The specialist sours. This is the half of the cost that bites NOW -
	-- reputation has no consumer until merchants exist, so on its own it would
	-- be a number in a log and no reason to settle.
	local soured = math.max(1, session.rank - 1)
	specialistSetSignal:Fire(session.thief, session.role, soured, true)

	notify(session.thief, ("No deal over the %s. They are worth less to you now."):format(session.role))
	notify(session.victim, ("No deal. Your %s is gone for good."):format(session.role))
	clearSession(session)
end

local function settle(session: Session)
	if session.over then
		return
	end
	local purse = counterFor(session.victim, session.resource)
	if not purse or purse.Value < session.demand then
		-- They agreed to something they can no longer pay. Treat it as a
		-- failure to settle rather than silently handing over a specialist for
		-- nothing.
		resolveUnsettled(session, "the ransom could not be paid")
		return
	end
	purse.Value -= session.demand
	local paid = counterFor(session.thief, session.resource)
	if paid then
		paid.Value += session.demand
	end

	-- Out of the thief's hands and back into the victim's at FULL efficiency:
	-- they were ransomed, not re-stolen, so the 85% penalty does not follow
	-- them home.
	specialistSetSignal:Fire(session.thief, session.role, nil, false)
	specialistSetSignal:Fire(session.victim, session.role, session.rank, false)

	session.message = ("Settled at %d %s"):format(session.demand, session.resource)
	notify(session.thief, ("Paid %d %s for %s's %s"):format(
		session.demand, session.resource, session.victim.Name, session.role))
	notify(session.victim, ("Bought back your %s for %d %s"):format(
		session.role, session.demand, session.resource))
	clearSession(session)
end

-- ---------------------------------------------------------------- opening
local function villageOf(player: Player): Model?
	local sites = Workspace:FindFirstChild("BuildSites")
	if not sites then
		return nil
	end
	for _, base in sites:GetChildren() do
		if base:GetAttribute("Owner") == player.UserId then
			return base :: Model
		end
	end
	return nil
end

local function placeMessenger(session: Session)
	local template = ServerStorage:FindFirstChild("MessengerTemplate")
	if not template or not template:IsA("Model") then
		return
	end
	local folder = Workspace:FindFirstChild("Messengers")
	if not folder then
		folder = Instance.new("Folder")
		;(folder :: Folder).Name = "Messengers"
		;(folder :: Folder).Parent = Workspace
	end

	-- Outside the victim's gate if they still have a village, otherwise beside
	-- them - a messenger with nowhere to stand should still arrive.
	local at: CFrame
	local village = villageOf(session.victim)
	local gate = village and village:FindFirstChild("Gate")
	local foundation = village and village:FindFirstChild("Foundation")
	if gate and gate:IsA("BasePart") and foundation and foundation:IsA("BasePart") then
		local outward = gate.Position - foundation.Position
		outward = Vector3.new(outward.X, 0, outward.Z).Unit
		at = CFrame.lookAt(gate.Position + outward * 9, gate.Position)
	else
		local character = session.victim.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			at = root.CFrame * CFrame.new(0, 0, -8)
		else
			return
		end
	end

	local messenger = template:Clone()
	messenger.Name = ("Messenger_%d"):format(session.id)
	messenger:SetAttribute("SessionId", session.id)
	messenger.Parent = folder
	messenger:PivotTo(at * CFrame.new(0, 0.5, 0))
	session.messenger = messenger
end

local function openSession(thief: Player, victim: Player, role: string, rank: number)
	-- One at a time per player. A second theft while a negotiation is live just
	-- means the second specialist is kept; stacking panels would be unreadable
	-- and the doc says nothing about parallel negotiations.
	if sessionByPlayer[thief] or sessionByPlayer[victim] then
		return
	end

	nextId += 1
	local resource = ransomCurrency(victim)
	local opening = math.max(1, rank * RANSOM_PER_RANK)
	local session: Session = {
		id = nextId,
		thief = thief,
		victim = victim,
		role = role,
		rank = rank,
		resource = resource,
		demand = opening,
		opening = opening,
		round = 1,
		-- The victim moves first: the thief's demand is already on the table.
		turn = victim,
		messenger = nil,
		message = ("%s demands %d %s for your %s"):format(thief.Name, opening, resource, role),
		over = false,
		deadline = os.clock() + TURN_SECONDS,
	}
	sessions[session.id] = session
	sessionByPlayer[thief] = session
	sessionByPlayer[victim] = session

	placeMessenger(session)
	notify(thief, ("Your messenger has gone to %s"):format(victim.Name))
	notify(victim, ("%s's messenger is at your gate"):format(thief.Name))
	push(session)
end

-- ---------------------------------------------------------------- acting
local function act(player: Player, action: unknown, amount: unknown)
	local session = sessionByPlayer[player]
	if not session or session.over then
		return
	end
	if session.turn ~= player then
		return
	end
	if typeof(action) ~= "string" then
		return
	end

	if action == "accept" then
		if player == session.victim and held(session.victim, session.resource) < session.demand then
			notify(session.victim, ("You cannot raise %d %s"):format(session.demand, session.resource))
			return
		end
		settle(session)
		return
	end

	if action == "refuse" then
		resolveUnsettled(session, ("%s refused"):format(player.Name))
		return
	end

	if action ~= "counter" then
		return
	end

	-- Everything below is a counter, and every part of it is re-checked. This
	-- is the project's first client-supplied value; the client is only ever
	-- telling us what it WANTS.
	if typeof(amount) ~= "number" or amount ~= amount or amount == math.huge then
		return
	end
	local proposed = math.clamp(math.floor(amount), 0, session.opening * COUNTER_CEILING)

	session.demand = proposed
	session.turn = if player == session.victim then session.thief else session.victim
	session.deadline = os.clock() + TURN_SECONDS

	-- A round is one exchange. It ticks when the ball returns to the victim,
	-- so both sides always get an equal number of moves.
	if player == session.thief then
		session.round += 1
	end

	session.message = ("%s offers %d %s"):format(player.Name, proposed, session.resource)

	if session.round > MAX_ROUNDS then
		resolveUnsettled(session, "the talks ran out of rounds")
		return
	end
	push(session)
end

actRemote.OnServerEvent:Connect(function(player: Player, action: unknown, amount: unknown)
	local ok, err = pcall(act, player, action, amount)
	if not ok then
		warn(("[Negotiation] %s sent something that broke act(): %s"):format(player.Name, tostring(err)))
	end
end)

-- ---------------------------------------------------------------- escalation
messengerStruckSignal.Event:Connect(function(striker: Player, messenger: Model)
	local id = messenger:GetAttribute("SessionId")
	local session = if typeof(id) == "number" then sessions[id] else nil
	if not session or session.over then
		if messenger.Parent then
			messenger:Destroy()
		end
		return
	end
	if striker ~= session.thief and striker ~= session.victim then
		return
	end

	reputationDeltaSignal:Fire(striker, MESSENGER_REPUTATION_PENALTY, "killed a messenger")
	striker:SetAttribute("LabourPausedUntil", os.clock() + MESSENGER_LABOUR_PAUSE)

	local other = if striker == session.thief then session.victim else session.thief
	notify(striker, ("You killed the messenger. Your own people have downed tools for %ds."):format(
		MESSENGER_LABOUR_PAUSE))
	notify(other, ("%s killed the messenger"):format(striker.Name))
	resolveUnsettled(session, ("%s killed the messenger"):format(striker.Name))
end)

specialistStolenSignal.Event:Connect(function(thief: Player, victim: Player, role: string, rank: number)
	local ok, err = pcall(openSession, thief, victim, role, rank)
	if not ok then
		warn("[Negotiation] could not open a session: " .. tostring(err))
	end
end)

-- ---------------------------------------------------------------- timeouts
task.spawn(function()
	while true do
		task.wait(1)
		for _, session in sessions do
			if not session.over and os.clock() > session.deadline then
				resolveUnsettled(session, "nobody answered the messenger")
			end
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	local session = sessionByPlayer[player]
	if session and not session.over then
		resolveUnsettled(session, ("%s left"):format(player.Name))
	end
end)
