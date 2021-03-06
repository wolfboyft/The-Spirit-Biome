local input = require("input")
local constants = require("constants")
local settings = require("settings")
local components = require("components")
local movement = require("lib.concord.system")(
	{"mobs", components.presence, components.velocity, components.mobility},
	{"presences", components.presence}
)

local movementCommandsToCheck = {
	advance = true,
	strafeLeft = true,
	backpedal = true,
	strafeRight = true,
	turnLeft = true,
	turnRight = true,
	run = true,
	sneak = true
}

function movement:init()
	
end

function movement:execute(dt)
	self.moved = {}
	
	for i = 1, self.presences.size do
		local presence = self.presences:get(i):get(components.presence)
		presence.previousX, presence.previousY, presence.previousTheta = presence.x, presence.y, presence.theta
	end
	
	for i = 1, self.mobs.size do
		local entity = self.mobs:get(i)
		
		local commands = {}
		do -- Get commands
			local ai = entity:get(components.ai)
			local player = entity:get(components.player)
			
			if ai then
				-- TODO
			else
				for command in pairs(movementCommandsToCheck) do
					commands[command] = input.checkFixedUpdateCommand(command)
				end
			end
		end
		
		-- Get speed multiplier
		local speedMultiplier
		if commands.sneak and not commands.run then
			speedMultiplier = 0.25
		elseif not commands.run then
			speedMultiplier = 0.5
		else
			speedMultiplier = 1
		end
		
		local mobility = entity:get(components.mobility)
		local velocity = entity:get(components.velocity)
		
		-- Abstraction for getting target velocity and change (acceleration/deceleration)
		local function getVelocities(negative, positive, current)
			-- TODO: optimise writing
			local target, change
			if commands[negative] and not commands[positive] then
				target = -mobility.maxTargetVel[negative] * speedMultiplier
				if current < target then
					if current > 0 then
						change = -mobility.maxDecel[negative]
					else
						change = -mobility.maxAccel[negative]
					end
				elseif current > target then
					if current > 0 then
						change = -mobility.maxDecel[negative]
					else -- current >= 0
						change = -mobility.maxAccel[negative]
					end
				else -- current - target = 0
					change = 0
				end
			elseif commands[positive] and not commands[negative] then
				target = mobility.maxTargetVel[positive] * speedMultiplier
				if current > target then
					if current < 0 then
						change = mobility.maxDecel[positive]
					else
						change = mobility.maxAccel[positive]
					end
				elseif current < target then
					if current < 0 then
						change = mobility.maxDecel[positive]
					else
						change = mobility.maxAccel[positive]
					end
				else
					change = 0
				end
			else
				target = 0
				if current > target then
					change = -mobility.maxDecel[negative]
				elseif current < target then
					change = mobility.maxDecel[positive]
				else
					change = 0
				end
			end
			return target, change * speedMultiplier
		end
		
		-- Abstraction for using target and change velocities
		local function useVelocities(current, target, change)
			if change > 0 then
				return math.min(target, current + change * dt)
			elseif change < 0 then
				return math.max(target, current + change * dt)
			end
			
			return current
		end
		
		local presence = entity:get(components.presence)
		
		-- Deal with theta
		velocity.theta = useVelocities(velocity.theta, getVelocities("turnLeft", "turnRight", velocity.theta))
		presence.theta = (presence.theta + velocity.theta * dt) % math.tau
		
		do -- Deal with x and y
			local cosine, sine = math.cos(presence.theta), math.sin(presence.theta)
			
			-- Get velocity rotated clockwise
			local relativeVelocityX = velocity.x * cosine + velocity.y * sine
			local relativeVelocityY = velocity.y * cosine - velocity.x * sine
			
			-- Get target and change
			local relativeTargetVelocityX, relatveVelocityChangeX = getVelocities("strafeLeft", "strafeRight", relativeVelocityX)
			local relativeTargetVelocityY, relatveVelocityChangeY = getVelocities("advance", "backpedal", relativeVelocityY)
			
			-- Abstraction to clamp them to an ellipse-like shape (TODO: explain)
			local function clamp(x, y)
				if x ~= 0 and y ~= 0 then
					local currentMag = math.distance(x, y)
					local xSize, ySize = math.abs(x), math.abs(y)
					local maxMag = math.min(xSize, ySize)
					x, y = x / currentMag * maxMag, y / currentMag * maxMag
					x = x * math.max(xSize / ySize, 1)
					y = y * math.max(ySize / xSize, 1)
				end
				return x, y
			end
			
			-- Get clamped velocities
			relativeTargetVelocityX, relativeTargetVelocityY = clamp(relativeTargetVelocityX, relativeTargetVelocityY)
			relatveVelocityChangeX, relatveVelocityChangeY = clamp(relatveVelocityChangeX, relatveVelocityChangeY)
			
			-- Use the velocities
			relativeVelocityX = useVelocities(relativeVelocityX, relativeTargetVelocityX, relatveVelocityChangeX)
			relativeVelocityY = useVelocities(relativeVelocityY, relativeTargetVelocityY, relatveVelocityChangeY)
			
			-- Rotate it back anticlockwise
			local newVelocityX = relativeVelocityX * cosine - relativeVelocityY * sine
			local newVelocityY = relativeVelocityY * cosine + relativeVelocityX * sine
			if newVelocityX ~= velocity.x or newVelocityY ~= velocity.y then
				table.insert(self.moved, entity)
			end
			
			velocity.x = newVelocityX
			velocity.y = newVelocityY
		end
		
		-- Add velocity to position
		presence.x, presence.y = presence.x + velocity.x * dt, presence.y + velocity.y * dt
	end
