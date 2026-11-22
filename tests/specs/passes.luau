--!strict
local Passes = require("../../src/server/Shop/Passes")

local function rig(): any
	local r: any = { owned = {}, calls = {}, failing = false }
	r.passes = Passes.new({
		passes = {
			[11] = { perk = "DoubleCoins" },
			[12] = { perk = "Lantern" },
			[0] = { perk = "Placeholder" },
		},
		owns = function(userId: number, passId: number): boolean
			table.insert(r.calls, `{userId}:{passId}`)
			if r.failing then
				error("service unavailable")
			end
			return r.owned[`{userId}:{passId}`] == true
		end,
	})
	return r
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
		name = "a failed check counts as not owned, and the next refresh retries it",
		run = function()
			local r = rig()
			r.owned["5:11"] = true
			r.failing = true
			r.passes:refresh(5)
			assert(r.passes:has(5, "DoubleCoins") == false, "a failed check is not owned")
			r.failing = false
			r.passes:refresh(5)
			assert(r.passes:has(5, "DoubleCoins") == true, "owned once the check works")
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
}
