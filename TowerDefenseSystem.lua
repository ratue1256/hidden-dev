-- Discord: e_z_1_o | Roblox: ezio25eziopro

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

-- CollectionService tags are used to automatically detect towers and enemies.
-- Any Model tagged with "Tower" is registered by the tower manager below.
local TOWER_TAG = "Tower"
local ENEMY_TAG = "Enemy"

-- These values are used when a tower does not have the corresponding
-- attribute configured. Individual towers can override them with attributes.
local DEFAULT_CONFIG = {
	Range = 45,
	Damage = 18,
	FireInterval = 0.65,
	ProjectileSpeed = 100,
	ProjectileLifetime = 5,
	ProjectileGravity = 0,
	HomingStrength = 2.5,
	RotationResponsiveness = 10,
	AimToleranceDegrees = 8,
	TargetRefreshInterval = 0.2,
	RequireLineOfSight = true,
	TargetMode = "First",
	MaxProjectilePoolSize = 40,
}

-- All active and pooled projectile visuals are stored in this folder.
-- Keeping them in one folder makes raycast filtering and cleanup easier.
local PROJECTILE_FOLDER = Workspace:FindFirstChild("TowerProjectiles")

if not PROJECTILE_FOLDER then
	PROJECTILE_FOLDER = Instance.new("Folder")
	PROJECTILE_FOLDER.Name = "TowerProjectiles"
	PROJECTILE_FOLDER.Parent = Workspace
end

-- Reads a numeric attribute while guaranteeing that invalid or too-small
-- values do not break tower behavior.
local function getNumberAttribute(instance, name, fallback, minimum)
	local value = instance:GetAttribute(name)

	if typeof(value) ~= "number" then
		return fallback
	end

	if minimum ~= nil then
		return math.max(value, minimum)
	end

	return value
end

-- Reads a boolean attribute and uses the default value if the attribute
-- has not been configured correctly.
local function getBooleanAttribute(instance, name, fallback)
	local value = instance:GetAttribute(name)

	if typeof(value) == "boolean" then
		return value
	end

	return fallback
end

-- Reads a string attribute and rejects empty strings because they cannot
-- represent a valid targeting mode.
local function getStringAttribute(instance, name, fallback)
	local value = instance:GetAttribute(name)

	if typeof(value) == "string" and value ~= "" then
		return value
	end

	return fallback
end

-- Attachments and BaseParts expose their position differently.
-- This helper gives the rest of the script one consistent way to obtain
-- the world position of a muzzle or another valid object.
local function getWorldPosition(instance)
	if instance:IsA("Attachment") then
		return instance.WorldPosition
	end

	if instance:IsA("BasePart") then
		return instance.Position
	end

	error(instance:GetFullName() .. " is not a BasePart or Attachment")
end

-- This is the CFrame equivalent of getWorldPosition().
-- It is used when the projectile needs to inherit the muzzle orientation.
local function getWorldCFrame(instance)
	if instance:IsA("Attachment") then
		return instance.WorldCFrame
	end

	if instance:IsA("BasePart") then
		return instance.CFrame
	end

	error(instance:GetFullName() .. " is not a BasePart or Attachment")
end

-- Finds the first ancestor carrying a specific CollectionService tag.
-- Raycasts usually hit a body part, not the enemy Model itself, so this
-- function converts the hit part back into the tagged enemy model.
local function findTaggedAncestor(instance, tag)
	local current = instance

	while current and current ~= Workspace do
		if CollectionService:HasTag(current, tag) then
			return current
		end

		current = current.Parent
	end

	return nil
end

-- Enemies can use different body structures, so the script accepts a
-- HumanoidRootPart, PrimaryPart, or Head as the tracking point.
local function getEnemyComponents(enemy)
	if not enemy or not enemy.Parent then
		return nil, nil
	end

	local humanoid = enemy:FindFirstChildOfClass("Humanoid")
	local root = enemy:FindFirstChild("HumanoidRootPart")
		or enemy.PrimaryPart
		or enemy:FindFirstChild("Head")

	if not humanoid or not root or not root:IsA("BasePart") then
		return nil, nil
	end

	return humanoid, root
end

