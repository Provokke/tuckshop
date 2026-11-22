--!strict
-- Tuckshop server entry. This is where services, remotes and the DataStore are touched. The rules
-- themselves live in the modules next to it and are covered by the Lune tests.

-- First, before anything that can yield or fail: a ProcessReceipt callback that leaves every
-- purchase for later. With no callback at all, Roblox acknowledges receipts on its own and the
-- Robux are taken with nothing granted. If start-up stops early (a config problem, a module that
-- fails to load), this one stays in place and Roblox keeps the receipts until a server can grant
-- them. Once everything is built, it is replaced by the real handler further down.
local MarketplaceService = game:GetService("MarketplaceService")
MarketplaceService.ProcessReceipt = function(_info: { [string]: any }): Enum.ProductPurchaseDecision
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

local CollectionService = game:GetService("CollectionService")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Tuckshop")
local Config = require(Shared:WaitForChild("Config"))
local ConfigCheck = require(Shared:WaitForChild("ConfigCheck"))
local RateLimiter = require(Shared:WaitForChild("RateLimiter"))
local Validate = require(Shared:WaitForChild("Validate"))

local Handlers = require(script.Handlers)
local Lease = require(script.Data.Lease)
local Ledger = require(script.Shop.Ledger)
local MemoryStore = require(script.Data.MemoryStore)
local Migrations = require(script.Data.Migrations)
local Passes = require(script.Shop.Passes)
local Profile = require(script.Data.Profile)
local Receipts = require(script.Shop.Receipts)
local Rotation = require(script.Shop.Rotation)
local Sessions = require(script.Sessions)
local Shop = require(script.Shop.Shop)
local Steps = require(script.Data.Steps)
local Store = require(script.Data.Store)

local problems = ConfigCheck.check(Config, Steps)
if #problems > 0 then
	for _, problem in problems do
		warn("[Tuckshop] config problem: " .. problem)
	end
	warn("[Tuckshop] not starting until the config is fixed. Purchases are left for Roblox to retry.")
	return
end

-- Data store. Studio uses an in-memory table unless ServerStorage has TuckshopUseDataStore = true.
local useRealStore = not RunService:IsStudio() or ServerStorage:GetAttribute("TuckshopUseDataStore") == true
local dataStore: any
if useRealStore then
	dataStore = DataStoreService:GetDataStore(Config.DataStoreName)
else
	dataStore = MemoryStore.new()
	print(
		"[Tuckshop] Studio: using an in-memory store. Set ServerStorage attribute TuckshopUseDataStore to use the real one."
	)
end

-- Every Studio play test gets its own id, so a lease left behind by a crashed or parallel test
-- reads as someone else's (and runs out) rather than as ours.
local jobId = if game.JobId ~= "" then game.JobId else "studio-" .. HttpService:GenerateGUID(false)

local function log(message: string)
	warn("[Tuckshop] " .. message)
end

local profile = Profile.new({
	newWallet = function()
		return Ledger.new(Config.Currencies)
	end,
})

local store = Store.new({
	dataStore = dataStore,
	lease = Lease,
	migrations = Migrations,
	clock = os.time,
	wait = task.wait,
	budget = function(_kind: string): number
		if not useRealStore then
			return 100 -- the in-memory store has no request budget
		end
		return DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync)
	end,
	jobId = jobId,
	nonce = function(): string
		return HttpService:GenerateGUID(false)
	end,
	resume = function(thread: thread)
		task.spawn(thread)
	end,
	leaseSeconds = Config.LeaseSeconds,
	retries = Config.LoadRetries,
	retryBase = Config.RetryBaseSeconds,
	schema = Config.SchemaVersion,
	steps = Steps,
	defaultData = profile.defaultData,
	encode = profile.encode,
	decode = profile.decode,
	log = log,
})

-- Remotes. Request is client to server (intent only); Sync is server to client.
local remotes = Instance.new("Folder")
remotes.Name = "TuckshopRemotes"
local request = Instance.new("RemoteEvent")
request.Name = "Request"
request.Parent = remotes
local sync = Instance.new("RemoteEvent")
sync.Name = "Sync"
sync.Parent = remotes
remotes.Parent = ReplicatedStorage

local passes = Passes.new({
	passes = Config.GamePasses,
	owns = function(userId: number, passId: number): boolean
		return MarketplaceService:UserOwnsGamePassAsync(userId, passId)
	end,
})

-- Declared first: `ready` needs handlers, and handlers need sessions.
local handlers: any
local sessions: any
sessions = Sessions.new({
	store = store,
	keyFor = function(userId: number): string
		return "Player_" .. userId
	end,
	present = function(player: any): boolean
		return player.Parent ~= nil
	end,
	kick = function(player: any, message: string)
		player:Kick(message)
	end,
	playerOf = function(userId: number): any
		return Players:GetPlayerByUserId(userId)
	end,
	ready = function(userId: number, session: any)
		-- Items bought before are in the saved data; show them on the player again.
		local player = Players:GetPlayerByUserId(userId)
		if player ~= nil then
			for itemId, count in session.data.owned do
				player:SetAttribute("Owns_" .. itemId, count)
			end
		end
		handlers:push(userId)
		task.spawn(function()
			passes:refresh(userId)
		end)
	end,
	spawn = function(fn: () -> ())
		task.spawn(fn)
	end,
	wait = function(seconds: number)
		task.wait(seconds)
	end,
	clock = os.clock,
	closeSeconds = Config.CloseTimeoutSeconds,
	log = log,
})

