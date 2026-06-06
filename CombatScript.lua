--# Combat Framework 
--Discord : 590BIll
--Roblox : 590Bill

-- COMBAT FRAMEWORK (SERVER AUTHORITATIVE)
-- Controls All Melee Combat Logic (Punch , Block , Dash)
-- Server authoritative cooldowns to prevent exploits
-- Flow : Client Input -> Remote -> Server Validation -> State Changes -> Replication

--!optimize 2
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local remotes = ReplicatedStorage:FindFirstChild("Remotes")
local combatRemote = remotes:FindFirstChild("CombatRemote")

-- Validation Layer 
local allowedEvents = {
  Punch = true , Block = true , UnBlock = true , Dash = true
}

export type Combat = {
	 Character :Model ,
	 Cooldowns : {[string] : boolean } ,
	 
	-- State System (Changes Automatically Replicate To Client)
	 
	 GetCombat : (self:Combat , descendant:Instance) -> Combat , 
	 SetHumanoid : (self:Combat , speed:number , height:number , canrotate:boolean) -> (),
	 SetState : (self:Combat , name:string , value:any) -> () ,
	 GetState : (self:Combat , name:string) -> boolean | number ,
    	
	
	 SetCooldown : (self:Combat, name:string , duration:number) -> () ,
	 HasCooldown : (self:Combat , OnCooldown:string) -> boolean ,
	 FreezeHumanoid : (self:Combat) -> (),
	 ResetHumanoid : (self:Combat) -> (),
   
     GetMainComponents :(self:Combat)  -> (BasePart , Humanoid) ,
     Destroy : (self:Combat) -> (),
   
   -- Combat Actions
	
	Punch : (self:Combat) -> (),
	Block : (self:Combat) -> (),
	UnBlock : (self:Combat) -> (),
	Dash : (self:Combat) -> (),
	Stun : (self:Combat , target:Humanoid) -> (),
	UnStun:(self:Combat) -> () ,
		
} 

--/Combat State
local Combat:Combat = {}
Combat.__index = Combat

--/ Active Combat States
local playerCombats = {}
local npcCombats = {}


-- Config Values (Tuning Constants)
local CONFIG = {
	stunCooldown = 1.75 ,
	stunKnockBack = 25 ,

	punchCooldown = 0.75 ,
	comboResetTimer = 5 ,
	damage = 10 ,
	
	ragdollCooldown = 2 ,
	ragdollKnockBack = 50 ,

	dashDelay = 1 ,
	dashCooldown = 5 ,
	dashForce = 60 ,

	maxDistance = 12
}

--Each Character Receives Its Own Combat Instance to Isolate
--States , Cooldowns And Combat Logic

function Combat.new(character:Model)
	if not character then 
		return
	end
	local self = setmetatable({} , Combat)
	
	local player = Players:GetPlayerFromCharacter(character)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	self.Character = character
	self.Cooldowns = {}
	
	-- Create A Event Listener So Any Changes To The Combat Instance Can Be Replicated To The Client
	self.Events = {
		OnChanged = {},
	}
	
	self.DeathConnection = humanoid.Died:Connect(function()
		self:Destroy()
		if npcCombats[character] then
			npcCombats[character] = nil
			
		end
		if playerCombats[player.UserId] then
			playerCombats[player.UserId] = nil
		end	
	end)
	
	-- Seperate Storage For Players Vs Npcs
	if not player then
		npcCombats[character] = self
		return self
	end
	
	playerCombats[player.UserId] = self
	
	return self
end


-- Destroy The Combat Instance To Prevent Memory Leak

function Combat:Destroy()
	if self.DeathConnection then 
		self.DeathConnection:Disconnect()
	end
	
	for _, v in pairs(self)  do
		if typeof(v) == "RBXScriptConnection" then
			v:Disconnect()
		end
	end
	table.clear(self)
end


--Retreive The Combat Instance From Any Descendant Of The Model 
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
		if not targetCombat then
		    targetCombat = Combat.new(targetModel)
		end
	  
	  return targetCombat 
end

--Return Core Physical Components Of A Character 
-- HumanoidRootPart For Movement / Physics 
-- Humanoid For State Control

