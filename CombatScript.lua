--# Combat Framework 
--Discord : 590BIll
--Roblox : 590Bill

-- //////COMBAT FRAMEWORK (SERVER AUTHORITATIVE)////////
-- // Controls All Melee Combat Logic 
--//  State Driven Combat Including (Punch , Block , Stun , Ragdoll)
--//  Server Side Hit Detection Using Spatial Queries
--//   Server Authoritative Cooldowns To Prevent Exploits 
--//   
--//  All State Changes Are Replicated Using OnChanged Events
--//  
--// Flow : 
--// Client Input -> Remote -> Server Validation -> Method Call 
--// -> State Changes (Attributes) ->  OnChanged Events -> 
--// Replication To Client
--////////////////////////////////////////////////////////////
--///////////////////////////////////////////////////////////


--!optimize 2
--/ Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
--/Remote
local remotes = ReplicatedStorage:FindFirstChild("Remotes")
local combatRemote = remotes:FindFirstChild("CombatRemote")


-- Validation Layer 
local AllowedEvents = {
  Punch = true, Block = true , UnBlock = true , Dash = true
}

export type Combat = {
	 Character :Model ,
	 Cooldowns : {[string] : any } ,
 	
      	
	--////////////////////////
	 -- Central State System Using Attributes For Replication
	 -- Changes Automatically Replicate To Client Using OnChanged Listeners
	--////////////////////////
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
   --////////////////////
   -- Combat Actions
   --//////////////////
	
	Punch : (self:Combat) -> (),
	Block : (self:Combat) -> (),
	UnBlock : (self:Combat) -> (),
	Dash : (self:Combat) -> (),
	Stun : (self:Combat , target:Humanoid) -> (),
	UnStun:(self:Combat) -> () ,
		
} 

--/Combat State
local Combat:Combat = {}

--//// Store The Player's Combat State
local PlayerCombats = {}

--/// Store The Npc's Combat State
local NpcCombats = {}
Combat.__index = Combat


local Configs = {
	
	stunCooldown = 1.75,
	punchCooldown = 0.75 ,
	comboResetTimer = 5,
	ragdollCooldown = 2 ,
	dashDelay = 1,
	dashCooldown = 5
	
}

--[[ Create A Combat Instance For The Model/Player 

Each Character Receives Its Own Combat Instance to Isolate
State , Cooldowns And Combat Logic
]]

function Combat.New(Character:Model)
	if not Character then 
		return
	end
	local self = setmetatable({} , Combat)
	
	local plr = Players:GetPlayerFromCharacter(Character)
	local humanoid = Character:FindFirstChildOfClass("Humanoid")
	self.Character = Character
	
	self.Cooldowns = {}
	-- Create A Event Listener So Any Changes To The Combate Instance Can Be Replicated To The Client
	self.Events = {
		OnChanged = {},
	}
	
	self.DeathConnection = humanoid.Died:Connect(function()
		self:Destroy()
	end)
	
	-- Seperate Storage For Players Vs Npcs
	if not plr then
		NpcCombats[Character] = self
		return self
	end
	
	PlayerCombats[plr.UserId] = self
	
	return self
end


--// Destroy The Combat Instance To Prevent Memory Leak
function Combat:Destroy()
	if self.DeathConnection then 
		self.DeathConnection:Disconnect()
		
	end
	table.clear(self)
end


--[[
Retreive The Combat Instance From Any Descendant Of The Model 
 And Ensure That Every Valid Character Has A Combat Instance
]] 
function Combat:GetCombat(descendant:Instance)
	local targetmodel = descendant and (descendant:IsA("Model") and descendant  or descendant:FindFirstAncestorOfClass("Model"))
		if not targetmodel then return nil  end	 
			
	local Plr = Players:GetPlayerFromCharacter(targetmodel) 
		local targetcombat = Plr and PlayerCombats[Plr.UserId] or NpcCombats[targetmodel]
		if not targetcombat then
		    targetcombat = Combat.New(targetmodel)
		end
	   return targetcombat 
end
--[[
Return Core Physical Components Of A Character 
 HumanoidRootPart For Movement / Physics 
 Humanoid For State Control
]]
function Combat:GetMainComponents()
	local character:Model = self.Character
	if not character then 
		return nil , nil 
	end
	local hrp:BasePart = character and character.PrimaryPart or character:WaitForChild("HumanoidRootPart")
	local humanoid:Humanoid = character and  character:FindFirstChildOfClass("Humanoid")
	
	if not hrp or not humanoid then
		return
	end
	return hrp , humanoid
