# Combat-Framework-
Scripter : 590BILL
Discord : 590bill
Roblox : 590Bill

-- //////COMBAT FRAMEWORK (SERVER AUTHORITATIVE)////////
-- // Controls All Melee Combat Logic 
--//  State Driven Combat Including (Punch , Block , Stun , Ragdoll)
--//  Server Side Hit Detection Using Spatial Queries
--//   Server Authorative Cooldowns To Prevent Exploits 
--//   
--//  All State Changes Are Replicated Using OnChanged Events
--//  
--// Flow : 
--// Client Input -> Remote -> Server Validation -> Method Call 
--// -> State Changes (Attributes) ->  OnChanged Events -> 
--// Replication To Client
--////////////////////////////////////////////////////////////
--///////////////////////////////////////////////////////////



--/ Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
	HasCooldown : (self:Combat , OnCooldown:string) -> ({[string]:any}) ,
	FreezeHumanoid : (self:Combat) -> (),
	ResetHumanoid : (self:Combat) -> (),
   
   GetMainComponents :(self:Combat)  -> (BasePart , Humanoid) ,
   
   --////////////////////
   -- Methods
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


-- ///  The Player's Combat State
--///  The Cooldowns Are Server Authoritive To Prevent Exploitation
--///  Use Observers To Automatically Replicate All State Changes To The Client
--///  Check If The Model Belongs To A Player If Not Then Set It For  The NpcCombat FrameWork

function Combat.New(Character:Model)
	local self = setmetatable({} , Combat)
	
	local plr = Players:GetPlayerFromCharacter(Character)
	self.Character = Character
	self.Cooldowns = {}
	self.Events = {
		OnChanged = {},
	}
	if not plr then
		NpcCombats[Character] = self
		return self
	end
	PlayerCombats[plr.UserId] = self
	
	return self
end

-- /// Get The Combat Framework Of The Object
function Combat:GetCombat(descendant:Instance)
	local targetmodel = descendant:FindFirstAncestorOfClass("Model")
	local Plr = Players:GetPlayerFromCharacter(targetmodel) 
		local targetcombat = Plr and PlayerCombats[Plr.UserId] or NpcCombats[targetmodel]
		if not targetcombat then
		    targetcombat = Combat.New(targetmodel)
		end
	   return targetcombat 
end

-- /// Get The Necessary Components Of A Object
function Combat:GetMainComponents()
	local character:Model = self.Character
	local hrp:BasePart = character and character.PrimaryPart or character:WaitForChild("HumanoidRootPart")
	local humanoid:Humanoid = character and  character:FindFirstChildOfClass("Humanoid")
	return hrp , humanoid
end

---/// Set The Common Properties OF The Humanoid
function Combat:SetHumanoid(speed:number , height:number , canrotate:boolean)
	local hrp,selfhumanoid:Humanoid = self:GetMainComponents()
	
	selfhumanoid.WalkSpeed = speed
	selfhumanoid.JumpHeight = height
	selfhumanoid.AutoRotate = canrotate
	
end

--/// Insert All The Functions That Will Be Callbacked For A Specific Event
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
 Spatial Query Hitbox Using GetPartsBoundsInBox
 Avoids Unreliable Touched Events 
 To Ensure Fast Melee Combat And Consistency 
--]]

function Combat:CreateHitbox(range , size , ignorelist)
    local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = ignorelist or {}
	
	local parts = workspace:GetPartBoundsInBox(range , size , overlapParams)
	local hithumanoids = {}
	
	for _ , basepart in ipairs(parts) do
		 local model = basepart:FindFirstAncestorOfClass("Model")
		 local primaryPart = model.PrimaryPart 
		 if not model or not primaryPart  then
			continue
		 end
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

--/// Set The State Of The Combat Using Attributes
function Combat:SetState(name:string , value:any)
	local Character:Model = self.Character
	Character:SetAttribute(name , value)
	self:Callback("OnChanged" , name , value)
	