function Combat:GetMainComponents()
	local character:Model = self.Character
	if not character then 
		return nil , nil 
	end
	local humanoidRootPart:BasePart = character and character.PrimaryPart or character:WaitForChild("HumanoidRootPart")
	local humanoid:Humanoid = character and  character:FindFirstChildOfClass("Humanoid")
	
	
	if not humanoidRootPart or not humanoid then
		return
	end

  return humanoidRootPart , humanoid
end

-- Set The Necessary Humanoid Properties Of The Character
function Combat:SetHumanoid(speed:number , height:number , canrotate:boolean)
	local humanoidRootPart , selfhumanoid:Humanoid = self:GetMainComponents()
	
	if not selfhumanoid then 
		return
	end
	
	selfhumanoid.WalkSpeed = speed
	selfhumanoid.JumpPower = height
	selfhumanoid.AutoRotate = canrotate
	
end

 --Register Callback Triggers Whenever A Combat Instance Changes
 --Used For 
 --Ui Updates 
 --Animation Syncing
 --Vfx Triggers

function Combat:OnChanged(callback)
	table.insert(self.Events.OnChanged , callback)
end

-- Callback All The Functions Tied To A Specific Event
function Combat:Callback(eventCall:string , ...)
	local events = self.Events[eventCall]
	if not events then 
		return 
	end
	
	for _ , callback in ipairs(events) do
		callback(...)
	end
end

--Used Spatial Query (GetPartsBoundsInBox)
--  To Avoid UnReliable Touched Events
--  To Prevent Physics-Based Exploit 
--  To Ensure Consistent Hit Registration

function Combat:CreateHitbox(range , size , ignorelist)
    local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = ignorelist or {}
	
	local parts = workspace:GetPartBoundsInBox(range , size , overlapParams)
	local hitHumanoids = {}
	
	for _ , basepart in ipairs(parts) do
		 local model = basepart:FindFirstAncestorOfClass("Model")
		if not model or not model.PrimaryPart  then
			continue
		 end
		
		local primaryPart = model.PrimaryPart 
		 
		 local targetCombat: Combat = self:GetCombat(primaryPart)
		 local targetHumanoidRootPart , targetHumanoid: Humanoid = targetCombat:GetMainComponents()
		if  targetHumanoid and targetHumanoid.Health > 0  then 
			
			if not table.find(hitHumanoids , targetHumanoid)   then
				table.insert(hitHumanoids , targetHumanoid)
			end
		
		end		
	end
	return hitHumanoids
end

--The Instance's State Is Set Using Attributes To Allow Replication
--Any State Changes Are Replicated To The Client 
--To Allow Client Ui Changes
--Sync The Animations 

function Combat:SetState(name:string , value:any)
	local character: Model = self.Character
	character:SetAttribute(name , value)
	self:Callback("OnChanged" , name , value)
	
end

-- Get The State Of The Combat Instance Using Attributes
function Combat:GetState(name:string)
	local character: Model = self.Character
	return character:GetAttribute(name)
end

--UnStun The Combat Object 
--Cancel The UnStun( Using task.cancel() )If The Method Was Called Again
--Set A New UnStun Timer Using task.delay() 
--This Is To Ensure Consistency And To Prevent Weird Desyncs

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

 --This is Used For The Stun , Ragdoll And The Dash
 --To Prevent Weird Client Input Desyncs 

function Combat:FreezeHumanoid()
	self:SetHumanoid(0 , 0 , false)
end

--Enable All Movement To Prevent Permanent Freeze Of The Model 
function Combat:ResetHumanoid()
	local hrp , humanoid = self:GetMainComponents()
	self:SetHumanoid(16 , 50 , true)
end

 --Ragdoll The Combat Object
 --Full Physical Simulation Of The Instance
 --Prevents The Player's From Fighting During Knockdown

function Combat:Ragdoll()
	 local humanoidRootPart  , humanoid  = self:GetMainComponents()
	 if self:GetState("IsRagdoll") then 
		return 
	 end 
	 
	 if humanoid.Health <= 0 then 
		return 
	 end
	
	self:SetState("IsRagdoll" , true)

	 humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	 
	self:FreezeHumanoid()
	 
	--/Set Back To Default To Prevent The Player From Permanently Being Stucked In The State
	task.delay(CONFIG.ragdollCooldown , function()
		self:ResetHumanoid() 
		self:SetState("IsRagdoll" , false)
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		
	end)
