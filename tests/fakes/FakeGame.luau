--!strict
-- Runs the real server entry script (src/server/init.server.luau) under Lune, over a small
-- stand-in for the parts of Roblox it touches: the services it asks for, Players and their
-- attributes, remotes, tagged parts, task and Enum. The data store is a FakeDataStore over
-- `records`, and task.spawn and task.wait run on a FakeScheduler, so a test can park a save, move
-- the clock and act while something is still in flight.
--
-- Only what the entry script uses is modelled. A call to anything else fails, so a new service
-- or member used by the script shows up here as an error rather than passing quietly.
local fs = require("@lune/fs")
local luau = require("@lune/luau")

local FakeClock = require("./FakeClock")
local FakeDataStore = require("./FakeDataStore")
local FakeScheduler = require("./FakeScheduler")

local SHARED: { [string]: any } = {
	Config = require("../../src/shared/Config"),
	ConfigCheck = require("../../src/shared/ConfigCheck"),
	RateLimiter = require("../../src/shared/RateLimiter"),
	Validate = require("../../src/shared/Validate"),
}

local DATA: { [string]: any } = {
	Lease = require("../../src/server/Data/Lease"),
	MemoryStore = require("../../src/server/Data/MemoryStore"),
	Migrations = require("../../src/server/Data/Migrations"),
	Profile = require("../../src/server/Data/Profile"),
	Steps = require("../../src/server/Data/Steps"),
	Store = require("../../src/server/Data/Store"),
}

local SHOP: { [string]: any } = {
	Ledger = require("../../src/server/Shop/Ledger"),
	Passes = require("../../src/server/Shop/Passes"),
	Receipts = require("../../src/server/Shop/Receipts"),
	Rotation = require("../../src/server/Shop/Rotation"),
	Shop = require("../../src/server/Shop/Shop"),
}

local Handlers = require("../../src/server/Handlers")
local Sessions = require("../../src/server/Sessions")

-- Read once, when this module is first required. fs.readFile yields to Lune's scheduler, which a
-- test running in the runner's own thread must not do.
local SOURCE = fs.readFile("src/server/init.server.luau")

local FakeGame = {}

export type Options = {
	config: any?, -- replaces Config
	failRequire: string?, -- the name of a module whose require throws
	blockShared: boolean?, -- ReplicatedStorage:WaitForChild never returns
	start: number?, -- the clock's starting time
}

local function signal(world: any): any
	local s: any = { fns = {} }
	function s.Connect(self: any, fn: (...any) -> ())
		table.insert(self.fns, fn)
		return {
			Disconnect = function()
				local i = table.find(self.fns, fn)
				if i then
					table.remove(self.fns, i)
				end
			end,
		}
	end
	-- Each handler runs in its own thread, as Roblox does.
	function s.fire(self: any, ...: any)
		local args = table.pack(...)
		for _, fn in table.clone(self.fns) do
			world.sched:spawn(function()
				fn(table.unpack(args, 1, args.n))
			end)
		end
	end
	return s
end

local function strict(name: string, members: { [string]: any }): any
	return setmetatable(members, {
		__index = function(_, key)
			error(`FakeGame: {name}.{tostring(key)} is not modelled`, 2)
		end,
	})
end

-- A stand-in module reference: what `script.Shop.Receipts` or `Shared:WaitForChild("Config")`
-- gives the entry script, and what its `require` turns back into the module.
local function moduleRef(name: string, value: any): any
	return { __moduleName = name, __module = value }
end

