--!strict
-- The money path. Every test checks what ended up granted and stored, not just the answer.
local FakeClock = require("../fakes/FakeClock")
local FakeScheduler = require("../fakes/FakeScheduler")
local Profile = require("../../src/server/Data/Profile")
local Receipts = require("../../src/server/Shop/Receipts")
local StoreServer = require("../fakes/StoreServer")

local GRANTED = "PurchaseGranted"
local WAIT = "NotProcessedYet"

local function newWallet(): any
	return { balances = { Coins = 100, Gems = 0 }, log = {} }
end

-- A stand-in session: data, a save that can be told to fail, and a count of saves.
local function fakeSession(): any
	local s: any = {
		data = { wallet = newWallet(), bought = {}, receipts = {} },
		saves = 0,
		saveWorks = true,
		lost = false,
		readOnly = false,
	}
	function s.save(self: any): boolean
		self.saves += 1
		return self.saveWorks
	end
	return s
end

-- One receipts handler over one session, with a grant that credits 100 Gems and counts itself.
local function rig(memory: number?): any
	local r: any = { session = fakeSession(), grants = 0, logs = {}, now = 0 }
	r.receipts = Receipts.new({
		getSession = function(userId: number)
			if userId == 1 then
				return r.session
			end
			return nil
		end,
		products = {
			[100] = function(session: any): boolean
				r.grants += 1
				session.data.wallet.balances.Gems += 100
				return true
			end,
			[200] = function(): boolean
				r.grants += 1
				if r.grantThrows then
					error("grant exploded")
				end
				return r.grantWorks ~= false
			end,
		},
		memory = memory or 200,
		clock = function()
			return r.now
		end,
		log = function(message: string)
			table.insert(r.logs, message)
		end,
	})
	return r
end

local function receipt(purchaseId: string, productId: number?, playerId: number?): any
	return { PlayerId = playerId or 1, ProductId = productId or 100, PurchaseId = purchaseId }
end

-- Two servers over one shared store, each with its own session handler.
local function twoServers(): any
	local w: any = { records = {}, grants = 0 }
	local profile = Profile.new({ newWallet = newWallet })
	local clock = FakeClock.new(0)
	w.clock = clock
	local function server(jobId: string): any
		local store, ds = StoreServer.new(w.records, clock, jobId, {
			defaultData = profile.defaultData,
			encode = profile.encode,
			decode = profile.decode,
		})
		local s: any = { store = store, ds = ds }
		s.receipts = Receipts.new({
			getSession = function()
				return s.session
			end,
			products = {
				[100] = function(session: any): boolean
					w.grants += 1
					session.data.wallet.balances.Gems += 100
					return true
				end,
			},
			memory = 200,
			clock = function()
				return clock:now()
			end,
			log = function() end,
		})
		return s
	end
	w.one = server("JOB1")
	w.two = server("JOB2")
	return w
end