end

--Set The Stun Of The Istance
--Ragdoll Validation To Prevent Duplicate Physics State Application
--To Prevent The Enemy From Doing Any Kind Of Action While The Player Is Hitting
--Apply A Slight KnockBack To Allow The Enemy To Escape If It Gets Out Of Range Of The Player

function Combat:Stun(targetHumanoid:Humanoid)
	local targetCombat = self:GetCombat(targetHumanoid)
	
	if targetCombat:GetState("IsRagdoll") 
	 or targetHumanoid:GetState() == Enum.HumanoidStateType.Physics 
	then 
		return 
	end
	 
	local targetHumanoidRootPart  , _ =  targetCombat:GetMainComponents()
	 local combo = self:GetState("ComboCount")
	 local selfHumanoidRootPart , selfHumanoid = self:GetMainComponents()
      
	 if combo < 4 then
		targetHumanoidRootPart.AssemblyLinearVelocity = selfHumanoidRootPart.CFrame.LookVector * CONFIG.stunKnockBack + Vector3.new(0 , 0 , -5)
		
		targetCombat:FreezeHumanoid()
		targetCombat:SetState("IsStunned" , true)
		
		targetCombat:UnStun()
	 else
		targetCombat:Ragdoll()
	    targetHumanoidRootPart.AssemblyLinearVelocity =  selfHumanoidRootPart.CFrame.LookVector * CONFIG.ragdollKnockBack + Vector3.new(0 , 0 , -5)
	 end
end

--Find The Direction The Target Is Facing
--To Prevent A  360' Degree Block Abuse 

function Combat:CheckBlockAngle(targethumanoid:Humanoid)
	local targetCombat: Combat = self:GetCombat(targethumanoid)
    local targetHumanoidRootPart: BasePart , _ = targetCombat:GetMainComponents() 
	
	local selfHumanoidRootPart: BasePart , _ =  self:GetMainComponents()
	
	if not targetCombat:GetState("IsBlocking") then 
		return true 
	end
	local direction = (selfHumanoidRootPart.Position - targetHumanoidRootPart.Position).Unit
	local dot = targetHumanoidRootPart.CFrame.LookVector:Dot(direction)

	-- Return True If The Player Is Infront (Dot = 1 or Greater Than 0.6)
	if dot > 0.6 then
		return true
	else 
		return false
	end
end


--Check If The Player Is In The  Ideal State  To Allow Block
--To Prevent Block Abuse And Exploit Behaviour During Combat

function Combat:Block()
	if self:GetState("IsStunned") 
		or self:GetState("IsRagdoll") 
		or self:GetState("IsDashing") 
	then 
		return 
	end
	self:SetState("IsBlocking" , true)
end

-- Check If The Combat Object is Blocking And Then Set It To False
function Combat:UnBlock()
	if self:GetState("IsBlocking") then
	  self:SetState("IsBlocking",false)
	end
	
end

--Enforces Server Side Cooldowns Per Method To Prevent Spam
--Ensure Proper Combat Pacing Across All Clients

function Combat:SetCooldown(name:string , duration:number)
	if self.Cooldowns[name] then 
		return 
	end
	self.Cooldowns[name] = true
	self:Callback("OnChanged" , name , true)
	
	task.delay(duration , function()
		self.Cooldowns[name] = false
		self:Callback("OnChanged" , name , false)
	end)
end


--Check If Combat Action Is On Cooldown
function Combat:HasCooldown(name:string)
	return self.Cooldowns[name]
end

-- Reset The Combo Of  A Combat Instance  To Prevent Ragdoll Abuse
function Combat:ResetCombo()
	if self.ResetThread then 
		task.cancel(self.ResetThread)
		self.ResetThread = nil
	end

	self.ResetThread = task.delay(CONFIG.comboResetTimer , function()
		self:SetState("ComboCount", 1)
		print("Resetting Combo")
	end)	
end


--Check If The Player Is In The Suitable State For A Dash 
--And Disable All Movements To Prevent Weird Movements During A Dash
--Apply Linear Velocity For Consistent Movement 
--Set A Cooldown For The Dash

