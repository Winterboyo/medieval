--!strict
-- Original R15 run cycle. In Studio, the authored sequence is registered for
-- preview. A published Animation ID on SiegeRun enables the same cycle in live.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")

local sequence = ReplicatedStorage:WaitForChild("Animations"):WaitForChild("SiegeRun") :: KeyframeSequence

local function animationId(): string?
	local published = sequence:GetAttribute("PublishedAnimationId")
	if typeof(published) == "number" and published > 0 then
		return "rbxassetid://" .. tostring(published)
	end
	if RunService:IsStudio() then
		local ok, id = pcall(function()
			return KeyframeSequenceProvider:RegisterKeyframeSequence(sequence)
		end)
		if ok then return id end
		warn("SiegeRun preview could not register:", id)
	end
	return nil
end

local function apply(character: Model)
	local id = animationId()
	if not id then return end
	local animate = character:WaitForChild("Animate", 10)
	if not animate then return end
	for _, slotName in { "walk", "run" } do
		local slot = animate:WaitForChild(slotName, 10)
		if slot then
			local function bind(clip: Instance)
				if not clip:IsA("Animation") then return end
				local function enforce()
					if clip.AnimationId ~= id then clip.AnimationId = id end
				end
				clip:GetPropertyChangedSignal("AnimationId"):Connect(enforce)
				enforce()
			end
			for _, child in slot:GetChildren() do bind(child) end
			slot.ChildAdded:Connect(bind)
		end
	end
end

local player = Players.LocalPlayer
if player.Character then task.spawn(apply, player.Character) end
player.CharacterAdded:Connect(apply)