end

--[[
Set The Properties Of The Humanoid :

The Speed , The JumpPower , And The Rotation 

This Is To Ensure No Weird Client Input Descyns
]]
function Combat:SetHumanoid(speed:number , height:number , canrotate:boolean)
	local hrp,selfhumanoid:Humanoid = self:GetMainComponents()
	
	selfhumanoid.WalkSpeed = speed
	selfhumanoid.JumpPower = height
	selfhumanoid.AutoRotate = canrotate
	
end

--[[
 ///////////////////////////////////////////////////////////////////////////////////////////////
 Register Callback Triggers Whenever A Combat State 
 Used For 
 Ui Updates 
 Animation Syncing
 Vfx Triggers
]]

function Combat:OnChanged(callback)
	table.insert(self.Events.OnChanged , callback)
end

--/// Callback All The Functions Tied To A Specific Event
function Combat:Callback(Event:string , ...)
	local Events = self.Events[Event]
    if not Events then return end
	
	for _ , callback in ipairs(Events) do
		callback(...)
	end
end

--[[
Used Spatial Query OverlapParams 
  To Avoid UnReliable Touched Events
  To Prevent Physics-Based Exploit 
  To Ensure Consistent Hit Registration
--]]

function Combat:CreateHitbox(range , size , ignorelist)
    local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = ignorelist or {}
	
	local parts = workspace:GetPartBoundsInBox(range , size , overlapParams)
	local hithumanoids = {}
	
	for _ , basepart in ipairs(parts) do
		 local model = basepart:FindFirstAncestorOfClass("Model")
		if not model or not model.PrimaryPart  then
			continue
		 end
		
		local primaryPart = model.PrimaryPart 
		 
		 local targetCombat:Combat = self:GetCombat(primaryPart)
		 local hrp , humanoid:Humanoid = targetCombat:GetMainComponents()
		if  humanoid and humanoid.Health > 0  then 
			if not table.find(hithumanoids , humanoid)   then
				table.insert(hithumanoids , humanoid)
			end
		end		
	end
	return hithumanoids
end

--[[
//////////////////////////////////////////////////////////////////
The Instance's State Is Set Using Attributes To Allow Replication
Any State Changes Are Replicated To The Client 
To Allow Client Ui Changes
Sync The Animations 
////////////////////////////////////////////////////////////////
]]
function Combat:SetState(name:string , value:any)
	local Character:Model = self.Character
	Character:SetAttribute(name , value)
	self:Callback("OnChanged" , name , value)
	
end
--/// Get The State Of The Combat Instance Using Attributes
function Combat:GetState(name:string)
	local Character:Model = self.Character
	return Character:GetAttribute(name)
end

--[[ 
 //////////////////////////////////////////////////////////////////////////
 UnStun The Combat Object 
  Cancel The UnStun( Using task.cancel() )If The Method Was Called Again
  Set A New UnStun Timer Using task.delay() 
  This Is To Ensure Consistency And To Prevent Weird Desyncs
 ]]
function Combat:UnStun()	
	if self.revertStun  then
		task.cancel(self.revertStun)
		self.revertStun = nil
	end
	if self:GetState("IsRagdoll") then return end
	
	self.revertStun = task.delay(Configs.stunCooldown , function()
		self:SetState("IsStunned" , false)
		self:ResetHumanoid()
	end)
	
end

--[[ 
 ////////////////////////////////////////////////
 Disable All Movements For The Humanoid 
 This is Used For The Stun , Ragdoll And The Dash
 To Prevent Weird Client Input Desyncs 
 //////////////////////////////////////////////
]]

function Combat:FreezeHumanoid()
	self:SetHumanoid(0 , 0 , false)
end
--[[
Enable All Movement Back For The Instance's Model 
To Prevent Permanent Freeze Of The Model 
]]
function Combat:ResetHumanoid()
	local hrp , humanoid = self:GetMainComponents()
	self:SetHumanoid(16 , 50 , true)
	
end

--// Ragdoll The Combat Object
--[[
   ///////////////////////////////////////////////////
   Full Physical Simulation Of The Instance
   Prevents The Player's From Fighting During Knockdown
   ////////////////////////////////////////////////////
--]]

