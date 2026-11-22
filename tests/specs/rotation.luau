--!strict
local Rotation = require("../../src/server/Shop/Rotation")

-- A copy of the demo catalogue's shape, written out so the expected listings below don't move
-- when someone edits Config.
local catalogue = {
	sword_skin = { pool = "skins" },
	shield_skin = { pool = "skins" },
	cape_skin = { pool = "skins" },
	hat_skin = { pool = "skins" },
	boots_skin = { pool = "skins" },
	speed_tonic = { pool = "boosts" },
	lucky_charm = { pool = "boosts" },
	sturdy_shield = { pool = "boosts" },
	night_lantern = { pool = "boosts" },
	tuck_basket = { always = true },
}
local config = { WindowSeconds = 3600, Seed = 7351, Pools = { skins = 3, boosts = 2 } }

local function join(list: { string }): string
	return table.concat(list, ",")
end

local function count(list: { string }, pool: string): number
	local n = 0
	for _, id in list do
		if (catalogue :: any)[id].pool == pool then
			n += 1
		end
	end
	return n
end

return {
	{
		name = "the same window gives the same listing on two calls, whatever the second within it",
		run = function()
			local a = Rotation.listing(catalogue, config, 100)
			local b = Rotation.listing(catalogue, config, 100)
			local c = Rotation.listing(catalogue, config, 3599)
			assert(join(a) == join(b) and join(a) == join(c))
			-- control: the next window is a different shop
			local d = Rotation.listing(catalogue, config, 3600)
			assert(join(d) ~= join(a))
		end,
	},
	{
		name = "consecutive windows list the expected items",
		run = function()
			-- Computed once with an independent xorshift32 and written in.
			local w0 = Rotation.listing(catalogue, config, 0)
			assert(
				join(w0) == "boots_skin,cape_skin,lucky_charm,night_lantern,shield_skin,tuck_basket",
				join(w0)
			)
			local w1 = Rotation.listing(catalogue, config, 3600)
			assert(
				join(w1) == "boots_skin,cape_skin,night_lantern,speed_tonic,sword_skin,tuck_basket",
				join(w1)
			)
			local w2 = Rotation.listing(catalogue, config, 7200)
			assert(
				join(w2) == "boots_skin,cape_skin,hat_skin,lucky_charm,sturdy_shield,tuck_basket",
				join(w2)
			)
		end,
	},
	{
		name = "seconds left counts down to the next window",
		run = function()
			local _, left = Rotation.listing(catalogue, config, 3599)
			assert(left == 1, `{left}`)
			local _, atBoundary = Rotation.listing(catalogue, config, 3600)
			assert(atBoundary == 3600, `{atBoundary}`)
			local _, early = Rotation.listing(catalogue, config, 0)
			assert(early == 3600)
			assert(Rotation.window(3599, 3600) == 0 and Rotation.window(3600, 3600) == 1)
		end,
	},
	{
		name = "each pool lists exactly its slot count with no duplicates, in every window",
		run = function()
			for window = 0, 60 do
				local list = Rotation.listing(catalogue, config, window * 3600 + 17)
				assert(
					count(list, "skins") == 3 and count(list, "boosts") == 2,
					`window {window}: {join(list)}`
				)
				local seen: { [string]: boolean } = {}
				for _, id in list do
					assert(not seen[id], `{id} listed twice in window {window}`)
					seen[id] = true
				end
				assert(#list == 6)
			end
			-- control: change the slot count and the listing follows it
			local wider = { WindowSeconds = 3600, Seed = 7351, Pools = { skins = 5, boosts = 1 } }
			local list = Rotation.listing(catalogue, wider, 0)
			assert(count(list, "skins") == 5 and count(list, "boosts") == 1)
		end,
	},
	{
		name = "always items are listed in every window, and a pool never lists more than it has",
		run = function()
			for window = 0, 30 do
				local list = Rotation.listing(catalogue, config, window * 3600)
				assert(table.find(list, "tuck_basket") ~= nil, `missing in window {window}`)
			end
			-- control: the pooled items do come and go
			local seen: { [string]: boolean } = {}
			for window = 0, 30 do
				for _, id in Rotation.listing(catalogue, config, window * 3600) do
					seen[id] = true
				end
			end
			assert(seen.speed_tonic and seen.hat_skin and seen.sword_skin)
			local greedy = { WindowSeconds = 3600, Seed = 1, Pools = { skins = 99, boosts = 2 } }
			assert(count(Rotation.listing(catalogue, greedy, 0), "skins") == 5, "capped at the pool size")
		end,
	},
}
