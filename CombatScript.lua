--[[
COMBAT FRAMEWORK 
 This Script is for a combat framework 
 
 
 Overview :
 A Combat Instance is created for the character on spawn
 Cooldowns are managed on the server to prevent exploits
 The Combat instance are stored inside tables to allow easy tracking 
 Different states are replicated with the player's character through attributes
 Changes to the client automatically replicate through these states 
 Client stores cooldown flags inside a table locally to prevent overrides and animation desyncs
 Cooldown updates replicate to the client to keep the animations synchronized


   
Minimal Server Code ~

Players.PlayerAdded:Connect(function(player)
 
	player.CharacterAdded:Connect(function(character)
		CombatFramework:Register(character)

	end)
end)

]]

--!optimize 2

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local combatRemote = ReplicatedStorage.Remotes:FindFirstChild("CombatRemote")

-- Combat State
local Combat = {}
Combat.__index = Combat

-- Validation Layer 
local allowedEvents = {
	Punch = "Punch" , Block = "Block" , UnBlock = "UnBlock" , Dash = "Dash"
}

-- Config Values (Tuning Constants)
local CONFIG = {
	stunCooldown = 1.75,
	stunKnockBack = 25,

	maxDistance = 8,

	-- Event Implentation Because The cooldown completion logic was being used from two places
	punchCooldown = {Cooldown = 0.75 , Event = function(playerCombat) 
		playerCombat:ResetHumanoid()
	end,
	} ,
	comboResetTimer = 5,
	damage = 10,

	ragdollCooldown = 2 ,
	ragdollKnockBack = 50,

	dashDelay = 1,
	dashCooldown = 5 ,
	dashForce = 60 ,

}

-- States that will be replicated on "Register"
local REPLICATED_STATES = {
	IsStunned = false ,
	IsRagdoll = false ,
	IsBlocking = false ,
	IsDashing  = false ,
	ComboCount = 1
	
}

-- Active Combat States
local playerCombats = {}
local npcCombats  = {}


-- Each character to be granted their own Combat Instance
-- To prevent the states and cooldowns from being duplicated
function Combat.new(character :Model)
	if not character then 
		return
	end
	local self = setmetatable({} , Combat)
	
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")

	if not humanoid or not humanoidRootPart then 
		return
	end
	  
	  
	self.Character = character
	self.Humanoid = humanoid
	self.HumanoidRootPart = humanoidRootPart

	self.Cooldowns = {}

	-- Create a event listener to listen to any state changes and fire them to the client 
	self.Events = {
		OnChanged = {},
	}

	return self
end

-- Register the connections and states 
-- The Event Connections are set with the object so that we can easily change the combat instance on event trigger or replicate any changes to the client
function Combat:Register(character :Model)
local combat = self.new(character)

	local player = Players:GetPlayerFromCharacter(character)

 
    for stateName , stateValue in REPLICATED_STATES do
		combat:SetState(stateName , stateValue )
    end
	
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	 
		combat.DeathConnection = humanoid.Died:Connect(function()
		
		    combat:Destroy()

		    if npcCombats[character] then
			 npcCombats[character] = nil
			 return
		   end

		   if playerCombats[player.UserId] then
			 playerCombats[player.UserId] = nil
			 return
		   end	
			
			
		end)
	
		
		if not player then
		   npcCombats[character] = combat
		  return combat 
	    end
	
	   playerCombats[player.UserId] = combat
				
		combat.Leaving = Players.PlayerRemoving:Connect(function(player)
			playerCombats[player.UserId]:Destroy()
			playerCombats[player.UserId] = nil
		end)


	combat:OnChanged(function(cooldown , value)
		combatRemote:FireClient(player , cooldown , value)
	end)
	
	 return combat
end

-- Destroy the character's combat instance to prevent memory leaks and to prevent the combat from being desynced
function Combat:Destroy()
	if self.DeathConnection and self.Leaving then 
		self.DeathConnection:Disconnect()
		self.Leaving:Disconnect()
       
	end
	for _, callbacks in pairs(self.Events) do
		table.clear(callbacks)
	end
	
	for _, v in pairs(self)  do
		if typeof(v) == "RBXScriptConnection" then
			v:Disconnect()
		end
	end
	table.clear(self)
end

-- Retreive the combat instance of a model and replicate changes to the client 
function Combat:GetCombat(descendant:Instance)
	local targetModel 

	if descendant and descendant:IsA("Model") then
		targetModel = descendant
	else
		targetModel = descendant and descendant:FindFirstAncestorOfClass("Model")
	end

	if not targetModel then 
		return nil  
	end	 

	local player = Players:GetPlayerFromCharacter(targetModel) 
	local targetCombat = player and playerCombats[player.UserId] or npcCombats[targetModel]
	
	assert(targetCombat , "combat instance is missing ~!!!")
	return targetCombat 
