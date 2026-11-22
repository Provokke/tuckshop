--!strict
local Deep = require("../fakes/Deep")
local Lease = require("../../src/server/Data/Lease")

local function def(): { [string]: any }
	return { gold = 0, wallet = { balances = {}, log = {} }, bought = {}, receipts = {} }
end

local function record(owner: string?, expiresAt: number?): any
	local r: any = { schema = 1, data = { gold = 7 }, savedAt = 10 }
	if owner then
		r.lease = { owner = owner, expiresAt = expiresAt }
	end
	return r
end

return {
	{
		name = "claim on no record gives a new leased record with default data",
		run = function()
			local rec, outcome = Lease.claim(nil, "A", 100, 180, def)
			assert(outcome == "new", outcome)
			assert(rec ~= nil)
			assert(
				rec.lease ~= nil and rec.lease.owner == "A" and rec.lease.expiresAt == 280,
				"lease should be A until 280"
			)
			assert(Deep.equal(rec.data, def()), "data should equal the defaults")
		end,
	},
	{
		name = "claim steals an expired foreign lease",
		run = function()
			local rec, outcome = Lease.claim(record("B", 50), "A", 100, 180, def)
			assert(outcome == "stolen", outcome)
			assert(rec ~= nil and rec.lease ~= nil and rec.lease.owner == "A")
			assert(rec.data.gold == 7, "stolen record keeps its data")
		end,
	},
	{
		name = "claim is held by a live foreign lease, until it expires",
		run = function()
			local rec, outcome = Lease.claim(record("B", 500), "A", 100, 180, def)
			assert(outcome == "held", outcome)
			assert(rec == nil, "a held claim writes nothing")
			local rec2, outcome2 = Lease.claim(record("B", 500), "A", 501, 180, def)
			assert(outcome2 == "stolen", outcome2)
			assert(rec2 ~= nil and rec2.lease ~= nil and rec2.lease.owner == "A")
		end,
	},
	{
		name = "claim on our own live lease is taken (a retry of a claim that landed)",
		run = function()
			local rec, outcome = Lease.claim(record("A", 500), "A", 100, 180, def)
			assert(outcome == "taken", outcome)
			assert(
				rec ~= nil and rec.lease ~= nil and rec.lease.expiresAt == 280,
				"lease is renewed from now"
			)
		end,
	},
	{
		name = "claim does not mutate the stored record",
		run = function()
			local stored = record("B", 50)
			local snapshot = Deep.copy(stored)
			local rec = Lease.claim(stored, "A", 100, 180, def)
			assert(rec ~= nil)
			rec.data.gold = 999
			assert(Deep.equal(stored, snapshot), "stored changed")
		end,
	},
	{
		name = "refresh with our lease writes data and extends the lease",
		run = function()
			local rec, outcome = Lease.refresh(record("A", 150), "A", 100, 180, { gold = 42 }, true)
			assert(outcome == "saved", outcome)
			assert(rec ~= nil and rec.data.gold == 42 and rec.lease ~= nil and rec.lease.expiresAt == 280)
		end,
	},
	{
		name = "refresh with a foreign lease is lost, with our lease it saves",
		run = function()
			local rec, outcome = Lease.refresh(record("B", 500), "A", 100, 180, { gold = 42 }, true)
			assert(outcome == "lost", outcome)
			assert(rec == nil, "a lost refresh writes nothing")
			local rec2, outcome2 = Lease.refresh(record("A", 500), "A", 100, 180, { gold = 42 }, true)
			assert(outcome2 == "saved", outcome2)
			assert(rec2 ~= nil)
		end,
	},
	{
		name = "refresh without writeData keeps stored data but extends the lease",
		run = function()
			local rec, outcome = Lease.refresh(record("A", 150), "A", 100, 180, { gold = 42 }, false)
			assert(outcome == "saved", outcome)
			assert(rec ~= nil and rec.data.gold == 7, "stored data kept")
			assert(rec.lease ~= nil and rec.lease.expiresAt == 280)
		end,
	},
	{
		name = "release clears the lease and writes data, so another server can take it",
		run = function()
			local rec, outcome = Lease.release(record("A", 500), "A", 100, { gold = 42 }, true)
			assert(outcome == "released", outcome)
			assert(rec ~= nil and rec.lease == nil and rec.data.gold == 42)
			local _, claimOutcome = Lease.claim(rec, "B", 101, 180, def)
			assert(claimOutcome == "taken", claimOutcome)
		end,
	},
	{
		name = "release with a foreign lease is lost, with our lease it releases",
		run = function()
			local rec, outcome = Lease.release(record("B", 500), "A", 100, { gold = 42 }, true)
			assert(outcome == "lost", outcome)
			assert(rec == nil)
			local rec2, outcome2 = Lease.release(record("A", 500), "A", 100, { gold = 42 }, true)
			assert(outcome2 == "released", outcome2)
			assert(rec2 ~= nil)
		end,
	},
	{
		name = "release by an owner whose release already landed writes nothing and says released",
		run = function()
			local landed: any = { schema = 1, data = { gold = 7 }, savedAt = 10, releasedBy = "A" }
			local rec, outcome = Lease.release(landed, "A", 100, { gold = 1 }, true)
			assert(outcome == "released" and rec == nil, outcome)
			-- and still after another session has claimed it since
			local claimed = Lease.claim(landed, "B", 101, 180, def)
			assert(claimed ~= nil and claimed.releasedBy == "A", "claim keeps releasedBy")
			local rec2, outcome2 = Lease.release(claimed, "A", 102, { gold = 1 }, true)
			assert(outcome2 == "released" and rec2 == nil, outcome2)
			-- control: someone else's release is not ours
			local _, outcome3 = Lease.release(landed, "C", 100, { gold = 1 }, true)
			assert(outcome3 == "lost", outcome3)
		end,
	},
	{
		name = "release stamps the owner it was released by",
		run = function()
			local rec = Lease.release(record("A", 500), "A", 100, { gold = 42 }, true)
			assert(rec ~= nil and rec.releasedBy == "A")
		end,
	},
	{
		name = "refresh and release on a record with no lease are lost and write nothing",
		run = function()
			local free = record(nil, nil) -- released by someone else
			local rec, outcome = Lease.refresh(free, "A", 100, 180, { gold = 1 }, true)
			assert(outcome == "lost" and rec == nil, outcome)
			local rec2, outcome2 = Lease.release(free, "A", 100, { gold = 1 }, true)
			assert(outcome2 == "lost" and rec2 == nil, outcome2)
			-- control: the same calls on our own lease go through
			local _, ok1 = Lease.refresh(record("A", 500), "A", 100, 180, { gold = 1 }, true)
			local _, ok2 = Lease.release(record("A", 500), "A", 100, { gold = 1 }, true)
			assert(ok1 == "saved" and ok2 == "released")
		end,
	},
}