end
--/// Get The State Of The Combat Using Attributes
function Combat:GetState(name:string)
	local Character:Model = self.Character
	return Character:GetAttribute(name)
end

--[[ 
   /UnStun The Combat Object 
  //Cancel The UnStun( Using task.cancel() )If The Method Was Called Again
 ///Set A New UnStun Timer Using task.delay() 
 ]]
function Combat:UnStun()	
	if self.revertStun  then
		task.cancel(self.revertStun)
		self.revertStun = nil
	end
	self.revertStun = task.delay(1.75 , function()
		self:SetState("IsStunned" , false)
		self:ResetHumanoid()
	end)
	
end

--[[ Lock The Combat Object In Place 
 By Disabling its Walkspeed, JumpHeight and Rotation]]

function Combat:FreezeHumanoid()
	self:SetHumanoid(0 , 0 , false)
end
--/// Reset The Combat Object And Its Properties Which Were Changed
function Combat:ResetHumanoid()
	self:SetHumanoid(16 , 7.2 , true)
end

--// Ragdoll The Combat Object
--[[
   Change The Humanoid State Of The Combat Object To HumanoidStateType.Physics To Make It Fall
   Lock The Combat Object In Place
   Add A Delay Of 5 Seconds Using task.delay() 
   After Which The Combat Object 
   Gains Back Movement 
   The Ragdoll property is set to False
   The Humanoid's State Is Changed Back To HumanoidStateType.GettingUp
--]]

function Combat:Ragdoll()
	 local hrp  , humanoid:Humanoid = self:GetMainComponents()
	 if self:GetState("IsRagdoll") then return end 
	 if humanoid.Health < 0  then return end
	self:SetState("IsRagdoll" , true)
	
	--//Change Humanoid State
	 humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	 
	-- Humanoid Properties
	self:FreezeHumanoid()
	 
	--//Set Back To Default
	task.delay(3.5 , function()
		self:ResetHumanoid() 
		self:SetState("IsRagdoll" , false)
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end)

end

--[[
Check To Whether Stun or Ragdoll The Combat The Combat Object Depending On Combo Threshold
Apply Knockback According To The Threshold :
And Set The Direction Of The Knockback Using The Combat Object's LookVector
Set The Stun State For The Combat Object To True
]]
function Combat:Stun(targethumanoid:Humanoid)

	local targetcombat = self:GetCombat(targethumanoid)
	
	local targethrp  , _t = targetcombat:GetMainComponents()
	 local combo = self:GetState("HasCombo")
	 local selfhrp , _s = self:GetMainComponents()
          
	 if combo < 4 then
		targethrp.AssemblyLinearVelocity = selfhrp.CFrame.LookVector * 25 + Vector3.new(0 , 0 , -5)
		
		targetcombat:FreezeHumanoid()
		targetcombat:UnStun()
	 else
		targetcombat:Ragdoll()
	    targethrp.AssemblyLinearVelocity =  selfhrp.CFrame.LookVector * 50 + Vector3.new(0 , 0 , -5)
	 end
	
	targetcombat:SetState("IsStunned" , true)
end