-- This check is used before selecting, aiming at, or damaging an enemy.
-- It prevents towers and projectiles from keeping references to dead targets.
local function isEnemyAlive(enemy)
	local humanoid, root = getEnemyComponents(enemy)

	return humanoid ~= nil
		and root ~= nil
		and humanoid.Health > 0
		and humanoid:GetState() ~= Enum.HumanoidStateType.Dead
end

-- Creates the shared projectile template once.
-- Every projectile in the pool is cloned from this object instead of
-- rebuilding lights, attachments, and trails for every shot.
local function createProjectileTemplate()
	local existing = ReplicatedStorage:FindFirstChild("TowerProjectileTemplate")

	if existing and existing:IsA("BasePart") then
		return existing
	end

	local projectile = Instance.new("Part")
	projectile.Name = "TowerProjectileTemplate"
	projectile.Shape = Enum.PartType.Ball
	projectile.Size = Vector3.new(0.65, 0.65, 0.65)
	projectile.Material = Enum.Material.Neon
	projectile.Color = Color3.fromRGB(255, 145, 35)
	projectile.Anchored = true
	projectile.CanCollide = false
	projectile.CanTouch = false
	projectile.CanQuery = false
	projectile.CastShadow = false

	-- The light makes the projectile visible even when it moves quickly.
	local light = Instance.new("PointLight")
	light.Name = "ProjectileLight"
	light.Color = projectile.Color
	light.Brightness = 1.5
	light.Range = 7
	light.Parent = projectile

	-- These attachments define the two ends of the projectile trail.
	local attachment0 = Instance.new("Attachment")
	attachment0.Name = "TrailStart"
	attachment0.Position = Vector3.new(0, 0, 0.25)
	attachment0.Parent = projectile

	local attachment1 = Instance.new("Attachment")
	attachment1.Name = "TrailEnd"
	attachment1.Position = Vector3.new(0, 0, -0.25)
	attachment1.Parent = projectile

	local trail = Instance.new("Trail")
	trail.Name = "ProjectileTrail"
	trail.Attachment0 = attachment0
	trail.Attachment1 = attachment1
	trail.Color = ColorSequence.new(projectile.Color)
	trail.Lifetime = 0.12
	trail.LightEmission = 1
	trail.FaceCamera = true
	trail.Parent = projectile

	projectile.Parent = ReplicatedStorage

	return projectile
end

local PROJECTILE_TEMPLATE = createProjectileTemplate()

-- Creates a short-lived visual effect at the point where a projectile hits
-- an enemy or an obstacle. Debris automatically removes the effect later.
local function createImpactEffect(position, color)
	local effectPart = Instance.new("Part")
	effectPart.Name = "ProjectileImpact"
	effectPart.Size = Vector3.new(0.2, 0.2, 0.2)
	effectPart.Transparency = 1
	effectPart.Anchored = true
	effectPart.CanCollide = false
	effectPart.CanTouch = false
	effectPart.CanQuery = false
	effectPart.CFrame = CFrame.new(position)
	effectPart.Parent = PROJECTILE_FOLDER

	local attachment = Instance.new("Attachment")
	attachment.Parent = effectPart

	local particles = Instance.new("ParticleEmitter")
	particles.Name = "ImpactParticles"
	particles.Color = ColorSequence.new(color)
	particles.LightEmission = 1
	particles.Lifetime = NumberRange.new(0.15, 0.3)
	particles.Speed = NumberRange.new(4, 8)
	particles.Drag = 5
	particles.SpreadAngle = Vector2.new(180, 180)
	particles.Rate = 0
	particles.Rotation = NumberRange.new(0, 360)
	particles.RotSpeed = NumberRange.new(-180, 180)
	particles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 0),
	})
	particles.Parent = attachment
	particles:Emit(10)

	Debris:AddItem(effectPart, 0.5)
end

-- Projectile objects are reused through a pool.
-- This reduces cloning and destroying operations when many towers fire
-- repeatedly during the same game.
local Projectile = {}
Projectile.__index = Projectile

local projectilePool = {}
local activeProjectiles = {}