end

function movement:correct()
	local randomShifts, randomShiftMagnitudes = {}, {}
	local xShifts, yShifts = {}, {}
	
	for i = 1, self.presences.size do
		local entity = self.presences:get(i)
		local presence = entity:get(components.presence)
		
		if presence.clip then
			for other, vector in pairs(self:getInstance().collider:collisions(presence.shape)) do
				-- Make sure the other shape also clips, and also make sure it can move
				if other.bag.clip and other.bag.owner:get(components.velocity) then
					local pusherImmovability, pusheeImmovability = presence.immovability, other.bag.immovability
					local pusherFactor -- How much of the vector moves the pusher
					if pusheeImmovability == pusherImmovability then
						pusherFactor = 0.5
					elseif pusheeImmovability == math.huge and pusherImmovability ~= math.huge then
						pusherFactor = 1
					elseif pusheeImmovability ~= math.huge and pusherImmovability == math.huge then
						pusherFactor = 0
					else
						pusherFactor = pusheeImmovability / (pusherImmovability + pusheeImmovability)
					end
					local pusheeFactor = 1 - pusherFactor
					local vx, vy = vector.x, vector.y
					if presence.x == other.bag.x and presence.y == other.bag.y then
						-- If we're in the same place then we push in a pseudorandom direction (deterministic, of course)
						table.insert(randomShifts, other.bag)
						randomShiftMagnitudes[other.bag] = pusheeFactor * math.distance(vx, vy)
					else
						xShifts[other.bag] = xShifts[other.bag] and xShifts[other.bag] + pusheeFactor * -vx or pusheeFactor * -vx
						yShifts[other.bag] = yShifts[other.bag] and yShifts[other.bag] + pusheeFactor * -vy or pusheeFactor * -vy
						xShifts[presence] = xShifts[presence] and xShifts[presence] + pusherFactor * vx or pusherFactor * vx
						yShifts[presence] = yShifts[presence] and yShifts[presence] + pusherFactor * vy or pusherFactor * vy
					end
				end
			end
		end
	end
	
	table.sort(randomShifts,
		function(i, j)
			-- Determinism is maintained because Concord's pool order is deterministic
			return self.presences.pointers[i.owner] < self.presences.pointers[j.owner]
		end
	)
	
	local rng = self:getInstance().rng
	
	for _, pushedPresence in ipairs(randomShifts) do
		local vx, vy = math.polarToCartesian(
			randomShiftMagnitudes[pushedPresence],
			rng:random() * math.tau
		)
		xShifts[pushedPresence] = xShifts[pushedPresence] and xShifts[pushedPresence] + vx or vx
		yShifts[pushedPresence] = yShifts[pushedPresence] and yShifts[pushedPresence] + vy or vy
	end
	
	for shiftee, xAmount in pairs(xShifts) do
		shiftee.x = shiftee.x + xAmount
		shiftee.y = shiftee.y + yShifts[shiftee] -- If you shift on the x only you'll still have a 0 in the yShifts
	end
	
	for i = 1, self.presences.size do
		local entity = self.presences:get(i)
		local presence = entity:get(components.presence)
		
		presence.shape:moveTo(presence.x, presence.y)
	end
end

return movement