function FakeGame.new(options: Options?): any
	local opts: Options = options or {}
	local world: any = {
		records = {},
		players = {},
		warnings = {},
		prints = {},
		synced = {},
		instances = {},
		pads = {},
		passOwned = {},
		passChecks = {},
		fireThrows = false,
		guids = 0,
	}
	world.clock = FakeClock.new(opts.start or 0)
	world.sched = FakeScheduler.new(world.clock)
	world.ds = FakeDataStore.new(world.records)

	local Players: any
	Players = strict("Players", {
		PlayerAdded = signal(world),
		PlayerRemoving = signal(world),
		GetPlayers = function()
			local list = {}
			for _, player in world.players do
				table.insert(list, player)
			end
			return list
		end,
		GetPlayerByUserId = function(_, userId: number)
			return world.players[userId]
		end,
		GetPlayerFromCharacter = function(_, character: any)
			if type(character) == "table" and character.player ~= nil then
				return world.players[character.player.UserId]
			end
			return nil
		end,
	})

	local MarketplaceService = strict("MarketplaceService", {
		ProcessReceipt = false, -- false stands in for "never assigned"; the script sets a function
		PromptGamePassPurchaseFinished = signal(world),
		UserOwnsGamePassAsync = function(_, userId: number, passId: number): boolean
			table.insert(world.passChecks, `{userId}:{passId}`)
			local owned = world.passOwned[`{userId}:{passId}`]
			if owned == "error" then
				error("service unavailable")
			end
			return owned == true
		end,
	})
	world.marketplace = MarketplaceService

	local config = opts.config or SHARED.Config
	local sharedFolder = strict("Tuckshop", {
		WaitForChild = function(_, name: string)
			local value = if name == "Config" then config else SHARED[name]
			assert(value ~= nil, `FakeGame: no shared module {name}`)
			return moduleRef(name, value)
		end,
	})

	local services: { [string]: any } = {
		CollectionService = strict("CollectionService", {
			GetTagged = function()
				return table.clone(world.pads)
			end,
			GetInstanceAddedSignal = function()
				return signal(world)
			end,
		}),
		DataStoreService = strict("DataStoreService", {
			GetDataStore = function()
				return world.ds
			end,
			GetRequestBudgetForRequestType = function()
				return 100
			end,
		}),
		HttpService = strict("HttpService", {
			GenerateGUID = function()
				world.guids += 1
				return `guid-{world.guids}`
			end,
		}),
		MarketplaceService = MarketplaceService,
		Players = Players,
		ReplicatedStorage = strict("ReplicatedStorage", {
			WaitForChild = function(_, name: string)
				assert(name == "Tuckshop", name)
				if opts.blockShared then
					world.sched:wait(math.huge)
				end
				return sharedFolder
			end,
		}),
		RunService = strict("RunService", {
			IsStudio = function()
				return false -- so the script uses the data store it is given, which is the fake
			end,
		}),
		ServerStorage = strict("ServerStorage", {
			GetAttribute = function()
				return nil
			end,
		}),
	}

	local function folder(prefix: string, modules: { [string]: any }): any
		local out = {}
		for name, value in modules do
			out[name] = moduleRef(prefix .. name, value)
		end
		return out
	end

	local env: any = {
		game = strict("game", {
			JobId = "JOB",
			GetService = function(_, name: string)
				local service = services[name]
				assert(service ~= nil, `FakeGame: service {name} is not modelled`)
				return service
			end,
			BindToClose = function(_, fn: () -> ())
				world.onClose = fn
			end,
		}),
		script = {
			Handlers = moduleRef("Handlers", Handlers),
			Sessions = moduleRef("Sessions", Sessions),
			Data = folder("Data.", DATA),
			Shop = folder("Shop.", SHOP),
		},
		require = function(ref: any): any
			assert(type(ref) == "table" and ref.__moduleName ~= nil, "FakeGame: require of a non-module")
			if opts.failRequire == ref.__moduleName then
				error(`{ref.__moduleName} failed to load`)
			end
			return ref.__module
		end,
		Instance = {
			new = function(className: string): any
				local instance: any = { ClassName = className, Name = className, Parent = nil }
				if className == "RemoteEvent" then
					instance.OnServerEvent = signal(world)
					function instance.FireClient(_, player: any, payload: any)
						if world.fireThrows then
							error("FireClient failed")
						end
						table.insert(world.synced, { userId = player.UserId, payload = payload })
					end
				end
				table.insert(world.instances, instance)
				return instance
			end,
		},
		Enum = {
			ProductPurchaseDecision = {
				NotProcessedYet = "NotProcessedYet",
				PurchaseGranted = "PurchaseGranted",
			},
			DataStoreRequestType = { UpdateAsync = "UpdateAsync" },
		},
		task = {
			spawn = function(fn: any, ...: any)
				if type(fn) == "thread" then
					world.sched:spawn(fn)
					return
				end
				local args = table.pack(...)
				world.sched:spawn(function()
					fn(table.unpack(args, 1, args.n))
				end)
			end,
			wait = function(seconds: number?): number
				world.sched:wait(seconds or 0)
				return seconds or 0
			end,
		},
		os = {
			time = function(): number
				return math.floor(world.clock:now())
			end,
			clock = function(): number
				return world.clock:now()
			end,
		},
		warn = function(...: any)
			local parts = {}
			for i = 1, select("#", ...) do
				table.insert(parts, tostring((select(i, ...))))
			end
			table.insert(world.warnings, table.concat(parts, " "))
		end,
		print = function(...: any)
			table.insert(world.prints, table.concat({ ... }, " "))
		end,
	}

	-- Starts the script in its own thread, as Roblox does. `started` is true once it reaches the
	-- end, and `startError` holds anything it threw.
	function world.start(self: any)
		local chunk = luau.load(SOURCE, { debugName = "init.server", environment = env })
		self.sched:spawn(function()
			local ok, err = pcall(chunk)
			self.started = ok
			self.startError = if ok then nil else tostring(err)
		end)
		return self
	end

	-- The ProcessReceipt callback as the script left it, or nil if it never assigned one.
	function world.callback(self: any): any
		local fn = self.marketplace.ProcessReceipt
		return if type(fn) == "function" then fn else nil
	end

	-- Calls ProcessReceipt the way Roblox does, in its own thread. Returns a box whose `result`
	-- is filled in when the callback returns, and whose `error` holds anything it threw.
	function world.receipt(self: any, userId: number, productId: number, purchaseId: string): any
		local box: any = {}
		local fn = self:callback()
		assert(fn ~= nil, "no ProcessReceipt callback")
		self.sched:spawn(function()
			local ok, result =
				pcall(fn, { PlayerId = userId, ProductId = productId, PurchaseId = purchaseId })
			if ok then
				box.result = result
			else
				box.error = tostring(result)
			end
		end)
		return box
	end

	function world.join(self: any, userId: number): any
		local player: any = { UserId = userId, Name = `player{userId}`, Parent = Players, attributes = {} }
		function player.SetAttribute(p: any, name: string, value: any)
			p.attributes[name] = value
		end
		function player.GetAttribute(p: any, name: string): any
			return p.attributes[name]
		end
		function player.Kick(p: any, message: string)
			p.kicked = message
		end
		player.character = { player = player }
		self.players[userId] = player
		Players.PlayerAdded:fire(player)
		return player
	end

	-- PlayerRemoving fires while the player is still in Players; then they are gone.
	function world.leave(self: any, userId: number)
		local player = self.players[userId]
		Players.PlayerRemoving:fire(player)
		self.players[userId] = nil
		player.Parent = nil
	end

	function world.remote(self: any, name: string): any
		for _, instance in self.instances do
			if instance.Name == name and instance.ClassName == "RemoteEvent" then
				return instance
			end
		end
		return nil
	end

	-- A client firing the Request remote.
	function world.request(self: any, userId: number, action: any, arg: any)
		local remote = self:remote("Request")
		assert(remote ~= nil, "no Request remote")
		remote.OnServerEvent:fire(self.players[userId], action, arg)
	end

	-- A part tagged as a coin pad. Must be added before start().
	function world.addPad(self: any): any
		local pad: any = {
			Touched = signal(self),
			IsA = function(_, className: string): boolean
				return className == "BasePart"
			end,
		}
		table.insert(self.pads, pad)
		return pad
	end

	function world.touch(self: any, pad: any, userId: number)
		pad.Touched:fire({ Parent = self.players[userId].character })
	end

	function world.passFinished(self: any, userId: number, passId: number, wasPurchased: boolean)
		self.marketplace.PromptGamePassPurchaseFinished:fire(self.players[userId], passId, wasPurchased)
	end

	return world
end

return FakeGame