function Projectile.new()
	local self = setmetatable({}, Projectile)

	self.Visual = PROJECTILE_TEMPLATE:Clone()
	self.Visual.Name = "PooledTowerProjectile"

	-- Pooled projectiles start hidden and far below the map until acquired.
	self.Visual.Transparency = 1
	self.Visual.CFrame = CFrame.new(0, -1000, 0)
	self.Visual.Parent = PROJECTILE_FOLDER

	self.Active = false
	self.Position = Vector3.zero
	self.Velocity = Vector3.zero
	self.Age = 0
	self.Damage = 0
	self.Speed = 0
	self.Gravity = 0
	self.HomingStrength = 0
	self.MaximumLifetime = 0
	self.Target = nil
	self.Owner = nil
	self.RaycastParameters = nil

	return self
end

-- Takes a projectile from the pool, or creates one if the pool is empty.
function Projectile.Acquire()
	local projectile = table.remove(projectilePool)

	if not projectile then
		projectile = Projectile.new()
	end

	projectile.Active = true
	projectile.Visual.Transparency = 0

	local trail = projectile.Visual:FindFirstChildOfClass("Trail")

	if trail then
		trail.Enabled = true
	end

	return projectile
end

-- Returns a projectile to the pool after it expires or collides.
-- If the configured pool limit has been reached, the visual is destroyed
-- instead of being stored.
function Projectile:Release(maximumPoolSize)
	if not self.Active then
		return
	end

	self.Active = false
	self.Target = nil
	self.Owner = nil
	self.RaycastParameters = nil
	self.Visual.Transparency = 1
	self.Visual.CFrame = CFrame.new(0, -1000, 0)

	local trail = self.Visual:FindFirstChildOfClass("Trail")

	if trail then
		trail.Enabled = false
		trail:Clear()
	end

	if #projectilePool < maximumPoolSize then
		table.insert(projectilePool, self)
	else
		self.Visual:Destroy()
	end
end

-- Initializes the projectile's movement data.
-- The initial direction uses target prediction, while later updates apply
-- homing so the projectile can correct its path as the enemy moves.
function Projectile:Launch(owner, origin, target, configuration)
	self.Owner = owner
	self.Target = target
	self.Position = origin
	self.Age = 0
	self.Damage = configuration.Damage
	self.Speed = configuration.ProjectileSpeed
	self.Gravity = configuration.ProjectileGravity
	self.HomingStrength = configuration.HomingStrength
	self.MaximumLifetime = configuration.ProjectileLifetime

	local predictedPosition = owner:GetPredictedTargetPosition(
		origin,
		target,
		self.Speed
	)

	local direction = predictedPosition - origin

	if direction.Magnitude < 0.001 then
		direction = owner.Head.CFrame.LookVector
	else
		direction = direction.Unit
	end

	self.Velocity = direction * self.Speed

	-- Raycast filtering prevents a projectile from hitting its own tower,
	-- another projectile, or the projectile folder itself.
	self.RaycastParameters = RaycastParams.new()
	self.RaycastParameters.FilterType = Enum.RaycastFilterType.Exclude
	self.RaycastParameters.IgnoreWater = true
	self.RaycastParameters.FilterDescendantsInstances = {
		PROJECTILE_FOLDER,
		owner.Model,
	}

	self.Visual.CFrame = CFrame.lookAt(
		origin,
		origin + self.Velocity.Unit
	)
end

-- Applies damage only when the raycast hit a valid tagged enemy.
-- The attribute can be used by other systems to identify the tower that
-- most recently damaged the humanoid.
function Projectile:DamageEnemy(enemy)
	if not enemy or not CollectionService:HasTag(enemy, ENEMY_TAG) then
		return
	end

	local humanoid = getEnemyComponents(enemy)

	if not humanoid or humanoid.Health <= 0 then
		return
	end

	if self.Owner and self.Owner.Model.Parent then
		humanoid:SetAttribute("LastDamagedByTower", self.Owner.Model.Name)
	end

	humanoid:TakeDamage(self.Damage)
end