return {
	{
		name = "a first receipt runs the grant once, saves once and is granted",
		run = function()
			local r = rig()
			r.now = 50
			assert(r.receipts:process(receipt("p-1")) == GRANTED)
			assert(r.grants == 1 and r.session.data.wallet.balances.Gems == 100, "granted once")
			assert(r.session.saves == 1, `saved {r.session.saves} times`)
			assert(r.session.data.receipts["p-1"] == 50, "and recorded with the time")
		end,
	},
	{
		name = "the same PurchaseId again is granted without granting again",
		run = function()
			local r = rig()
			assert(r.receipts:process(receipt("p-1")) == GRANTED)
			assert(r.receipts:process(receipt("p-1")) == GRANTED)
			assert(r.grants == 1 and r.session.data.wallet.balances.Gems == 100, "still one grant")
			assert(r.session.saves == 2, "a repeat only saves again")
			-- control: a new PurchaseId does grant a second time
			assert(r.receipts:process(receipt("p-2")) == GRANTED)
			assert(r.grants == 2 and r.session.data.wallet.balances.Gems == 200)
		end,
	},
	{
		name = "a save that fails is retried without granting again",
		run = function()
			local r = rig()
			r.session.saveWorks = false
			assert(r.receipts:process(receipt("p-1")) == WAIT)
			assert(r.grants == 1, "the grant ran")
			assert(r.session.data.receipts["p-1"] ~= nil, "and is recorded, so a retry can't grant again")
			r.session.saveWorks = true
			assert(r.receipts:process(receipt("p-1")) == GRANTED)
			assert(r.grants == 1 and r.session.data.wallet.balances.Gems == 100, "still one grant")
			assert(r.session.saves == 2)
		end,
	},
	{
		name = "a save that throws is not a grant",
		run = function()
			local r = rig()
			r.session.save = function()
				error("datastore down")
			end
			assert(r.receipts:process(receipt("p-1")) == WAIT)
			r.session.save = function()
				return true
			end
			assert(r.receipts:process(receipt("p-1")) == GRANTED and r.grants == 1)
		end,
	},
	{
		name = "no live session means not processed, and nothing is granted",
		run = function()
			local r = rig()
			assert(r.receipts:process(receipt("p-1", 100, 99)) == WAIT)
			assert(r.grants == 0 and r.session.saves == 0 and next(r.session.data.receipts) == nil)
			-- control: for a player who is loaded, the same receipt is granted
			assert(r.receipts:process(receipt("p-1", 100, 1)) == GRANTED and r.grants == 1)
		end,
	},
	{
		name = "a session that is read-only or has lost its lease is treated as no session",
		run = function()
			local r = rig()
			r.session.readOnly = true
			assert(r.receipts:process(receipt("p-1")) == WAIT)
			r.session.readOnly = false
			r.session.lost = true
			assert(r.receipts:process(receipt("p-1")) == WAIT)
			assert(r.grants == 0 and r.session.saves == 0, "nothing granted, nothing saved")
			assert(next(r.session.data.receipts) == nil and r.session.data.wallet.balances.Gems == 0)
			-- control
			r.session.lost = false
			assert(r.receipts:process(receipt("p-1")) == GRANTED and r.grants == 1)
		end,
	},
	{
		name = "a real session loaded read-only can't be credited by a receipt",
		run = function()
			local w = twoServers()
			w.records.p1 = {
				schema = 9,
				savedAt = 0,
				data = { wallet = { balances = { Gems = 7 }, log = {} }, bought = {}, receipts = {} },
			}
			w.one.session = w.one.store:load("p1")
			assert(w.one.session ~= nil and w.one.session.readOnly == true)
			assert(w.one.receipts:process(receipt("p-1")) == WAIT)
			assert(w.grants == 0 and w.one.session.data.wallet.balances.Gems == 7)
			assert(w.one.session:release() == true)
			assert(w.records.p1.data.wallet.balances.Gems == 7 and w.records.p1.schema == 9)
			-- control: a current record is credited and saved
			w.two.session = w.two.store:load("p2")
			assert(w.two.receipts:process(receipt("p-1")) == GRANTED)
			assert(w.records.p2.data.wallet.balances.Gems == 100 and w.records.p2.data.receipts["p-1"] == 0)
		end,
	},
	{
		name = "an unknown product is not processed, and nothing is granted",
		run = function()
			local r = rig()
			assert(r.receipts:process(receipt("p-1", 555)) == WAIT)
			assert(r.grants == 0 and r.session.saves == 0 and next(r.session.data.receipts) == nil)
			assert(#r.logs == 1 and string.find(r.logs[1], "555", 1, true) ~= nil, "and it is logged")
			-- control: a known product is granted
			assert(r.receipts:process(receipt("p-1", 100)) == GRANTED and r.grants == 1)
		end,
	},
	{
		name = "a grant that throws is not processed and records nothing, and a retry grants once",
		run = function()
			local r = rig()
			r.grantThrows = true
			assert(r.receipts:process(receipt("p-1", 200)) == WAIT)
			assert(next(r.session.data.receipts) == nil, "nothing recorded")
			assert(r.session.saves == 0)
			r.grantThrows = false
			assert(r.receipts:process(receipt("p-1", 200)) == GRANTED)
			assert(r.grants == 2, "one failed try and one good one")
			assert(r.session.data.receipts["p-1"] ~= nil and r.session.saves == 1)
			-- and a grant that returns false is the same
			r.grantWorks = false
			assert(r.receipts:process(receipt("p-2", 200)) == WAIT)
			assert(r.session.data.receipts["p-2"] == nil)
		end,
	},
	{
		name = "with a memory of 3, only the 3 newest ids remain after 5 receipts",
		run = function()
			local r = rig(3)
			for i = 1, 5 do
				r.now = i * 10
				assert(r.receipts:process(receipt("p-" .. i)) == GRANTED)
			end
			local kept = {}
			for id in r.session.data.receipts do
				table.insert(kept, id)
			end
			table.sort(kept)
			assert(table.concat(kept, ",") == "p-3,p-4,p-5", table.concat(kept, ","))
			assert(r.grants == 5)
			-- control: a memory of 5 forgets nothing
			local r2 = rig(5)
			for i = 1, 5 do
				r2.now = i * 10
				r2.receipts:process(receipt("p-" .. i))
			end
			local n = 0
			for _ in r2.session.data.receipts do
				n += 1
			end
			assert(n == 5)
		end,
	},
	{
		name = "receipts that land in the same second still trim to the memory and keep the newest",
		run = function()
			local r = rig(3)
			for i = 1, 6 do
				assert(r.receipts:process(receipt("p-" .. i)) == GRANTED) -- the clock never moves
				local n = 0
				for _ in r.session.data.receipts do
					n += 1
				end
				assert(n == math.min(i, 3), `{n} after {i}`)
				assert(r.session.data.receipts["p-" .. i] ~= nil, "the one just granted is always kept")
			end
		end,
	},
	{
		name = "a retry on another server after a failed save and a release is granted without granting again",
		run = function()
			local w = twoServers()
			w.one.session = w.one.store:load("p1")
			assert(w.one.session ~= nil)
			-- server 1 grants, but the save fails
			w.one.ds:failNext(1, "datastore down")
			assert(w.one.receipts:process(receipt("pur-1")) == WAIT)
			assert(w.grants == 1)
			assert(w.records.p1.data.receipts["pur-1"] == nil, "nothing reached the store yet")
			-- the player leaves: the release writes the data, receipt included
			assert(w.one.session:release() == true)
			assert(
				w.records.p1.data.receipts["pur-1"] ~= nil and w.records.p1.data.wallet.balances.Gems == 100
			)
			-- Roblox retries on server 2
			w.two.session = w.two.store:load("p1")
			assert(w.two.session ~= nil)
			assert(w.two.receipts:process(receipt("pur-1")) == GRANTED)
			assert(w.grants == 1, "still one grant in total")
			assert(w.records.p1.data.wallet.balances.Gems == 100, "stored once")
			-- control: a new purchase on server 2 does grant
			assert(w.two.receipts:process(receipt("pur-2")) == GRANTED)
			assert(w.grants == 2 and w.records.p1.data.wallet.balances.Gems == 200)
		end,
	},
	{
		name = "a retry on another server before the first server saved grants again, and only the saved copy counts",
		run = function()
			-- Server 1 grants in memory but crashes before anything reaches the store. The player's
			-- stored data has no grant, so server 2 grants it, once. This is why a grant counts
			-- only when its save landed.
			local w = twoServers()
			w.one.session = w.one.store:load("p1")
			assert(w.one.session ~= nil)
			w.one.ds:failNext(1, "datastore down")
			assert(w.one.receipts:process(receipt("pur-1")) == WAIT)
			w.clock:advance(181) -- server 1 is gone; its lease runs out
			w.two.session = w.two.store:load("p1")
			assert(w.two.session ~= nil)
			assert(w.two.receipts:process(receipt("pur-1")) == GRANTED)
			assert(w.records.p1.data.wallet.balances.Gems == 100, "the stored copy holds one grant")
			assert(w.records.p1.data.receipts["pur-1"] ~= nil)
			-- server 1's old session can no longer write over it
			assert(w.one.session:save() == false)
			assert(w.records.p1.data.wallet.balances.Gems == 100)
		end,
	},
	{
		name = "two calls for one new PurchaseId that interleave across a slow save grant exactly once",
		run = function()
			local clock = FakeClock.new(0)
			local sched = FakeScheduler.new(clock)
			local records: any = {}
			local profile = Profile.new({ newWallet = newWallet })
			local store, ds = StoreServer.new(records, clock, "JOB", {
				wait = function(seconds: number)
					sched:wait(seconds)
				end,
				resume = function(thread: thread)
					sched:spawn(thread)
				end,
				defaultData = profile.defaultData,
				encode = profile.encode,
				decode = profile.decode,
			})
			local session = store:load("p1")
			assert(session ~= nil)
			local grants = 0
			local receipts = Receipts.new({
				getSession = function()
					return session
				end,
				products = {
					[100] = function(s: any): boolean
						grants += 1
						s.data.wallet.balances.Gems += 100
						return true
					end,
				},
				memory = 200,
				clock = function()
					return clock:now()
				end,
				log = function() end,
			})
			ds:hookNext(function()
				sched:wait(5) -- the first save is parked mid-call
			end)
			local results: { string } = {}
			sched:spawn(function()
				table.insert(results, receipts:process(receipt("pur-1")))
			end)
			assert(#results == 0, "the first call is parked inside its save")
			assert(
				grants == 1 and session.data.receipts["pur-1"] ~= nil,
				"granted and recorded before the yield"
			)
			sched:spawn(function()
				table.insert(results, receipts:process(receipt("pur-1"))) -- Roblox asks again meanwhile
			end)
			assert(#results == 0, "the second call queues behind the first save")
			sched:advance(6)
			assert(
				#results == 2 and results[1] == GRANTED and results[2] == GRANTED,
				table.concat(results, ",")
			)
			assert(grants == 1, `granted {grants} times`)
			assert(records.p1.data.wallet.balances.Gems == 100, "stored once")
			assert(records.p1.data.receipts["pur-1"] ~= nil)
			-- control: a different id interleaved the same way grants separately
			ds:hookNext(function()
				sched:wait(5)
			end)
			sched:spawn(function()
				receipts:process(receipt("pur-2"))
			end)
			sched:spawn(function()
				receipts:process(receipt("pur-3"))
			end)
			sched:advance(6)
			assert(grants == 3 and records.p1.data.wallet.balances.Gems == 300)
		end,
	},
	{
		name = "a grant that yields can't be started twice for the same PurchaseId",
		run = function()
			local clock = FakeClock.new(0)
			local sched = FakeScheduler.new(clock)
			local session = fakeSession()
			local grants = 0
			local receipts = Receipts.new({
				getSession = function()
					return session
				end,
				products = {
					[100] = function(s: any): boolean
						grants += 1
						sched:wait(5) -- a slow grant
						s.data.wallet.balances.Gems += 100
						return true
					end,
				},
				memory = 200,
				clock = function()
					return clock:now()
				end,
				log = function() end,
			})
			local results: { string } = {}
			sched:spawn(function()
				table.insert(results, receipts:process(receipt("pur-1")))
			end)
			sched:spawn(function()
				table.insert(results, receipts:process(receipt("pur-1")))
			end)
			assert(#results == 1 and results[1] == WAIT, "the second call is told to come back")
			sched:advance(6)
			assert(#results == 2 and results[2] == GRANTED)
			assert(grants == 1 and session.data.wallet.balances.Gems == 100)
			-- the retry that Roblox sends later only saves
			assert(receipts:process(receipt("pur-1")) == GRANTED and grants == 1)
		end,
	},
}
