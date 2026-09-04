--!strict
-- Villagers walk here, on the client, and nowhere else.
--
-- They are decoration: no player outcome depends on where a villager is
-- standing. Walking them on the server would spend replication every frame, on
-- sixty-four rigs, forever, to change nothing about the game. Anchored parts
-- CFramed locally do not replicate back, so each player animates only what is
-- near their own camera and the server never learns it happened.
--
-- There is no Humanoid, no Animator, no Animation asset and no pathfinding. The
-- rig carries its own layout as attributes (see makeVillager in build-world),
-- so nothing here hardcodes a hip height - change a limb there and this follows.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

-- Beyond this a villager simply stands still. Nobody can tell at 260 studs, and
-- it means a full sixteen-village world animates a handful of rigs, not 64.
local ACTIVE_RADIUS = 260
local CULL_INTERVAL = 0.45
local STRIDE = 0.7 -- radians of leg swing at full walk
local PAUSE = 2.4 -- seconds spent at each end of a patrol
local BOB = 0.11 -- studs of vertical bounce per step
local MAX_STEP = 0.1 -- a hitched frame must not teleport anybody

type Limb = { part: BasePart, rest: CFrame, pivot: CFrame, swing: number }
type Villager = {
	limbs: { Limb },
	a: Vector3,
	b: Vector3,
	length: number,
	legLength: number,
	speed: number,
	phase: number,
	u: number,
	dir: number,
	wait: number,
	cycle: number,
	gait: number,
	active: boolean,
}

local villagers: { [Model]: Villager } = {}

local function adopt(model: Model)
	if villagers[model] then
		return
	end
	local a = model:GetAttribute("PatrolA")
	local b = model:GetAttribute("PatrolB")
	if typeof(a) ~= "Vector3" or typeof(b) ~= "Vector3" then
		return
	end

	local limbs: { Limb } = {}
	for _, child in model:GetChildren() do
		if child:IsA("BasePart") then
			local rest = child:GetAttribute("Rest")
			local pivot = child:GetAttribute("Pivot")
			if typeof(rest) == "CFrame" and typeof(pivot) == "CFrame" then
				limbs[#limbs + 1] = {
					part = child,
					rest = rest,
					pivot = pivot,
					swing = (child:GetAttribute("Swing") :: number?) or 0,
				}
			end
		end
	end
	if #limbs == 0 then
		return
	end

	-- Phase spreads them out in time. Sixteen villagers stepping in unison reads
	-- as a chorus line, which is worse than not moving at all.
	local phase = (model:GetAttribute("Phase") :: number?) or 0
	villagers[model] = {
		limbs = limbs,
		a = a,
		b = b,
		length = math.max((b - a).Magnitude, 1),
		legLength = (model:GetAttribute("LegLength") :: number?) or 2.2,
		speed = (model:GetAttribute("Speed") :: number?) or 3.5,
		phase = phase,
		u = phase,
		dir = if phase > 0.5 then -1 else 1,
		wait = phase * PAUSE,
		cycle = phase * 6.2,
		gait = 0,
		active = false,
	}
end

local function step(villager: Villager, dt: number)
	local moving = false
	if villager.wait > 0 then
		villager.wait -= dt
	else
		moving = true
		villager.u += (villager.speed * dt / villager.length) * villager.dir
		if villager.u >= 1 then
			villager.u, villager.dir = 1, -1
			villager.wait = PAUSE * (0.6 + villager.phase)
		elseif villager.u <= 0 then
			villager.u, villager.dir = 0, 1
			villager.wait = PAUSE * (0.6 + villager.phase)
		end
	end

	-- Gait eases in and out, so a villager settles onto both feet when it stops
	-- rather than freezing mid-stride with one leg in the air.
	villager.gait += ((if moving then 1 else 0) - villager.gait) * math.min(dt * 6, 1)
	if moving then
		villager.cycle += dt * villager.speed * 1.7
	end

	local swing = math.sin(villager.cycle) * STRIDE * villager.gait

	-- FEET ON THE GROUND. A rigid leg pivoting at the hip always shortens its
	-- vertical reach - the foot rises by legLength * (1 - cos t). Both legs sit
	-- at +t and -t and cosine is even, so BOTH feet rise by the same amount and
	-- the villager hovers at the peak of every stride. Dropping the root by
	-- exactly that much plants them: measured at 0.000 studs across the cycle.
	local dip = villager.legLength * (1 - math.cos(swing))

	local position = villager.a:Lerp(villager.b, villager.u)
		+ Vector3.new(0, math.abs(math.sin(villager.cycle)) * BOB * villager.gait - dip, 0)

	local heading = (villager.b - villager.a) * villager.dir
	heading = Vector3.new(heading.X, 0, heading.Z)
	local root = if heading.Magnitude > 0.01
		then CFrame.lookAt(position, position + heading)
		else CFrame.new(position)

	for _, limb in villager.limbs do
		if limb.swing == 0 then
			limb.part.CFrame = root * limb.rest
		else
			-- Rotate the limb about its joint, not about its own centre: shift
			-- into pivot space, turn, shift back.
			local turn = CFrame.Angles(swing * limb.swing, 0, 0)
			limb.part.CFrame = root * limb.pivot * turn * limb.pivot:Inverse() * limb.rest
		end
	end
end

local sinceCull = CULL_INTERVAL
local function cull()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local eye = camera.CFrame.Position
	for _, villager in villagers do
		villager.active = (villager.a - eye).Magnitude < ACTIVE_RADIUS
	end
end

local sites = Workspace:WaitForChild("BuildSites", 30)
if not sites then
	return
end

-- Villages are BUILT DURING THE MATCH: a villager does not exist until its
-- owner pays for the cottage and ResourceService reparents the stage into the
-- world. So the roster is discovered as it arrives, not enumerated once.
for _, descendant in sites:GetDescendants() do
	if descendant:IsA("Model") and descendant.Name == "Villager" then
		adopt(descendant)
	end
end
sites.DescendantAdded:Connect(function(descendant)
	if descendant:IsA("Model") and descendant.Name == "Villager" then
		adopt(descendant)
	end
end)
sites.DescendantRemoving:Connect(function(descendant)
	if descendant:IsA("Model") then
		villagers[descendant] = nil
	end
end)

RunService.Heartbeat:Connect(function(dt)
	dt = math.min(dt, MAX_STEP)
	sinceCull += dt
	if sinceCull >= CULL_INTERVAL then
		sinceCull = 0
		cull()
	end
	for _, villager in villagers do
		if villager.active then
			step(villager, dt)
		end
	end
end)
