--!strict
local FakeClock = require("../fakes/FakeClock")
local FakeScheduler = require("../fakes/FakeScheduler")
local Passes = require("../../src/server/Shop/Passes")

local function rig(): any
	local r: any = { owned = {}, calls = {}, failing = false, slow = false }
	r.clock = FakeClock.new(0)
	r.sched = FakeScheduler.new(r.clock)
	r.passes = Passes.new({
		passes = {
			[11] = { perk = "DoubleCoins" },
			[12] = { perk = "Lantern" },
			[0] = { perk = "Placeholder" },
		},
		owns = function(userId: number, passId: number): boolean
			table.insert(r.calls, `{userId}:{passId}`)
			if r.slow then
				r.sched:wait(5) -- the web call takes a while
			end
			if r.failing then
				error("service unavailable")
			end
			return r.owned[`{userId}:{passId}`] == true
		end,
		wait = function(seconds: number)
			r.sched:wait(seconds)
		end,
	})
	return r
end

local function refreshLater(r: any, userId: number): any
	local box: any = {}
	r.sched:spawn(function()
		r.passes:refresh(userId)
		box.done = true
	end)
	return box
end

local function callsFor(r: any, userId: number): number
	local n = 0
	for _, call in r.calls do
		if string.sub(call, 1, #tostring(userId) + 1) == `{userId}:` then
			n += 1
		end
	end
	return n
end

return {
	{
		name = "a pass the player owns gives its perk, and only that perk",
		run = function()
			local r = rig()
			r.owned["5:11"] = true
			assert(r.passes:has(5, "DoubleCoins") == false, "nothing is known before the first refresh")
			r.passes:refresh(5)
			assert(r.passes:has(5, "DoubleCoins") == true)
			assert(r.passes:has(5, "Lantern") == false, "a pass they don't own gives nothing")
			assert(r.passes:has(6, "DoubleCoins") == false, "and neither does someone else's")
		end,
	},
	{
		name = "a player who owns nothing has no perks, and the placeholder id is never asked about",
		run = function()
			local r = rig()
			r.passes:refresh(5)
			assert(r.passes:has(5, "DoubleCoins") == false and r.passes:has(5, "Lantern") == false)
			assert(table.find(r.calls, "5:0") == nil, "id 0 is a placeholder, not a real pass")
			assert(#r.calls == 2, `{#r.calls} calls`)
			assert(r.passes:has(5, "Placeholder") == false)
		end,
	},
	{
		name = "a failed check counts as not owned and is tried again 30 s later, without another refresh",
		run = function()
			local r = rig()
			r.owned["5:11"] = true
			r.failing = true
			local box = refreshLater(r, 5)
			assert(r.passes:has(5, "DoubleCoins") == false, "a failed check is not owned")
			assert(#r.calls == 2 and box.done == nil, "both checks failed; the retry is waiting")
			r.failing = false
			r.sched:advance(29)
			assert(#r.calls == 2 and r.passes:has(5, "DoubleCoins") == false, "not before 30 s")
			r.sched:advance(1)
			assert(r.passes:has(5, "DoubleCoins") == true, "owned once the check works")
			assert(#r.calls == 4 and box.done == true, "both retried once, then it stops")
			r.sched:advance(600)
			assert(#r.calls == 4, "nothing more to check")
			-- control: a check that works the first time isn't retried
			local r2 = rig()
			r2.owned["5:11"] = true
			local box2 = refreshLater(r2, 5)
			assert(box2.done == true and #r2.calls == 2 and r2.passes:has(5, "DoubleCoins") == true)
		end,
	},
	{
		name = "checks that keep failing stop after six retries, and sooner when the player leaves",
		run = function()
			local r = rig()
			r.failing = true
			local box = refreshLater(r, 5)
			r.sched:advance(1000)
			assert(
				box.done == true and callsFor(r, 5) == 14,
				`{callsFor(r, 5)} calls: the first try and six more`
			)
			assert(r.passes:has(5, "DoubleCoins") == false)
			-- the player leaves after the first retry: no more checks
			local left = refreshLater(r, 6)
			r.sched:advance(30)
			assert(callsFor(r, 6) == 4)
			r.passes:forget(6)
			r.sched:advance(1000)
			assert(callsFor(r, 6) == 4 and left.done == true, `{callsFor(r, 6)} calls after leaving`)
		end,
	},
	{
		name = "a check still running when the player leaves doesn't write them back into the cache",
		run = function()
			local r = rig()
			r.owned["5:11"] = true
			r.slow = true
			refreshLater(r, 5)
			r.passes:forget(5) -- PlayerRemoving, while the first check is out
			r.sched:advance(20)
			assert(r.passes.owned[5] == nil, "nothing is kept for a player who has gone")
			assert(r.passes:has(5, "DoubleCoins") == false)
			-- control: the same refresh for a player who stays is kept
			local stays = refreshLater(r, 6)
			r.owned["6:11"] = true
			r.sched:advance(20)
			assert(stays.done == true and r.passes.owned[6] ~= nil and r.passes:has(6, "DoubleCoins") == true)
		end,
	},
	{
		name = "a completed purchase counts straight away, and forgetting a player clears it",
		run = function()
			local r = rig()
			r.passes:refresh(5)
			assert(r.passes:has(5, "Lantern") == false)
			r.passes:bought(5, 12)
			assert(r.passes:has(5, "Lantern") == true, "no need to wait for a refresh")
			assert(r.passes:has(5, "DoubleCoins") == false)
			r.passes:bought(5, 999) -- a pass that isn't configured changes nothing
			assert(r.passes:has(5, "DoubleCoins") == false)
			r.passes:forget(5)
			assert(r.passes:has(5, "Lantern") == false)
		end,
	},
	{
		name = "a finished purchase the server says isn't owned is taken back, and one it confirms is kept",
		run = function()
			local r = rig()
			r.passes:bought(5, 12) -- the event said purchased
			assert(r.passes:has(5, "Lantern") == true, "counted straight away")
			r.passes:confirm(5, 12)
			assert(table.find(r.calls, "5:12") ~= nil, "the server was asked")
			assert(r.passes:has(5, "Lantern") == false, "not owned, so taken back")
			-- control: a purchase the server confirms is kept
			r.owned["5:11"] = true
			r.passes:bought(5, 11)
			r.passes:confirm(5, 11)
			assert(r.passes:has(5, "DoubleCoins") == true)
			-- and a check that fails keeps the purchase rather than taking it away
			r.passes:bought(5, 12)
			r.failing = true
			r.passes:confirm(5, 12)
			assert(r.passes:has(5, "Lantern") == true)
		end,
	},
}