-- Updates one projectile for one Heartbeat frame.
-- Returning false tells the main update loop that the projectile must be
-- released back into the pool.
function Projectile:Update(deltaTime)
	if not self.Active then
		return false
	end

	self.Age += deltaTime

	-- Lifetime prevents lost projectiles from remaining active forever.
	if self.Age >= self.MaximumLifetime then
		return false
	end

	-- Homing adjusts the current velocity toward the enemy's current position.
	-- Exponential interpolation keeps the response consistent across frame rates.
	if self.Target and isEnemyAlive(self.Target) then
		local _, targetRoot = getEnemyComponents(self.Target)

		if targetRoot then
			local offset = targetRoot.Position - self.Position

			if offset.Magnitude > 0.001 then
				local desiredVelocity = offset.Unit * self.Speed
				local homingAlpha = 1 - math.exp(
					-self.HomingStrength * deltaTime
				)

				self.Velocity = self.Velocity:Lerp(
					desiredVelocity,
					homingAlpha
				)
			end
		end
	end

	-- Gravity changes the vertical component of the velocity before moving
	-- the projectile.
	self.Velocity += Vector3.new(
		0,
		-self.Gravity * deltaTime,
		0
	)

	local oldPosition = self.Position
	local displacement = self.Velocity * deltaTime

	-- A raycast is used instead of relying on Touched because the projectile
	-- is anchored and may travel several studs during one frame.
	local raycastResult = Workspace:Raycast(
		oldPosition,
		displacement,
		self.RaycastParameters
	)

	if raycastResult then
		self.Position = raycastResult.Position
		self.Visual.CFrame = CFrame.new(self.Position)

		local enemy = findTaggedAncestor(
			raycastResult.Instance,
			ENEMY_TAG
		)

		if enemy then
			self:DamageEnemy(enemy)
		end

		createImpactEffect(
			raycastResult.Position,
			self.Visual.Color
		)

		return false
	end

	self.Position = oldPosition + displacement

	-- This secondary check helps the projectile hit a moving target when the
	-- raycast passes close to the target without directly touching its parts.
	if self.Target and isEnemyAlive(self.Target) then
		local _, targetRoot = getEnemyComponents(self.Target)

		if targetRoot then
			local contactRadius = math.max(
				1.5,
				displacement.Magnitude
			)

			if (targetRoot.Position - self.Position).Magnitude <= contactRadius then
				self:DamageEnemy(self.Target)
				createImpactEffect(
					self.Position,
					self.Visual.Color
				)

				return false
			end
		end
	end

	-- Orient the visual in the direction in which the projectile is moving.
	local lookDirection = self.Velocity

	if lookDirection.Magnitude < 0.001 then
		lookDirection = Vector3.zAxis
	end

	self.Visual.CFrame = CFrame.lookAt(
		self.Position,
		self.Position + lookDirection.Unit
	)

	return true
end

local Tower = {}
Tower.__index = Tower

-- Creates the runtime controller for one tower model.
-- The model must contain a BasePart named Head and may contain a Muzzle
-- BasePart or Attachment.
function Tower.new(model)
	local self = setmetatable({}, Tower)

	self.Model = model
	self.Head = model:FindFirstChild("Head", true)
	self.Muzzle = model:FindFirstChild("Muzzle", true)
	self.Target = nil
	self.FireCooldown = 0
	self.TargetRefreshCooldown = 0
	self.Destroyed = false
	self.Config = self:ReadConfiguration()

	if not self.Head or not self.Head:IsA("BasePart") then
		error(model:GetFullName() .. " requires a BasePart named Head")
	end

	if not self.Muzzle then
		self.Muzzle = self.Head
	end

	if not self.Muzzle:IsA("BasePart")
		and not self.Muzzle:IsA("Attachment")
	then
		error("Muzzle must be a BasePart or Attachment")
	end

	return self
end