local function itemGranted(userId: number, itemId: string, count: number): (boolean, string?)
	-- Shop has already written the item to the player's data (data.owned, saved with the charge),
	-- and `count` is how many they now own. The demo shows that as an Owns_<itemId> attribute on
	-- the player, which `ready` sets again on every load. A game would give a Tool or unlock a
	-- cosmetic here. Return false to have the charge, the allowance and the item taken back.
	local player = Players:GetPlayerByUserId(userId)
	if player == nil then
		return false, "left"
	end
	player:SetAttribute("Owns_" .. itemId, count)
	return true, nil
end

local shop = Shop.new({
	ledger = Ledger,
	rotation = Rotation,
	catalogue = Config.Catalogue,
	rotationConfig = Config.Rotation,
	clock = os.time,
	logLength = Config.LogLength,
	grant = itemGranted,
})

handlers = Handlers.new({
	validate = Validate,
	limiter = RateLimiter.new(Config.Limits.BurstPerPlayer, Config.Limits.RefillPerSecond, os.clock),
	getSession = function(userId: number): any
		return sessions:get(userId)
	end,
	writableSession = function(userId: number): any
		return sessions:writableSession(userId)
	end,
	shop = shop,
	rotation = Rotation,
	catalogue = Config.Catalogue,
	rotationConfig = Config.Rotation,
	clock = os.time,
	send = function(userId: number, payload: any)
		local player = Players:GetPlayerByUserId(userId)
		if player then
			sync:FireClient(player, payload)
		end
	end,
})

-- Developer products. Each product id in Config.Products grants an amount of a currency. Id 0 is
-- a placeholder that no real purchase uses. The grant credits the session's wallet; Receipts
-- records the PurchaseId and saves before telling Roblox it is done.
local products: { [number]: (session: any) -> boolean } = {}
for productId, def in Config.Products do
	products[productId] = function(session: any): boolean
		local ok = Ledger.apply(
			session.data.wallet,
			def.grant,
			def.amount,
			`product:{productId}`,
			os.time(),
			Config.LogLength
		)
		return ok
	end
end

-- A receipt can arrive while the player's data is still loading. It waits for the load (up to this
-- long) rather than answering NotProcessedYet, which Roblox would only retry at their next purchase
-- or rejoin. A ProcessReceipt callback may yield.
local RECEIPT_WAIT_SECONDS = 30

local receipts = Receipts.new({
	getSession = function(userId: number): any
		return sessions:waitForSession(userId, RECEIPT_WAIT_SECONDS)
	end,
	products = products,
	memory = Config.ReceiptMemory,
	clock = os.time,
	log = log,
})

-- The real handler, replacing the holding one assigned at the top of this script. Nothing else
-- may assign ProcessReceipt: a second assignment anywhere would replace this handler and strand
-- every purchase.
MarketplaceService.ProcessReceipt = function(info: { [string]: any }): Enum.ProductPurchaseDecision
	local ok, result = pcall(function(): string
		return receipts:process({
			PlayerId = info.PlayerId,
			ProductId = info.ProductId,
			PurchaseId = info.PurchaseId,
		})
	end)
	if not ok then
		log("receipt error: " .. tostring(result))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if result == "PurchaseGranted" then
		handlers:push(info.PlayerId)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

MarketplaceService.PromptGamePassPurchaseFinished:Connect(
	function(player: Player, passId: number, wasPurchased: boolean)
		if wasPurchased then
			passes:bought(player.UserId, passId)
		end
	end
)

request.OnServerEvent:Connect(function(player: Player, action: any, arg: any)
	local ok, err = pcall(function()
		handlers:handle(player.UserId, action, arg)
	end)
	if not ok then
		log("request error: " .. tostring(err))
	end
end)

-- The demo coin pad: any part tagged with Config.CoinPad.Tag. Touching it gives Coins, with a
-- cooldown per player. The DoubleCoins perk doubles it here and nowhere else.
local padReadyAt: { [number]: number } = {}

local function onPadTouched(hit: BasePart)
	local player = Players:GetPlayerFromCharacter(hit.Parent)
	if player == nil then
		return
	end
	local userId = player.UserId
	local now = os.clock()
	if (padReadyAt[userId] or 0) > now then
		return
	end
	local session = sessions:writableSession(userId)
	if session == nil then
		return
	end
	padReadyAt[userId] = now + Config.CoinPad.CooldownSeconds
	local reward = Config.CoinPad.Reward * (if passes:has(userId, "DoubleCoins") then 2 else 1)
	Ledger.apply(session.data.wallet, "Coins", reward, "coin pad", os.time(), Config.LogLength)
	handlers:push(userId)
end

local connectedPads: { [Instance]: boolean } = {}
local function connectPad(instance: Instance)
	if connectedPads[instance] or not instance:IsA("BasePart") then
		return
	end
	connectedPads[instance] = true
	instance.Touched:Connect(onPadTouched)
end

for _, instance in CollectionService:GetTagged(Config.CoinPad.Tag) do
	connectPad(instance)
end
CollectionService:GetInstanceAddedSignal(Config.CoinPad.Tag):Connect(connectPad)
if next(connectedPads) == nil then
	warn(
		`[Tuckshop] no part is tagged {Config.CoinPad.Tag}, so there is no coin pad yet. Tag a part to add one.`
	)
end

-- Sessions
local function onPlayerAdded(player: Player)
	sessions:join(player.UserId, player)
end

local function onPlayerRemoving(player: Player)
	local userId = player.UserId
	handlers.deps.limiter:forget(userId)
	padReadyAt[userId] = nil
	passes:forget(userId)
	sessions:leave(userId)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

-- Autosave. A session that has lost its lease is kicked rather than allowed to carry on unsaved.
task.spawn(function()
	while true do
		task.wait(Config.AutosaveSeconds)
		sessions:saveAll()
	end
end)

-- Releases every session and waits for loads and releases still running, within the timeout.
game:BindToClose(function()
	sessions:close()
end)