function Combat:Ragdoll()
	 local hrp  , humanoid:Humanoid = self:GetMainComponents()
	 if self:GetState("IsRagdoll") then return end 
	 if humanoid.Health <= 0  then return end
	self:SetState("IsRagdoll" , true)
	
	--//Change Humanoid State
	 humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	 
	-- Humanoid Properties
	self:FreezeHumanoid()
	 
	--//Set Back To Default
	task.delay(Configs.ragdollCooldown , function()
		self:ResetHumanoid() 
		self:SetState("IsRagdoll" , false)
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		
	end)

end

--[[
/////////////////////////////////////////////////////////////////////////////////////////
Set The Stun Of The Istance
To Prevent The Enemy From Doing Any Kind Of Action While The Player Is Hitting
Apply A Slight KnockBack To Allow The Enemy To Escape If It Gets Out Of Range Of The Player
///////////////////////////////////////////////////////////////////////////////////////
]]
function Combat:Stun(targethumanoid:Humanoid)

	local targetcombat = self:GetCombat(targethumanoid)
	if targetcombat:GetState("IsRagdoll") then return end
	
	local targethrp  , _t = targetcombat:GetMainComponents()
	 local combo = self:GetState("HasCombo")
	 local selfhrp , _s = self:GetMainComponents()
      
	 if combo < 4 then
		targethrp.AssemblyLinearVelocity = selfhrp.CFrame.LookVector * 25 + Vector3.new(0 , 0 , -5)
		
		targetcombat:FreezeHumanoid()
		targetcombat:SetState("IsStunned" , true)
		
		targetcombat:UnStun()
	 else
		targetcombat:Ragdoll()
	    targethrp.AssemblyLinearVelocity =  selfhrp.CFrame.LookVector * 50 + Vector3.new(0 , 0 , -5)
	 end
	
	
end

--[[
///////////////////////////////////////////////////////////
Find The Direction The Target Is Facing 
To Prevent A Weird 360' Degree Block Abuse 
And To Ensure A Skill-Based And Fair Combat Between The Players
//////////////////////////////////////////////////////////
]]
function Combat:CheckBlockAngle(targethumanoid:Humanoid)
	local targetCombat:Combat = self:GetCombat(targethumanoid)
    local targethrp:BasePart , _t  = targetCombat:GetMainComponents() 
	
	local selfhrp:BasePart , _s =  self:GetMainComponents()
	
	if not targetCombat:GetState("IsBlocking") then return true end
	local direction = (targethrp.Position-selfhrp.Position).Unit
	local dot = targethrp.CFrame.LookVector:Dot(direction)
	print(dot)
	
	if dot > 0.6 then
		return true
	else 
		return false
	end
end




--[[
Check If The Player Is Idle To Allow Block
To Prevent Block Abuse And Weird Behaviour During Combat
]]
function Combat:Block()
	if self:GetState("IsStunned") or self:GetState("IsRagdoll") or self:GetState("IsDashing") then return end
	self:SetState("IsBlocking" , true)
end
--// Check If The Combat Object is Blocking And Then Set It To False
function Combat:UnBlock()
	if self:GetState("IsBlocking") then
	  self:SetState("IsBlocking",false)
	end
	
end
--[[
/////////////////////////////////////////////////////////
Enforces Server Side Cooldowns Per Method To Prevent Spam
 Ensure Proper Combat Pacing Across All Clients
 ////////////////////////////////////////////////////
]]
function Combat:SetCooldown(name:string , duration:number)
	if self.Cooldowns[name] then return end
	self.Cooldowns[name] = true
	self:Callback("OnChanged" , name , true)
	
	task.delay(duration , function()
		self.Cooldowns[name] = false
		self:Callback("OnChanged" , name , false)
	end)
end

--[[
Check If Combat Action Is On Cooldown
To Prevent Infinite Spam 
]]
function Combat:HasCooldown(name:string)
	return self.Cooldowns[name]
end

