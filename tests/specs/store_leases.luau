--!strict
-- Lease ownership across sessions, retries and releases.
local FakeClock = require("../fakes/FakeClock")
local StoreServer = require("../fakes/StoreServer")

local server = StoreServer.new

return {
	{
		name = "two loads of one key on one server don't share the lease",
		run = function()
			local records = {}
			local store = server(records, FakeClock.new(0), "JOB")
			local first = store:load("p1")
			assert(first ~= nil)
			local second, outcome = store:load("p1")
			assert(second == nil and outcome == "locked", `same-server reload must be locked, got {outcome}`)
			assert(records.p1.lease.owner == first.owner, "the first session still holds the lease")
			-- control: once the first session has released, the same server loads it again
			assert(first:release() == true)
			local third, outcome3 = store:load("p1")
			assert(third ~= nil and outcome3 == "taken", outcome3)
			assert(third.owner ~= first.owner, "a new session gets a new owner")
			assert(records.p1.lease.owner == third.owner)
			third.data.gold = 9
			assert(third:save() == true and records.p1.data.gold == 9)
		end,
	},
	{
		name = "a session's lease owner is the job id plus a nonce from the load",
		run = function()
			local records = {}
			local store = server(records, FakeClock.new(0), "JOB", {
				nonce = function()
					return "fixed-guid"
				end,
			})
			local session = store:load("p1")
			assert(session ~= nil and session.owner == "JOB:fixed-guid", session and session.owner)
			assert(records.p1.lease.owner == "JOB:fixed-guid")
		end,
	},
	{
		name = "a claim that landed but errored is retried as this session's own lease",
		run = function()
			local records = {}
			local store, ds = server(records, FakeClock.new(0), "JOB")
			ds:commitThenFailNext(1, "timed out")
			local session, outcome = store:load("p1")
			assert(session ~= nil and outcome == "taken", `expected taken on the retry, got {outcome}`)
			assert(ds.calls == 2)
			assert(records.p1.lease.owner == session.owner)
			-- control: a different session on the same server is still locked out
			local other, otherOutcome = store:load("p1")
			assert(other == nil and otherOutcome == "locked", otherOutcome)
		end,
	},
	{
		name = "a release keeps retrying through an outage longer than three attempts",
		run = function()
			local records = {}
			local store, ds, waits = server(records, FakeClock.new(0), "JOB")
			local session = store:load("p1")
			assert(session ~= nil)
			session.data.gold = 8
			ds:failNext(5, "503 service unavailable")
			assert(session:release() == true, "the sixth attempt lands")
			assert(ds.calls == 7, `load plus six release attempts, got {ds.calls}`)
			local w = table.concat(waits, ",")
			assert(w == "1,2,4,8,16", `waits were {w}`)
			assert(records.p1.lease == nil and records.p1.data.gold == 8, "data written, lease handed back")
		end,
	},
	{
		name = "release backoff is capped at 30 s and gives up after the lease length",
		run = function()
			local records = {}
			local store, ds, waits = server(records, FakeClock.new(0), "JOB")
			local session = store:load("p1")
			assert(session ~= nil)
			session.data.gold = 8
			ds:failNext(100, "503 service unavailable")
			assert(session:release() == false)
			local w = table.concat(waits, ",")
			assert(w == "1,2,4,8,16,30,30,30,30", `waits were {w}`)
			assert(session.released == false and session.lost == false)
			assert(records.p1.lease.owner == session.owner, "nothing was written")
			-- control: once the outage is over, releasing again lands
			ds:failNext(0, "")
			assert(session:release() == true)
			assert(records.p1.lease == nil and records.p1.data.gold == 8)
		end,
	},
	{
		name = "a release with a wait limit gives up within it",
		run = function()
			local records = {}
			local store, ds, waits = server(records, FakeClock.new(0), "JOB")
			local session = store:load("p1")
			assert(session ~= nil)
			ds:failNext(100, "503 service unavailable")
			assert(session:release(3) == false)
			local w = table.concat(waits, ",")
			assert(w == "1,2", `waits were {w}`)
			assert(ds.calls == 4, "load plus three attempts")
		end,
	},
	{
		name = "a release that landed but then errored is reported as released, not lost",
		run = function()
			local records = {}
			local store, ds, _waits, logs = server(records, FakeClock.new(0), "JOB")
			local session = store:load("p1")
			assert(session ~= nil)
			session.data.gold = 6
			ds:commitThenFailNext(1, "timed out")
			assert(session:release() == true, "the retry sees our own release")
			assert(session.released == true and session.lost == false)
			assert(records.p1.lease == nil and records.p1.data.gold == 6)
			assert(records.p1.releasedBy == session.owner)
			for _, line in logs do
				assert(not string.find(line, "lease lost", 1, true), line)
			end
		end,
	},
	{
		name = "a release after another session took the lease is lost and writes nothing",
		run = function()
			local records = {}
			local clock = FakeClock.new(0)
			local storeA = server(records, clock, "A")
			local storeB = server(records, clock, "B")
			local a = storeA:load("p1")
			assert(a ~= nil)
			clock:advance(181)
			local b = storeB:load("p1")
			assert(b ~= nil)
			b.data.gold = 50
			assert(b:save() == true)
			a.data.gold = 999
			assert(a:release() == false and a.lost == true)
			assert(records.p1.data.gold == 50 and records.p1.lease.owner == b.owner)
			-- control: B's own release lands
			assert(b:release() == true and records.p1.lease == nil)
		end,
	},
}