-- Builds a complete configuration table from model attributes.
-- Centralizing configuration here allows the update and projectile systems
-- to use the same values without repeatedly reading attributes.
function Tower:ReadConfiguration()
	return {
		Range = getNumberAttribute(self.Model, "Range", DEFAULT_CONFIG.Range, 1),
		Damage = getNumberAttribute(self.Model, "Damage", DEFAULT_CONFIG.Damage, 0),
		FireInterval = getNumberAttribute(
			self.Model,
			"FireInterval",
			DEFAULT_CONFIG.FireInterval,
			0.05
		),
		ProjectileSpeed = getNumberAttribute(
			self.Model,
			"ProjectileSpeed",
			DEFAULT_CONFIG.ProjectileSpeed,
			1
		),
		ProjectileLifetime = getNumberAttribute(
			self.Model,
			"ProjectileLifetime",
			DEFAULT_CONFIG.ProjectileLifetime,
			0.1
		),
		ProjectileGravity = getNumberAttribute(
			self.Model,
			"ProjectileGravity",
			DEFAULT_CONFIG.ProjectileGravity,
			0
		),
		HomingStrength = getNumberAttribute(
			self.Model,
			"HomingStrength",
			DEFAULT_CONFIG.HomingStrength,
			0
		),
		RotationResponsiveness = getNumberAttribute(
			self.Model,
			"RotationResponsiveness",
			DEFAULT_CONFIG.RotationResponsiveness,
			0
		),
		AimToleranceDegrees = getNumberAttribute(
			self.Model,
			"AimToleranceDegrees",
			DEFAULT_CONFIG.AimToleranceDegrees,
			0
		),
		TargetRefreshInterval = getNumberAttribute(
			self.Model,
			"TargetRefreshInterval",
			DEFAULT_CONFIG.TargetRefreshInterval,
			0.05
		),
		RequireLineOfSight = getBooleanAttribute(
			self.Model,
			"RequireLineOfSight",
			DEFAULT_CONFIG.RequireLineOfSight
		),
		TargetMode = getStringAttribute(
			self.Model,
			"TargetMode",
			DEFAULT_CONFIG.TargetMode
		),
		MaxProjectilePoolSize = getNumberAttribute(
			self.Model,
			"MaxProjectilePoolSize",
			DEFAULT_CONFIG.MaxProjectilePoolSize,
			0
		),
	}
end

-- Checks distance using squared magnitude to avoid an unnecessary square root.
function Tower:IsTargetInRange(enemy)
	if not isEnemyAlive(enemy) then
		return false
	end

	local _, root = getEnemyComponents(enemy)

	if not root then
		return false
	end

	local offset = root.Position - getWorldPosition(self.Muzzle)

	return offset:Dot(offset) <= self.Config.Range ^ 2
end

-- Uses a raycast to ensure that walls or other level geometry do not block
-- the tower from attacking its selected enemy.
function Tower:HasLineOfSight(enemy)
	if not self.Config.RequireLineOfSight then
		return true
	end

	local _, root = getEnemyComponents(enemy)

	if not root then
		return false
	end

	local origin = getWorldPosition(self.Muzzle)
	local direction = root.Position - origin

	if direction.Magnitude < 0.001 then
		return true
	end

	local parameters = RaycastParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.IgnoreWater = true
	parameters.FilterDescendantsInstances = {
		self.Model,
		PROJECTILE_FOLDER,
	}

	local result = Workspace:Raycast(
		origin,
		direction,
		parameters
	)

	if not result then
		return true
	end

	-- The target is visible only if the first object hit belongs to the enemy.
	return result.Instance:IsDescendantOf(enemy)
end

-- Converts the selected targeting mode into a numerical score.
-- The enemy with the lowest score becomes the selected target.
function Tower:GetTargetScore(enemy, distance)
	local humanoid = getEnemyComponents(enemy)

	if not humanoid then
		return math.huge
	end

	local mode = string.lower(self.Config.TargetMode)
	local pathProgress = enemy:GetAttribute("PathProgress")

	if typeof(pathProgress) ~= "number" then
		pathProgress = 0
	end

	if mode == "first" then
		return -pathProgress
	elseif mode == "last" then
		return pathProgress
	elseif mode == "strongest" then
		return -humanoid.Health
	elseif mode == "weakest" then
		return humanoid.Health
	elseif mode == "closest" then
		return distance
	end

	-- Unknown modes safely fall back to closest-target behavior.
	return distance
end

-- Searches every tagged enemy and selects the best valid candidate.
-- Range and line-of-sight checks are performed before calculating the score
-- so invalid enemies are never selected.
function Tower:FindTarget()
	local bestEnemy = nil
	local bestScore = math.huge
	local origin = getWorldPosition(self.Muzzle)

	for _, enemy in CollectionService:GetTagged(ENEMY_TAG) do
		if not self:IsTargetInRange(enemy) then
			continue
		end

		if not self:HasLineOfSight(enemy) then
			continue
		end

		local _, root = getEnemyComponents(enemy)

		if not root then
			continue
		end

		local distance = (root.Position - origin).Magnitude
		local score = self:GetTargetScore(enemy, distance)

		if score < bestScore then
			bestScore = score
			bestEnemy = enemy
		end
	end

	return bestEnemy
end

