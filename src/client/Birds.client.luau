--!strict
-- The flock over the totem, animated on the client for the same reason the
-- villagers are: nothing depends on where a bird is, so the server should never
-- spend a byte replicating one. See Villagers.client.luau for the full argument.
--
-- Birds are the cheapest possible fix for the largest empty surface in the
-- game. They also mark the middle of the board from a long way off, which is
-- worth something on an island where the totem itself is hidden by terrain.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ACTIVE_RADIUS = 1100 -- generous: a bird 50 studs up is visible a long way off
local CULL_INTERVAL = 0.6
local WING_BEAT = 0.85 -- radians at the top of a beat
local MAX_STEP = 0.1

type Wing = { part: BasePart, rest: CFrame, pivot: CFrame, sign: number }
type Bird = {
	body: BasePart,
	rest: CFrame,
	wings: { Wing },
	radius: number,
	height: number,
	speed: number,
	flap: number,
	angle: number,
	beat: number,
}

local flock = Workspace:WaitForChild("Birds", 30)
if not flock then
	return
end
local centre = (flock:GetAttribute("Centre") :: Vector3?) or Vector3.zero

local birds: { Bird } = {}

-- A FOLDER REPLICATES BEFORE ITS CONTENTS DO. Enumerating once, the instant
-- WaitForChild returned, found the folder empty and left the whole flock frozen
-- with no error to show for it - the failure mode of a one-shot scan against a
-- tree that is still arriving. Rescanning whenever a descendant lands costs a
-- couple of dozen cheap passes at join and nothing at all afterwards.
local function rescan()
	table.clear(birds)
	for _, model in flock:GetChildren() do
		if model:IsA("Model") and model.PrimaryPart then
			local body = model.PrimaryPart
			local wings: { Wing } = {}
			for _, child in model:GetChildren() do
				local sign = (child:GetAttribute("Wing") :: number?) or 0
				if child:IsA("BasePart") and sign ~= 0 then
					wings[#wings + 1] = {
						part = child,
						rest = (child:GetAttribute("Rest") :: CFrame?) or CFrame.new(),
						pivot = (child:GetAttribute("Pivot") :: CFrame?) or CFrame.new(),
						sign = sign,
					}
				end
			end
			birds[#birds + 1] = {
				body = body,
				rest = (body:GetAttribute("Rest") :: CFrame?) or CFrame.new(),
				wings = wings,
				radius = (model:GetAttribute("Radius") :: number?) or 40,
				height = (model:GetAttribute("Height") :: number?) or 50,
				speed = (model:GetAttribute("Speed") :: number?) or 0.25,
				flap = (model:GetAttribute("Flap") :: number?) or 6,
				angle = (model:GetAttribute("Phase") :: number?) or 0,
				beat = (model:GetAttribute("Phase") :: number?) or 0,
			}
		end
	end
end

rescan()
flock.DescendantAdded:Connect(rescan)

local active = true
local sinceCull = CULL_INTERVAL

RunService.Heartbeat:Connect(function(dt)
	dt = math.min(dt, MAX_STEP)

	sinceCull += dt
	if sinceCull >= CULL_INTERVAL then
		sinceCull = 0
		local camera = Workspace.CurrentCamera
		active = camera ~= nil and (camera.CFrame.Position - centre).Magnitude < ACTIVE_RADIUS
	end
	if not active then
		return
	end

	for _, bird in birds do
		bird.angle += bird.speed * dt
		bird.beat += bird.flap * dt

		-- A slow rise and fall on top of the circle, so the ring does not read
		-- as a turntable.
		local lift = math.sin(bird.angle * 1.7) * 3.5
		local position = centre
			+ Vector3.new(
				math.cos(bird.angle) * bird.radius,
				bird.height + lift,
				math.sin(bird.angle) * bird.radius
			)

		-- Facing is the tangent to the circle: the derivative of the position,
		-- which is a quarter turn ahead of where the bird currently is.
		local heading = Vector3.new(-math.sin(bird.angle), 0, math.cos(bird.angle))
		-- Bank into the turn. Anything circling flat looks like it is on a wire.
		local bank = math.clamp(bird.speed * bird.radius * 0.055, 0, 0.5)
		local root = CFrame.lookAt(position, position + heading) * CFrame.Angles(0, 0, -bank)

		bird.body.CFrame = root * bird.rest
		local beat = math.sin(bird.beat) * WING_BEAT
		for _, wing in bird.wings do
			-- Wings hinge at the shoulder about the bird's own forward axis, so
			-- the pair beats mirrored rather than both tipping the same way.
			local turn = CFrame.Angles(0, 0, beat * wing.sign)
			wing.part.CFrame = root * wing.pivot * turn * wing.pivot:Inverse() * wing.rest
		end
	end
end)