--[[
//////////////////////////////////////////////////////////
Check If The Player Is In The Suitable State For A Dash 
And Disable All Movements To Prevent Weird Movements During A Dash
Apply Linear Velocity For Consistent Movement 
Set A Cooldown For The Dash To Prevent Infinite Spam
////////////////////////////////////////////////////////
]]
function Combat:Dash()
	
	local selfchar:Model = self.Character
	if self:GetState("IsStunned") or self:GetState("IsRagdoll") or self:GetState("IsBlocking") then return end
	if self:HasCooldown("Dash") then return end
	
	self:SetState("IsDashing" , true)
		
	 local hrp:BasePart , _s = self:GetMainComponents()
	
	local direction = hrp.CFrame.LookVector 
	 self:FreezeHumanoid()
	
	 local attachment = hrp:FindFirstChild("DashAttachment") or Instance.new("Attachment" , hrp)
     attachment.Name = "DashAttachment"
	 local linearvelocity = Instance.new("LinearVelocity" , hrp)
	 linearvelocity.Attachment0 = attachment
	 linearvelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	 linearvelocity.ForceLimitsEnabled = false
     linearvelocity.VectorVelocity = direction  * 60 + Vector3.new(0 , 2 , 0)
	

	 task.delay(Configs.dashDelay, function()
			if linearvelocity then
				linearvelocity:Destroy()
			end
		
		self:ResetHumanoid()
		self:SetState("IsDashing" , false)
		
	 end)

	self:SetCooldown("Dash" , Configs.dashCooldown)

end

--[[
Main Compat Logic (Punch Loop)
////////////////////////
Handles hitbox detection:
|Combo Management System
|Block Validation
|Damage Logic
|Combo Resetting Logic
|Stun Logic
|Cooldown Validation Logic
////////////////////
]]
function Combat:Punch()

   if self:GetState("IsBlocking") 
		or self:GetState("IsDashing") 
		or self:GetState("IsRagdoll")  
        then return end
	
	if self:HasCooldown("Punch") then return end
	
	local hrp , _s = self:GetMainComponents()
	
	local hits = self:CreateHitbox( hrp.CFrame * CFrame.new(0 , 0 , -3 ) , Vector3.new(5 , 5 , 5) , {self.Character} )
	local combo = self:GetState("HasCombo")

	-- Properties
	self:SetHumanoid(10 , 0 , true)
	-- 
	for _ , hitshumanoids:Humanoid in ipairs(hits) do
		if hitshumanoids then
			local targetCombat = self:GetCombat(hitshumanoids)
			
			if  targetCombat:GetState("IsRagdoll") then continue end
			if not  self:CheckBlockAngle(hitshumanoids) then
				continue 
			end
			
			hitshumanoids:TakeDamage(10)
			self:Stun(hitshumanoids)
	

		end
	end	

    combo+=1
	
	if combo > 4 then
		combo = 1
	end
    
  
	self:SetState("HasCombo",  combo )
	
  self:SetCooldown("Punch" , Configs.punchCooldown)
 task.delay(Configs.punchCooldown , function() 
   self:ResetHumanoid()
 end)

  if self.ResetCombo then 
   task.cancel(self.ResetCombo)
   self.ResetCombo = nil
 end

self.ResetCombo = task.delay(Configs.comboResetTimer , function()
	self:SetState("HasCombo", 1)
	print("Resetting Combo")
end)	

end
--[[
Player Intialization On Spwan
]]
Players.PlayerAdded:Connect(function(plr)
	plr.CharacterAdded:Connect(function(character)
		if PlayerCombats[plr.UserId] then
			PlayerCombats[plr.UserId] = nil
		end
	local plrCombat:Combat = Combat.New(character)
		
		-- Default States That The Player Spawns With
		plrCombat:SetState("IsBlocking" , false)
		plrCombat:SetState("IsStunned" , false)
		plrCombat:SetState("HasCombo" , 1)
		plrCombat:SetState("IsRagdoll" , false )
		plrCombat:SetState("IsDashing" , false)
		
		-- Replicate States To Client For Ui , Vfx , Animations
		plrCombat:OnChanged(function(state , value)
			combatRemote:FireClient(plr , state , value)
		end)
		
	end)
end)

--Remove The Player's Combat Instance In Order To Prevent Memory Leakes
Players.PlayerRemoving:Connect(function(plr)
	PlayerCombats[plr.UserId] = nil
end)

--[[
Handle Client - Server Logic
Check If The Client Is ALlowed To Execute The Combat Action Using AllowedEvents
Get The Combat Instance Of The Player To Isolate The Action Only To Client 
Check If It is A Function To Prevent Errors  
Execute The Action

]]


combatRemote.OnServerEvent:Connect(function(plr , event:string)
	if not AllowedEvents[event] then return end  
	local plrcombat = PlayerCombats[plr.UserId]     
	
	if not plrcombat then return end
	
	if  plrcombat.Cooldowns[event]  then return end
	local method = plrcombat[event]
	
	if type(method) ~= "function" then return end
	
	method(plrcombat)
end)


