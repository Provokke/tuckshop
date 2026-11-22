--!strict
-- Loads that go wrong after the claim, give up, or are called off.
local FakeClock = require("../fakes/FakeClock")
local StoreServer = require("../fakes/StoreServer")

local server = StoreServer.new

return {
	{
		name = "a record that can't be migrated fails the load and hands the lease back",
		run = function()
			local records: any = { p1 = { schema = 1, data = { gold = 1 }, savedAt = 0 } }
			local store = server(records, FakeClock.new(0), "JOB", { schema = 2, steps = {} })
			local ok, session, outcome = pcall(function()
				return store:load("p1")
			end)
			assert(ok, `load must not throw: {tostring(session)}`)
			assert(session == nil and outcome == "error", outcome)
			assert(records.p1.lease == nil, "the lease was handed back")
			assert(records.p1.data.gold == 1 and records.p1.schema == 1, "the stored data is untouched")
			-- control: with the step in place the same record loads and upgrades
			local fixed = server(records, FakeClock.new(0), "JOB", {
				schema = 2,
				steps = {
					function(data: any)
						data.gold += 1
						return data
					end,
				},
			})
			local again = fixed:load("p1")
			assert(again ~= nil and again.data.gold == 2)
		end,
	},
	{
		name = "a record with no data fails the load and hands the lease back",
		run = function()
			local records: any = { p1 = { schema = 1, savedAt = 0 } }
			local store = server(records, FakeClock.new(0), "JOB")
			local session, outcome = store:load("p1")
			assert(session == nil and outcome == "error", outcome)
			assert(records.p1.lease == nil and records.p1.data == nil)
			-- control
			records.p2 = { schema = 1, data = { gold = 3 }, savedAt = 0 }
			local good = store:load("p2")
			assert(good ~= nil and good.data.gold == 3)
		end,
	},
	{
		name = "a failing decode fails the load and hands the lease back",
		run = function()
			local records: any = { p1 = { schema = 1, data = { gold = 1 }, savedAt = 0 } }
			local store = server(records, FakeClock.new(0), "JOB", {
				decode = function(saved: any)
					assert(saved.wallet ~= nil, "no wallet")
					return saved
				end,
			})
			local session, outcome = store:load("p1")
			assert(session == nil and outcome == "error", outcome)
			assert(records.p1.lease == nil)
			-- control
			records.p1.data.wallet = {}
			local good = store:load("p1")
			assert(good ~= nil)
		end,
	},
	{
		name = "a load that never gets through doesn't wait after its last attempt",
		run = function()
			local store, ds, waits = server({}, FakeClock.new(0), "JOB", { retries = 3 })
			ds:failNext(3, "502 service unavailable")
			local session, outcome = store:load("p1")
			assert(session == nil and outcome == "error", outcome)
			local w = table.concat(waits, ",")
			assert(w == "1,2", `waits were {w}`)
		end,
	},
	{
		name = "a load whose last claim landed but errored hands that lease back",
		run = function()
			local records: any = {}
			local store, ds = server(records, FakeClock.new(0), "JOB", { retries = 1 })
			ds:commitThenFailNext(1, "timed out")
			local session, outcome = store:load("p1")
			assert(session == nil and outcome == "error", outcome)
			assert(records.p1 ~= nil and records.p1.lease == nil, "the landed claim's lease is cleared")
			-- control: the player can load straight away
			local again, outcome2 = store:load("p1")
			assert(again ~= nil and outcome2 == "taken", outcome2)
		end,
	},
	{
		name = "a budget reading that throws fails the call instead of raising",
		run = function()
			local broken = false
			local records: any = {}
			local store = server(records, FakeClock.new(0), "JOB", {
				retries = 1,
				budget = function(_kind: string): number
					if broken then
						error("budget unavailable")
					end
					return 100
				end,
			})
			broken = true
			local ok, session, outcome = pcall(function()
				return store:load("p1")
			end)
			assert(ok, `load must not throw: {tostring(session)}`)
			assert(session == nil and outcome == "error", outcome)
			broken = false
			local live = store:load("p2")
			assert(live ~= nil)
			live.data.gold = 4
			broken = true
			local saveOk, saved = pcall(function()
				return live:save()
			end)
			assert(saveOk and saved == false and live.lost == false, "a failed save, not a lost lease")
			-- control
			broken = false
			assert(live:save() == true and records.p2.data.gold == 4)
		end,
	},
	{
		name = "a load stops retrying once its caller calls it off",
		run = function()
			local records: any = {}
			local clock = FakeClock.new(0)
			local holder = server(records, clock, "A")
			assert(holder:load("p1") ~= nil)
			local store, ds, waits = server(records, clock, "B", { retries = 5 })
			local session, outcome = store:load("p1", function()
				return false -- the player has left
			end)
			assert(session == nil and outcome == "cancelled", outcome)
			assert(ds.calls == 1 and #waits == 0, `calls={ds.calls} waits={#waits}`)
			-- control: a caller that wants it keeps trying until locked
			local _, outcome2 = store:load("p1", function()
				return true
			end)
			assert(outcome2 == "locked" and ds.calls == 6, `{outcome2} {ds.calls}`)
		end,
	},
	{
		name = "a load called off after a claim that landed but errored hands that lease back",
		run = function()
			local records: any = {}
			local store, ds = server(records, FakeClock.new(0), "JOB", { retries = 3 })
			ds:commitThenFailNext(1, "timed out")
			local session, outcome = store:load("p1", function()
				return false -- the player left during the first attempt
			end)
			assert(session == nil and outcome == "cancelled", outcome)
			assert(records.p1 ~= nil and records.p1.lease == nil, "the landed claim's lease is cleared")
			-- control: a call-off after a held attempt writes nothing at all
			local holder = server(records, FakeClock.new(0), "A")
			assert(holder:load("p1") ~= nil)
			local before = records.p1
			local _, outcome2 = store:load("p1", function()
				return false
			end)
			assert(outcome2 == "cancelled" and records.p1 == before)
		end,
	},
}