--[[
Find The Direction The Target Is Facing 
By Getting The Direction B/w The Target And The Combat Object
Getting The Dot Product Of The Direction 
and Returning A boolean value according to it
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
Check If The Combat Object Is Not In Any State
Then Allow The Combat Object To Block
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
 Enforces Server Side Cooldowns Per Method To Prevent Spam
 Ensure Proper Combat Pacing Across All Clients
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

--//Check If A Method Is On Cooldown ///
function Combat:HasCooldown(name:string)
	return self.Cooldowns[name]
end

--[[
Check If The Combat Object Is In The State For A Dash
Check If The Method Is On Cooldown
Disable ALl Movements For The Combat Object's Character
Use Linear Velocity To Give A Forward Push To The Combat Object's Character Using The LookVector
Clean The Instance And Set The State For Dashing To False
Initialize A Cooldown For The Method
]]
function Combat:Dash()
	
	local selfchar:Model = self.Character
	if self:GetState("IsStunned") or self:GetState("IsRagdoll") or self:GetState("IsBlocking") then return end
	if self:HasCooldown("Dash") then return end
	
	self:SetState("IsDashing" , true)
		
	 local hrp:BasePart , _s = self:GetMainComponents()
	
	local direction = hrp.CFrame.LookVector 
	 self:FreezeHumanoid()
	
	 local attachment = hrp:WaitForChild("DashAttachment" , 0.1) or Instance.new("Attachment" , hrp)
     attachment.Name = "DashAttachment"
	 local linearvelocity = Instance.new("LinearVelocity" , hrp)
	 linearvelocity.Attachment0 = attachment
	 linearvelocity.MaxForce = 50000
	 linearvelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	 linearvelocity.ForceLimitsEnabled = false
     linearvelocity.VectorVelocity = direction  * 60 + Vector3.new(0 , 2 , 0)
	

	 task.delay(1, function()
		linearvelocity:Destroy()
		self:ResetHumanoid()
		self:SetState("IsDashing" , false)
		
	 end)

	self:SetCooldown("Dash" , 5)

end

--[[
Handles Punch Attack Logic And hit detection logic
]]
function Combat:Punch()

   if self:GetState("IsBlocking") or self:GetState("IsDashing") or self:GetState("IsRagdoll")  then return end
   if self:HasCooldown("Punch") then return end
	
	local hrp , _s = self:GetMainComponents()
	
	local hits = self:CreateHitbox( hrp.CFrame * CFrame.new(0 , 0 , -3 ) , Vector3.new(5 , 5 , 5) , {self.Character} )
	local combo = self:GetState("HasCombo")

	-- Properties
	self:SetHumanoid(10 , 0 , true)
	-- 
	for _ , hitshumanoids in ipairs(hits) do
		if hitshumanoids then
			if not  self:CheckBlockAngle(hitshumanoids) then
				continue 
			end
			hitshumanoids:TakeDamage(10)
			self:Stun(hitshumanoids)
			
			print("Firing")
		end
	end	

	if self:GetState("HasCombo") >= 4 then
		combo = 0
	end
    
  
	self:SetState("HasCombo", combo+1 )
	
  self:SetCooldown("Punch" , 0.75)
 task.delay(1, function() 
   self:ResetHumanoid()
 end)

  if self.ResetCombo then 
   task.cancel(self.ResetCombo)
   self.ResetCombo = nil
 end

self.ResetCombo = task.delay(5 , function()
	self:SetState("HasCombo", 1)
	print("Resetting Combo")
end)	

end
--[[
Used The CharacterAdded Event In Order For The States To Be Not Lost By The Combat Object
]]
Players.PlayerAdded:Connect(function(plr)
	plr.CharacterAdded:Connect(function(character)
	local plrCombat:Combat = Combat.New(character)
		plrCombat:SetState("IsBlocking" , false)
		plrCombat:SetState("IsStunned" , false)
		plrCombat:SetState("HasCombo" , 1)
		plrCombat:SetState("IsRagdoll" , false )
		plrCombat:SetState("IsDashing" , false)
		
		plrCombat:OnChanged(function(state , value)
			combatRemote:FireClient(plr , state , value)
		end)
		
	end)
end)

--Remove The Player's Combat Object In Order To Prevent Further Memory Leaks
Players.PlayerRemoving:Connect(function(plr)
	PlayerCombats[plr.UserId] = nil
end)

--[[
Get The Input In The Form Of A String From The Client In Order To Stop Exploits
]]
combatRemote.OnServerEvent:Connect(function(plr , event:string)
	if not AllowedEvents[event] then return end  
	local plrcombat = PlayerCombats[plr.UserId]     
	if  plrcombat.Cooldowns[event]  then return end
	local method = plrcombat[event]
	
	if type(method) ~= "function" then return end
	
	method(plrcombat)
end)