end


function Combat:ApplyHumanoidProperties(speed , height , canrotate)
	if not self.Character then
		return
	end
	local selfHumanoid = self.Humanoid

	if not self.Humanoid then 
		return
	end

	selfHumanoid.WalkSpeed = speed
	selfHumanoid.JumpPower = height
	selfHumanoid.AutoRotate = canrotate

end


-- Insert The methods that will be called later when a state change occurs
function Combat:OnChanged(callback)
	table.insert(self.Events.OnChanged , callback)
end


-- Callback all the functions tied to a specific event to replicate changes to the client  
function Combat:Callback(eventCall:string , ...)
	local events = self.Events[eventCall]
	assert(events , "Invalid Call ~!!!")
	if not events then 
		return 
	end

	for _ , callback in ipairs(events) do
		callback(...)
	end
end


-- Uses spatial queries for more consistent hit detection and to prevent physics based exploits
-- Reuses the same hitbox and humanoid container to prevent memory leaks
function Combat:QueryHits(range , size , ignorelist)
	local overlapParams = self.OverlapParams or OverlapParams.new()

	if not self.OverlapParams then 
		self.OverlapParams = overlapParams
	end

	if self.hitHumanoids then
		table.clear(self.hitHumanoids)
	end

	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = ignorelist

	local parts = workspace:GetPartBoundsInBox(range , size , overlapParams)
	self.hitHumanoids = {}

	for _, part in ipairs(parts) do
		local targetmodel = part:FindFirstAncestorOfClass("Model")

		if not targetmodel or not targetmodel.PrimaryPart  then
			continue
		end

		local targetHumanoid = targetmodel and targetmodel:FindFirstChildOfClass("Humanoid")

		if  targetHumanoid and targetHumanoid.Health > 0  then 
			if not self.hitHumanoids[targetHumanoid] then
				self.hitHumanoids[targetHumanoid] = true
			end
		end		

	end
	return self.hitHumanoids
end


--[[ 
 Handle the all the targets that got caught in the player's hitbox
 Check the distance between the target's character and the character to prevent exploit
 Check if the target's character doesn't have the ragdoll state enabled to ensure consistent combat
 Decide whether to stun or ragdoll them depending on the character's combo threshold 
 ]]
function Combat:HandleHits(hits)

	local selfHumanoidRootPart = self.HumanoidRootPart

	if not self:CanAct() then
		return
	end
	 
	 if self.LastTimeHit then
	     table.clear(self.LastTimeHit)	
	 end
	 self.LastTimeHit = {}
	for keyHumanoid  in pairs(hits) do

		local targetCombat = self:GetCombat(keyHumanoid)
		local targetPrimaryPart :BasePart = targetCombat.HumanoidRootPart
			  
	   
		if not targetPrimaryPart then
			continue
		end

		local distance = (selfHumanoidRootPart.Position - targetPrimaryPart.Position).Magnitude
		
		
		if distance > CONFIG.maxDistance 
			or  targetPrimaryPart.AssemblyLinearVelocity.Magnitude > 100 
			or self.LastTimeHit[keyHumanoid] and self.LastTimeHit[keyHumanoid] - os.clock()  < 0.2 
		then
			continue
		end

 
		if targetCombat:GetState("IsRagdoll") then 
			continue 
		end

		if not self:CheckBlockAngle(keyHumanoid) then
			continue 
		end

		keyHumanoid:TakeDamage(CONFIG.damage)
		self.LastTimeHit[keyHumanoid] = os.clock()
		self:ApplyHitEffect(keyHumanoid)


	end	
end


function Combat:IncrementCombo()
	local combo = self:GetState("ComboCount")
	combo += 1

	if combo > 4 then
		combo = 1
	end	

	self:SetState("ComboCount",  combo )	
end	


-- Check the main states to ensure the character is in the suitable state for a combat action
function Combat:CanAct()
	local selfHumanoid = self.Humanoid
	return not (
		self:GetState("IsStunned")  or 
			self:GetState("IsRagdoll")  or 
			self:GetState("IsBlocking") or 
			self:GetState("IsDashing")  or
			selfHumanoid.Health <= 0		
	)
end

-- Set the states using attributes to allow replication to the client
function Combat:SetState(name , value)
	local character = self.Character
	if not character then
		return
	end
	character:SetAttribute(name , value)

end

function Combat:GetState(name)
	local character = self.Character
	return character:GetAttribute(name)
end


