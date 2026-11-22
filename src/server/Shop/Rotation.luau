--!strict
-- Which items the shop lists right now. A leaf with its own random numbers, so every server, and
-- the Lune tests, agree on the listing for a given time. Nothing here reads a clock: the caller
-- passes `now`.
--
-- The generator is xorshift32 kept to 32 bits with bit32. Luau's math.random is not the same on
-- every server, so it can't be used for this.
local Rotation = {}

type Item = { pool: string?, always: boolean? }
type Config = { WindowSeconds: number, Seed: number, Pools: { [string]: number } }

local WARM_UP = 4 -- rounds thrown away, so a small seed doesn't give a small first number

local function step(x: number): number
	x = bit32.bxor(x, bit32.lshift(x, 13))
	x = bit32.bxor(x, bit32.rshift(x, 17))
	x = bit32.bxor(x, bit32.lshift(x, 5))
	return x
end

-- The window number that `now` falls in.
function Rotation.window(now: number, windowSeconds: number): number
	return math.floor(now / windowSeconds)
end

local function sortedIds(items: { string }): { string }
	table.sort(items)
	return items
end

-- Returns the listed item ids, sorted, and the seconds until the next window starts. Items with
-- `always = true` are always listed. Each pool lists its configured number of slots, picked
-- without replacement from the pool's ids in sorted order, seeded with Seed + window.
function Rotation.listing(catalogue: { [string]: Item }, config: Config, now: number): ({ string }, number)
	local window = Rotation.window(now, config.WindowSeconds)
	local listed: { string } = {}
	local pools: { [string]: { string } } = {}
	for id, item in catalogue do
		if item.always == true then
			table.insert(listed, id)
		elseif item.pool ~= nil then
			local members = pools[item.pool]
			if members == nil then
				members = {}
				pools[item.pool] = members
			end
			table.insert(members, id)
		end
	end
	for pool, members in pools do
		local remaining = sortedIds(members)
		local state = (config.Seed + window) % 2 ^ 32
		if state == 0 then
			state = 1 -- xorshift never leaves zero
		end
		for _ = 1, WARM_UP do
			state = step(state)
		end
		for _ = 1, math.min(config.Pools[pool] or 0, #remaining) do
			state = step(state)
			local pick = state % #remaining + 1
			table.insert(listed, table.remove(remaining, pick))
		end
	end
	local untilNext = config.WindowSeconds - (now - window * config.WindowSeconds)
	return sortedIds(listed), untilNext
end

return Rotation
