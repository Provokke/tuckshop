--!strict
-- The session lifecycle on one server: joins, leaves, quick rejoins, autosave and shutdown.
-- A FakeScheduler stands in for task.spawn and task.wait, and the fake store's hook parks a
-- call mid-flight so a test can act while it is still running.
local FakeClock = require("../fakes/FakeClock")
local FakeScheduler = require("../fakes/FakeScheduler")
local Profile = require("../../src/server/Data/Profile")
local Sessions = require("../../src/server/Sessions")
local StoreServer = require("../fakes/StoreServer")

local LOCKED = "Your data is still open on another server. Rejoin in a minute."
local LOST = "Your data was opened on another server."

local function world(records: any?): any
	local w: any = { records = records or {}, kicks = {}, players = {} }
	w.clock = FakeClock.new(0)
	w.sched = FakeScheduler.new(w.clock)
	local profile = Profile.new({
		newWallet = function()
			return { balances = { Coins = 100, Gems = 0 }, log = {} }
		end,
	})
	w.store, w.ds = StoreServer.new(w.records, w.clock, "JOB", {
		wait = function(seconds: number)
			w.sched:wait(seconds)
		end,
		resume = function(thread: thread)
			w.sched:spawn(thread)
		end,
		defaultData = profile.defaultData,
		encode = profile.encode,
		decode = profile.decode,
	})
	w.sessions = Sessions.new({
		store = w.store,
		keyFor = function(userId: number)
			return "Player_" .. userId
		end,
		present = function(player: any)
			return player.here
		end,
		kick = function(player: any, message: string)
			table.insert(w.kicks, `{player.name}: {message}`)
		end,
		playerOf = function(userId: number)
			return w.players[userId]
		end,
		ready = function() end,
		spawn = function(fn: () -> ())
			w.sched:spawn(fn)
		end,
		wait = function(seconds: number)
			w.sched:wait(seconds)
		end,
		clock = function()
			return w.clock:now()
		end,
		closeSeconds = 25,
		log = function() end,
	})
	return w
end

local function arrive(w: any, userId: number, name: string): any
	local player = { name = name, here = true }
	w.players[userId] = player
	w.sched:spawn(function()
		w.sessions:join(userId, player)
	end)
	return player
end

local function depart(w: any, userId: number)
	local player = w.players[userId]
	player.here = false
	w.players[userId] = nil
	w.sessions:leave(userId)
end

local function parkNextCall(w: any, seconds: number)
	w.ds:hookNext(function()
		w.sched:wait(seconds)
	end)
end

local function oldBag(schema: number): any
	return {
		schema = schema,
		savedAt = 0,
		data = { wallet = { balances = { Coins = 40 }, log = {} }, bought = {}, receipts = {} },
	}
end