-- Unstun the character to prevent freeze
-- This is to ensure that the player can escape if the enemy has stopped punching
function Combat:UnStun()	
	if self.revertStun  then
		task.cancel(self.revertStun)
		self.revertStun = nil
	end
	if self:GetState("IsRagdoll") then 
		return 
	end

	self.revertStun = task.delay(CONFIG.stunCooldown , function()
		self:SetState("IsStunned" , false)
		self:ResetHumanoid()
	end)

end


-- This method is used to freeze the  character's humanoid 
-- It is used mainly for the stun so that the target can't escape while being punched
function Combat:FreezeHumanoid()
	self:ApplyHumanoidProperties(0 , 0 , false)
end


-- This method is used to unfreeze the character's humanoid
function Combat:ResetHumanoid()
	self:ApplyHumanoidProperties(16 , 50 , true)
end


--[[ 
 Enable the "Ragdoll" state for the target's character
 To prevent the enemy from attacking while the target's character is knocked out  
 and to ensure consistent combat between the players 
 ]]

function Combat:Ragdoll()
	local selfHumanoid = self.Humanoid
	if self:GetState("IsRagdoll") then 
		return 
	end 

	if selfHumanoid.Health <= 0  then 
		return 
	end

	self:SetState("IsRagdoll" , true)

	if self:GetState("IsBlocking") then
		self:SetState("IsBlocking" , false)
	end

	self:FreezeHumanoid()
	selfHumanoid:ChangeState(Enum.HumanoidStateType.Physics)

	-- Reset the target character's state to prevent freeze and allow them to be hit 
	task.delay(CONFIG.ragdollCooldown , function()
		self:ResetHumanoid() 
		self:SetState("IsRagdoll" , false)
		selfHumanoid:ChangeState(Enum.HumanoidStateType.GettingUp)

	end)

end

-- Check to whether stun or to ragdoll the target character depending on the enemy's combo threshold
function Combat:ApplyHitEffect(targetHumanoid)

	local comboCount = self:GetState("ComboCount")
	local targetCombat = self:GetCombat(targetHumanoid)

	local targetHumanoidRootPart = targetCombat.HumanoidRootPart
	local selfHumanoidRootPart = self.HumanoidRootPart

	if comboCount < 4 then
		targetCombat:Stun()
		targetHumanoidRootPart.AssemblyLinearVelocity = selfHumanoidRootPart.CFrame.LookVector * CONFIG.stunKnockBack + Vector3.new(0 , 0 , -5)
	else
		targetCombat:Ragdoll()
		targetHumanoidRootPart.AssemblyLinearVelocity =  selfHumanoidRootPart.CFrame.LookVector * CONFIG.ragdollKnockBack + Vector3.new(0 , 0 , -5)
	end


end

--[[ 
 Stun the target character to ensure consistent combat 
 Validate the target character's ragdoll state to prevent duplicate physics state
 Freeze the target character so that they cannot escape 
]]
function Combat:Stun()
	local selfHumanoidRootPart = self.HumanoidRootPart
	local selfHumanoid = self.Humanoid

	if self:GetState("IsRagdoll") or selfHumanoid:GetState() == Enum.HumanoidStateType.Physics then 
		return 
	end

	if self:GetState("IsBlocking") then
		self:SetState("IsBlocking" , false)
	end

	self:SetState("IsStunned" , true)
	self:FreezeHumanoid()

	self:UnStun()
end

--[[ 
 Check where the target's character is facing
 To prevent a full 360 degree block abuse 
 Prevent further calculation if the target character does not have the "Blocking" state enabled 
]]

function Combat:CheckBlockAngle(targethumanoid:Humanoid)

	local targetCombat = self:GetCombat(targethumanoid)
	local targetHumanoidRootPart = targetCombat.HumanoidRootPart

	local selfHumanoidRootPart = self.HumanoidRootPart

	if not targetCombat:GetState("IsBlocking") then 
		return true 
	end
	local direction = (selfHumanoidRootPart.Position - targetHumanoidRootPart.Position).Unit
	local dot = targetHumanoidRootPart.CFrame.LookVector:Dot(direction)

	return dot > 0.6
end


-- Check if the character  is in the ideal state for blocking to prevent state desyncs
function Combat:Block()
	if not self:CanAct() then
		return
	end
	self:SetState("IsBlocking" , true)
end


-- Check if the player is alive to unblock the attack
-- Check if the character is already in the blocking state to prevent useless replication
function Combat:UnBlock()
	if not self.Character then
		return
	end

	if self:GetState("IsBlocking") then
		self:SetState("IsBlocking",false)
	end
end