-- Calculates where the enemy is expected to be when the projectile arrives.
-- This solves an interception problem using the enemy's current velocity and
-- the projectile's speed, which is more accurate than aiming at the current
-- position only.
function Tower:GetPredictedTargetPosition(origin, enemy, projectileSpeed)
	local _, root = getEnemyComponents(enemy)

	if not root then
		return origin
	end

	local relativePosition = root.Position - origin
	local targetVelocity = root.AssemblyLinearVelocity

	local a = targetVelocity:Dot(targetVelocity)
		- projectileSpeed * projectileSpeed

	local b = 2 * relativePosition:Dot(targetVelocity)
	local c = relativePosition:Dot(relativePosition)

	local interceptTime = nil

	-- This branch handles the case where the quadratic equation becomes
	-- nearly linear because the coefficient "a" is close to zero.
	if math.abs(a) < 0.001 then
		if math.abs(b) > 0.001 then
			local linearTime = -c / b

			if linearTime > 0 then
				interceptTime = linearTime
			end
		end
	else
		local discriminant = b * b - 4 * a * c

		if discriminant >= 0 then
			local squareRoot = math.sqrt(discriminant)
			local firstTime = (-b - squareRoot) / (2 * a)
			local secondTime = (-b + squareRoot) / (2 * a)

			if firstTime > 0 and secondTime > 0 then
				interceptTime = math.min(firstTime, secondTime)
			elseif firstTime > 0 then
				interceptTime = firstTime
			elseif secondTime > 0 then
				interceptTime = secondTime
			end
		end
	end

	-- If no valid interception time exists, aim using the direct distance.
	if not interceptTime then
		interceptTime = relativePosition.Magnitude / projectileSpeed
	end

	-- Limiting prediction prevents extreme values when an enemy is very fast
	-- or when the projectile speed is low.
	interceptTime = math.clamp(interceptTime, 0, 2)

	return root.Position + targetVelocity * interceptTime
end

-- Rotates the tower horizontally toward its current target.
-- Exponential interpolation prevents instant snapping and keeps the rotation
-- smooth regardless of the server frame rate.
function Tower:RotateTowardsTarget(deltaTime)
	if not self.Target then
		return
	end

	local _, root = getEnemyComponents(self.Target)

	if not root then
		return
	end

	local headPosition = self.Head.Position
	local flatDirection = Vector3.new(
		root.Position.X - headPosition.X,
		0,
		root.Position.Z - headPosition.Z
	)

	if flatDirection.Magnitude < 0.001 then
		return
	end

	local goalCFrame = CFrame.lookAt(
		headPosition,
		headPosition + flatDirection.Unit,
		Vector3.yAxis
	)

	local alpha = 1 - math.exp(
		-self.Config.RotationResponsiveness * deltaTime
	)

	self.Head.CFrame = self.Head.CFrame:Lerp(
		goalCFrame,
		alpha
	)
end

-- Verifies that the tower is facing the target within the configured angle.
-- This prevents the tower from firing backward while it is still rotating.
function Tower:IsAimedAtTarget()
	if not self.Target then
		return false
	end

	local _, root = getEnemyComponents(self.Target)

	if not root then
		return false
	end

	local direction = root.Position - self.Head.Position
	local flatDirection = Vector3.new(
		direction.X,
		0,
		direction.Z
	)

	if flatDirection.Magnitude < 0.001 then
		return true
	end

	local forward = self.Head.CFrame.LookVector
	local flatForward = Vector3.new(
		forward.X,
		0,
		forward.Z
	)

	if flatForward.Magnitude < 0.001 then
		return false
	end

	local alignment = flatForward.Unit:Dot(flatDirection.Unit)
	local minimumAlignment = math.cos(
		math.rad(self.Config.AimToleranceDegrees)
	)

	return alignment >= minimumAlignment
end

-- Creates and launches a projectile from the tower muzzle.
-- The projectile is added to activeProjectiles so the Heartbeat loop can
-- update its position and collision every frame.
function Tower:Fire()
	if not self.Target or not isEnemyAlive(self.Target) then
		return
	end

	local projectile = Projectile.Acquire()
	local muzzlePosition = getWorldPosition(self.Muzzle)

	projectile.Visual.CFrame = getWorldCFrame(self.Muzzle)

	projectile:Launch(
		self,
		muzzlePosition,
		self.Target,
		self.Config
	)

	table.insert(activeProjectiles, projectile)