function Combat:Dash()
	if self:GetState("IsStunned") 
		or self:GetState("IsRagdoll") 
		or self:GetState("IsBlocking") 
	then 
		return 
	end
	
	if self:HasCooldown("Dash") then 
		return 
	end
	
	self:SetState("IsDashing" , true)
		
	 local humanoidRootPart:BasePart , humanoid = self:GetMainComponents()
	
	local direction = humanoidRootPart.CFrame.LookVector 
	 self:FreezeHumanoid()
	
	 local attachment = humanoidRootPart:FindFirstChild("DashAttachment") or Instance.new("Attachment" , humanoidRootPart)
     attachment.Name = "DashAttachment"
	 
	 local linearvelocity = Instance.new("LinearVelocity" , humanoidRootPart)
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

-- Main Punch Logic
-- Handles Hit Detection , Player Damage Logic , Combo Logic , Cooldown Logic 

function Combat:Punch()
   if self:GetState("IsBlocking") 
		or self:GetState("IsDashing") 
		or self:GetState("IsRagdoll") 
	then 
		return 
   end
	
	if self:HasCooldown("Punch") then 
		return 
	end
	
	local selfHumanoidRootPart , selfHumanoid   = self:GetMainComponents()
    local hitOffset = selfHumanoidRootPart.CFrame * CFrame.new(0 , 0 , -3 )
	
	local hits = self:CreateHitbox( hitOffset , Vector3.new(5 , 5 , 5) , {self.Character} )
	local combo = self:GetState("ComboCount") or 1
	
	self:SetHumanoid(10 , 0 , true)

	for _, hitsHumanoid: Humanoid in ipairs(hits) do
			
			local targetCombat = self:GetCombat(hitsHumanoid)
			local targetPrimaryPart = targetCombat.Character.PrimaryPart
			
			if not targetPrimaryPart then
				continue
			end
			
			-- Distance Security Check To Prevent Exploits
			local distance = (selfHumanoidRootPart.Position - targetPrimaryPart.Position).Magnitude
			
			if distance > CONFIG.maxDistance  
			 or targetCombat:GetState("IsRagdoll")   -- Ignore If The Target Is In Ragdoll State
			 or not self:CheckBlockAngle(hitsHumanoid) -- Ignore If The Target Infront is Blocking While Facing The Player
			then
				continue
			end
			
			hitsHumanoid:TakeDamage(CONFIG.damage)
			self:Stun(hitsHumanoid)
	end	

    combo = combo + 1
	
	if combo > 4 then
		combo = 1
	end
  
	self:SetState("ComboCount",  combo )
	self:SetCooldown("Punch" , CONFIG.punchCooldown)
	
	-- Reset The Humanoid's Properties After The Punch 
    task.delay(CONFIG.punchCooldown , function() 
      self:ResetHumanoid()
    end)
 
 self:ResetCombo()
end


--Player Intialization On Spwan
Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		if playerCombats[player.UserId] then
			playerCombats[player.UserId] = nil
		end
	local playerCombat: Combat = Combat.new(character)
		
		-- Default States That The Player Spawns With
		playerCombat:SetState("IsBlocking" , false)
		playerCombat:SetState("IsStunned" , false)
		playerCombat:SetState("ComboCount" , 1)
	    playerCombat:SetState("IsRagdoll" , false )
		playerCombat:SetState("IsDashing" , false)
		
		-- Replicate States To Client For Ui , Vfx , Animations
		playerCombat:OnChanged(function(state , value)
			combatRemote:FireClient(player , state , value)
		end)
		
	end)
end)

--Remove The Player's Combat Instance In Order To Prevent Memory Leakes
Players.PlayerRemoving:Connect(function(player)
	playerCombats[player.UserId] = nil
end)


--Handle Client - Server Logic
--Check If The Client Is ALlowed To Execute The Combat Action Using allowedEvents
--Every Client Has A Isolated Combat Instance To Prevent Duplicated Logic
--Check If The Method Is A Function
--Execute The Action

combatRemote.OnServerEvent:Connect(function(plr , event:string)
	if not allowedEvents[event] then 
		return 
	end  
	local playerCombat = playerCombats[plr.UserId]     
	
	if not playerCombat or playerCombat.Cooldowns[event] then 
		return 
	end
	
	local method = playerCombat[event]
	if type(method) ~= "function" then 
		return 
	end
	
	method(playerCombat)
end)