-- Enforces Server-Side cooldowns to prevent client side exploits
-- Replicate the changes to the client to prevent combat animation desyncs
function Combat:SetCooldown(name:string , cooldownConfig)
	if self.Cooldowns[name] then 
		return 
	end
	self.Cooldowns[name] = true
	self:Callback("OnChanged" , name , true)
	 
	 
	 local cooldown =  typeof(cooldownConfig) == "table" 
			     and cooldownConfig.Cooldown 
				 or cooldownConfig
	
	task.delay(cooldown , function()
		self.Cooldowns[name] = nil

		self:Callback("OnChanged" , name , nil)

		-- Event called for the punch function
		if  type(cooldownConfig) ~= "table" then
			return
		end
		cooldownConfig.Event(self)

	end)
end


--Check whether if the combat action is on cooldown or not  
function Combat:HasCooldown(name:string)
	return self.Cooldowns[name]
end


-- Reset the combo of the character to prevent ragdoll abuse of the target
function Combat:ResetCombo()
	if not self.Character then
		return
	end

	if self.resetThread then 
		task.cancel(self.resetThread)
		self.resetThread = nil
	end

	self.resetThread = task.delay(CONFIG.comboResetTimer , function()
		self:SetState("ComboCount", 1)
		print("Resetting Combo")
		self.resetThread = nil
	end)	
end


--[[ 
 Check if the character doesn't have any secondary state enabled to prevent state override
 Apply LinearVelocity instead of BodyVelocity because it integrates with Roblox's modern physics solver 
 To ensure consistent movement 
 Set the "Dashing" state to sync the animation with the client 
 ]]
function Combat:Dash()

	if not self:CanAct() then
		return
	end

	if self:HasCooldown("Dash") then 
		return 
	end

	self:FreezeHumanoid()
	self:SetState("IsDashing" , true)

	local selfHumanoidRootPart = self.HumanoidRootPart

	local direction = selfHumanoidRootPart.CFrame.LookVector 	 

	local attachment = selfHumanoidRootPart:FindFirstChild("DashAttachment") or Instance.new("Attachment" , selfHumanoidRootPart)
	attachment.Name = "DashAttachment"

	local linearvelocity = Instance.new("LinearVelocity" , selfHumanoidRootPart)
	linearvelocity.Attachment0 = attachment
	linearvelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	linearvelocity.ForceLimitsEnabled = false
	linearvelocity.VectorVelocity = direction  * CONFIG.dashForce + Vector3.new(0 , 2 , 0)


	task.delay(CONFIG.dashDelay, function()
		if linearvelocity then
			linearvelocity:Destroy()
		end


		self:ResetHumanoid()
		self:SetState("IsDashing" , false)

	end)

	self:SetCooldown("Dash" , CONFIG.dashCooldown)

end

-- Validate and set a cooldown for the client's request to prevent remote spams  
function Combat:CanRequest(action)
	local timeNow = os.clock()
	self.lastTime = self.lastTime or {}
	local lastTime = self.lastTime[action] 
	
	if lastTime and (timeNow - lastTime) < 0.15  then
		return false
	end
	
	self.lastTime[action] = timeNow
	return true
	
end



--[[ 
 Punch attack 
 Create a hitbox infront of the player and get every validated target inside it
 Apply damage to all the targets of the hitbox 
 Increment the combo count to prevent animation desyncs
 Reset the combo count if the player is idle for a while to prevent ragdoll abuse
 ]]
function Combat:Punch()

	if not self:CanAct() or self:HasCooldown("Punch") then
		return
	end

	local selfHumanoidRootPart = self.HumanoidRootPart 

	local hits = self:QueryHits( selfHumanoidRootPart.CFrame * CFrame.new(0 , 0 , -3 ) , Vector3.new(5 , 5 , 5) , {self.Character} )

	self:ApplyHumanoidProperties(10 , 0 , true)

	self:HandleHits(hits)
	self:IncrementCombo()

	self:SetCooldown("Punch" , CONFIG.punchCooldown)



	self:ResetCombo()
end

--[[ 
 Receive calls from the client  
 Check if the method is allowed by the server to prevent exploitation from the client
 Get the player's combat instance to callback the method the client requested 
 Check if the method isn't on cooldown to prevent spam
 er
]]

combatRemote.OnServerEvent:Connect(function(player , event)
	  
	  if not allowedEvents[event] then 
			return
	  end

	local playerCombat = playerCombats[player.UserId]     

	if not playerCombat 
		or playerCombat.Character ~= player.Character 
		or playerCombat:HasCooldown(event) 
		or not playerCombat:CanRequest(event)
	then 
		return 
	end

	local method = playerCombat[event]

	if type(method) ~= "function" then 
		return 
	end

	method(playerCombat)
end)

return Combat
return Combat