end

-- Main per-tower update:
-- 1. Decrease cooldowns.
-- 2. Refresh or invalidate the target.
-- 3. Rotate toward the target.
-- 4. Fire only when cooldown, aim, and visibility checks succeed.
function Tower:Update(deltaTime)
	if self.Destroyed or not self.Model.Parent then
		return
	end

	self.FireCooldown = math.max(
		0,
		self.FireCooldown - deltaTime
	)

	self.TargetRefreshCooldown -= deltaTime

	if self.Target and not self:IsTargetInRange(self.Target) then
		self.Target = nil
	end

	if self.TargetRefreshCooldown <= 0 then
		self.TargetRefreshCooldown = self.Config.TargetRefreshInterval

		if not self.Target
			or not self:IsTargetInRange(self.Target)
			or not self:HasLineOfSight(self.Target)
		then
			self.Target = self:FindTarget()
		end
	end

	if not self.Target then
		return
	end

	self:RotateTowardsTarget(deltaTime)

	if self.FireCooldown > 0 then
		return
	end

	if not self:IsAimedAtTarget() then
		return
	end

	if not self:HasLineOfSight(self.Target) then
		return
	end

	self:Fire()
	self.FireCooldown = self.Config.FireInterval
end

-- Marks the tower as inactive. The manager removes it from activeTowers
-- when its CollectionService tag is removed or its model is destroyed.
function Tower:Destroy()
	self.Destroyed = true
	self.Target = nil
end

local activeTowers = {}

-- Registers a tagged model as a tower only once.
-- pcall prevents one invalid tower from stopping the complete tower system.
local function registerTower(instance)
	if not instance:IsA("Model") then
		warn("Tower tag can only be used on Models:", instance:GetFullName())
		return
	end

	if activeTowers[instance] then
		return
	end

	local success, towerOrError = pcall(Tower.new, instance)

	if not success then
		warn("Failed to initialize tower:", towerOrError)
		return
	end

	activeTowers[instance] = towerOrError
end

-- Stops updating a tower after its tag is removed.
local function unregisterTower(instance)
	local tower = activeTowers[instance]

	if not tower then
		return
	end

	tower:Destroy()
	activeTowers[instance] = nil
end

-- Register towers that already exist before this script starts.
for _, towerModel in CollectionService:GetTagged(TOWER_TAG) do
	registerTower(towerModel)
end

-- Automatically register and unregister towers added or removed later.
CollectionService:GetInstanceAddedSignal(TOWER_TAG):Connect(
	registerTower
)

CollectionService:GetInstanceRemovedSignal(TOWER_TAG):Connect(
	unregisterTower
)

-- A single Heartbeat loop updates every tower and every projectile.
-- Clamping deltaTime avoids extremely large movement steps after lag spikes,
-- which improves projectile collision reliability.
RunService.Heartbeat:Connect(function(deltaTime)
	deltaTime = math.min(deltaTime, 0.1)

	for model, tower in activeTowers do
		if model.Parent then
			tower:Update(deltaTime)
		else
			unregisterTower(model)
		end
	end

	-- Iterate backwards because expired projectiles are removed from the array.
	for index = #activeProjectiles, 1, -1 do
		local projectile = activeProjectiles[index]
		local stillActive = projectile:Update(deltaTime)

		if not stillActive then
			local maximumPoolSize = DEFAULT_CONFIG.MaxProjectilePoolSize

			-- Use the owner's pool setting when available, allowing different
			-- towers to control their own projectile memory usage.
			if projectile.Owner then
				maximumPoolSize =
					projectile.Owner.Config.MaxProjectilePoolSize
			end

			projectile:Release(maximumPoolSize)
			table.remove(activeProjectiles, index)
		end
	end
end)

-- Clean up all tower and projectile objects when the script is destroyed.
-- This prevents old references, active visuals, and pooled instances from
-- remaining in the game.
script.Destroying:Connect(function()
	for _, tower in activeTowers do
		tower:Destroy()
	end

	table.clear(activeTowers)

	for _, projectile in activeProjectiles do
		projectile:Release(0)
	end

	table.clear(activeProjectiles)

	for _, projectile in projectilePool do
		if projectile.Visual then
			projectile.Visual:Destroy()
		end
	end

	table.clear(projectilePool)
end)
