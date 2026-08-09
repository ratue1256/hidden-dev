-- Discord: e_z_1_o | Roblox: ezio25eziopro
local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local TOWER_TAG = "Tower"
local ENEMY_TAG = "Enemy"

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

local PROJECTILE_FOLDER = Workspace:FindFirstChild("TowerProjectiles")

if not PROJECTILE_FOLDER then
	PROJECTILE_FOLDER = Instance.new("Folder")
	PROJECTILE_FOLDER.Name = "TowerProjectiles"
	PROJECTILE_FOLDER.Parent = Workspace
end

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

local function getBooleanAttribute(instance, name, fallback)
	local value = instance:GetAttribute(name)

	if typeof(value) == "boolean" then
		return value
	end

	return fallback
end

local function getStringAttribute(instance, name, fallback)
	local value = instance:GetAttribute(name)

	if typeof(value) == "string" and value ~= "" then
		return value
	end

	return fallback
end

local function getWorldPosition(instance)
	if instance:IsA("Attachment") then
		return instance.WorldPosition
	end

	if instance:IsA("BasePart") then
		return instance.Position
	end

	error(instance:GetFullName() .. " is not a BaseParp or Attachment")
end

local function getWorldCFrame(instance)
	if instance:IsA("Attachment") then
		return instance.WorldCFrame
	end

	if instance:IsA("BasePart") then
		return instance.CFrame
	end

	error(instance:GetFullName() .. " is not a BasePart or Attachment")
end

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

local function isEnemyAlive(enemy)
	local humanoid, root = getEnemyComponents(enemy)

	return humanoid ~= nil
		and root ~= nil
		and humanoid.Health > 0
		and humanoid:GetState() ~= Enum.HumanoidStateType.Dead
end

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

	local light = Instance.new("PointLight")
	light.Name = "ProjectileLight"
	light.Color = projectile.Color
	light.Brightness = 1.5
	light.Range = 7
	light.Parent = projectile

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

local Projectile = {}
Projectile.__index = Projectile

local projectilePool = {}
local activeProjectiles = {}

function Projectile.new()
	local self = setmetatable({}, Projectile)

	self.Visual = PROJECTILE_TEMPLATE:Clone()
	self.Visual.Name = "PooledTowerProjectile"
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

function Projectile:Update(deltaTime)
	if not self.Active then
		return false
	end

	self.Age += deltaTime

	if self.Age >= self.MaximumLifetime then
		return false
	end

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

	self.Velocity += Vector3.new(
		0,
		-self.Gravity * deltaTime,
		0
	)

	local oldPosition = self.Position
	local displacement = self.Velocity * deltaTime
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

function Tower:ReadConfiguration()
	return {
		Range = getNumberAttribute(
			self.Model,
			"Range",
			DEFAULT_CONFIG.Range,
			1
		),

		Damage = getNumberAttribute(
			self.Model,
			"Damage",
			DEFAULT_CONFIG.Damage,
			0
		),

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

	return result.Instance:IsDescendantOf(enemy)
end

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

	return distance
end

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

	if not interceptTime then
		interceptTime = relativePosition.Magnitude / projectileSpeed
	end

	interceptTime = math.clamp(interceptTime, 0, 2)

	return root.Position + targetVelocity * interceptTime
end

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

function Tower:Destroy()
	self.Destroyed = true
	self.Target = nil
end

local activeTowers = {}

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

local function unregisterTower(instance)
	local tower = activeTowers[instance]

	if not tower then
		return
	end

	tower:Destroy()
	activeTowers[instance] = nil
end

for _, towerModel in CollectionService:GetTagged(TOWER_TAG) do
	registerTower(towerModel)
end

CollectionService:GetInstanceAddedSignal(TOWER_TAG):Connect(
	registerTower
)

CollectionService:GetInstanceRemovedSignal(TOWER_TAG):Connect(
	unregisterTower
)

RunService.Heartbeat:Connect(function(deltaTime)
	deltaTime = math.min(deltaTime, 0.1)

	for model, tower in activeTowers do
		if model.Parent then
			tower:Update(deltaTime)
		else
			unregisterTower(model)
		end
	end

	for index = #activeProjectiles, 1, -1 do
		local projectile = activeProjectiles[index]
		local stillActive = projectile:Update(deltaTime)

		if not stillActive then
			local maximumPoolSize = DEFAULT_CONFIG.MaxProjectilePoolSize

			if projectile.Owner then
				maximumPoolSize =
					projectile.Owner.Config.MaxProjectilePoolSize
			end

			projectile:Release(maximumPoolSize)
			table.remove(activeProjectiles, index)
		end
	end
end)

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