return {
	{
		name = "a player who rejoins while their release is in flight waits for it and loads what it wrote",
		run = function()
			local w = world()
			arrive(w, 1, "first")
			local old = w.sessions.live[1]
			assert(old ~= nil)
			old.data.gold = 7
			parkNextCall(w, 5)
			depart(w, 1) -- the release is now parked mid-call
			arrive(w, 1, "second")
			assert(w.sessions.live[1] == nil, "the new join waits")
			assert(w.records.Player_1.lease.owner == old.owner, "the old release hasn't landed yet")
			w.sched:advance(6)
			local new = w.sessions.live[1]
			assert(new ~= nil and new ~= old, "the rejoin has its own session")
			assert(new.data.gold == 7, "holding what the old session wrote")
			assert(w.records.Player_1.lease.owner == new.owner)
			assert(#w.kicks == 0, w.kicks[1])
			-- control: with nothing in flight, a rejoin loads straight away
			depart(w, 1)
			arrive(w, 1, "third")
			assert(w.sessions.live[1] ~= nil and w.sessions.live[1] ~= new)
		end,
	},
	{
		name = "a rejoin during a slow load gets the record, and the departed load is handed back",
		run = function()
			local w = world()
			parkNextCall(w, 5) -- the first load's claim is slow
			local first = arrive(w, 1, "first")
			assert(w.sessions.live[1] == nil)
			first.here = false -- they leave before it finishes
			w.players[1] = nil
			w.sessions:leave(1)
			arrive(w, 1, "second")
			w.sched:advance(6)
			local session = w.sessions.live[1]
			assert(session ~= nil, "the second join has a session")
			assert(w.records.Player_1.lease.owner == session.owner, "and holds the lease")
			session.data.gold = 3
			assert(session:save() == true and w.records.Player_1.data.gold == 3)
			assert(#w.kicks == 0, w.kicks[1])
		end,
	},
	{
		name = "a load for a player who left stops retrying",
		run = function()
			local records: any = {}
			local w = world(records)
			local other = StoreServer.new(records, w.clock, "OTHER")
			assert(other:load("Player_1") ~= nil) -- another server holds the record
			local first = arrive(w, 1, "first")
			assert(w.ds.calls == 1, "first attempt held, now waiting")
			first.here = false
			w.sched:advance(10)
			assert(w.ds.calls == 1, `no more attempts once the player left, calls={w.ds.calls}`)
			assert(#w.kicks == 0)
			-- control: a player who stays is retried and then told
			arrive(w, 1, "second")
			w.sched:advance(10)
			assert(w.ds.calls == 4, `calls={w.ds.calls}`)
			assert(w.kicks[1] == "second: " .. LOCKED, w.kicks[1])
		end,
	},
	{
		name = "close waits for a load still in flight and hands its lease back",
		run = function()
			local w = world()
			parkNextCall(w, 5)
			arrive(w, 1, "first")
			local closedAt: number? = nil
			w.sched:spawn(function()
				w.sessions:close()
				closedAt = w.clock:now()
			end)
			assert(closedAt == nil, "close waits for the load")
			w.sched:advance(10)
			assert(closedAt ~= nil and closedAt >= 5 and closedAt < 6, tostring(closedAt))
			assert(w.records.Player_1.lease == nil, "the late load was handed back")
			assert(w.sessions.live[1] == nil)
			-- control: with nothing in flight close returns straight away
			local w2 = world()
			local done = false
			w2.sched:spawn(function()
				w2.sessions:close()
				done = true
			end)
			assert(done)
		end,
	},
	{
		name = "close releases every session and waits no longer than its timeout",
		run = function()
			local w = world()
			arrive(w, 1, "a")
			arrive(w, 2, "b")
			w.sessions.live[1].data.gold = 1
			w.sessions.live[2].data.gold = 2
			parkNextCall(w, 100) -- one release hangs
			local closedAt: number? = nil
			w.sched:spawn(function()
				w.sessions:close()
				closedAt = w.clock:now()
			end)
			w.sched:advance(30)
			assert(closedAt ~= nil and closedAt >= 25 and closedAt < 25.2, tostring(closedAt))
			local released = 0
			for _, key in { "Player_1", "Player_2" } do
				if w.records[key].lease == nil then
					released += 1
				end
			end
			assert(released == 1, `one release landed, the other hung, got {released}`)
			-- control: without the hang both land and close returns at once
			local w2 = world()
			arrive(w2, 1, "a")
			arrive(w2, 2, "b")
			local done = false
			w2.sched:spawn(function()
				w2.sessions:close()
				done = true
			end)
			assert(done and w2.records.Player_1.lease == nil and w2.records.Player_2.lease == nil)
		end,
	},
	{
		name = "a read-only session can be shown but not changed, and a lost one is kicked",
		run = function()
			local w = world({ Player_1 = oldBag(9) })
			arrive(w, 1, "a")
			arrive(w, 2, "b")
			assert(w.sessions:get(1) ~= nil, "a read-only session can still be shown")
			assert(w.sessions:writable(1) == false and w.sessions:writableSession(1) == nil)
			assert(w.sessions:writable(2) == true, "control: a current record can change")
			assert(w.sessions:writableSession(2) == w.sessions:get(2))
			-- player 2's lease runs out and another server takes the record
			w.sched:advance(181)
			local thief = StoreServer.new(w.records, w.clock, "OTHER")
			assert(thief:load("Player_2") ~= nil)
			w.sessions:saveAll()
			assert(w.kicks[1] == "b: " .. LOST and #w.kicks == 1, w.kicks[1])
			assert(w.sessions:writable(2) == false and w.sessions:get(2) == nil)
			assert(w.sessions:writableSession(2) == nil)
			assert(w.records.Player_2.lease.owner ~= w.sessions.live[2].owner, "nothing was written")
		end,
	},
	{
		name = "a read-only session is never written back, by autosave or on release",
		run = function()
			local w = world({ Player_1 = oldBag(9) })
			arrive(w, 1, "a")
			w.sessions:get(1).data.wallet.balances.Coins = 9999 -- a bug that changes it anyway
			w.sessions:saveAll()
			depart(w, 1)
			assert(w.records.Player_1.data.wallet.balances.Coins == 40, "the newer record is untouched")
			assert(w.records.Player_1.schema == 9 and w.records.Player_1.lease == nil)
			-- control: a current record is written back
			local w2 = world({ Player_1 = oldBag(1) })
			arrive(w2, 1, "a")
			w2.sessions:get(1).data.wallet.balances.Coins = 55
			depart(w2, 1)
			assert(w2.records.Player_1.data.wallet.balances.Coins == 55)
		end,
	},
}
