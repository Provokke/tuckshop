--!strict
-- The server entry script itself, run under Lune over FakeGame: the ProcessReceipt callback it
-- leaves in place, the receipt and purchase wiring, and what a player keeps across a rejoin.
local Config = require("../../src/shared/Config")
local FakeGame = require("../fakes/FakeGame")

local GRANTED = "PurchaseGranted"
local WAIT = "NotProcessedYet"
local GEMS_PRODUCT = 555

-- The shipped config with one real developer product that grants 100 Gems.
local function configWithProduct(): any
	local config = table.clone(Config)
	config.Products = { [GEMS_PRODUCT] = { grant = "Gems", amount = 100 } }
	return config
end

local function started(options: any?): any
	local opts = options or {}
	if opts.config == nil then
		opts.config = configWithProduct()
	end
	local world = FakeGame.new(opts)
	world:start()
	return world
end

local function stored(world: any, userId: number): any
	local record = world.records["Player_" .. userId]
	return if record ~= nil then record.data else nil
end

return {
	{
		name = "a config that fails its checks leaves a callback that answers NotProcessedYet",
		run = function()
			local bad = configWithProduct()
			bad.ReceiptMemory = 20
			local world = started({ config = bad })
			assert(world.started == true, world.startError)
			local found = false
			for _, line in world.warnings do
				if string.find(line, "ReceiptMemory", 1, true) then
					found = true
				end
			end
			assert(found, "the problem is warned about")
			assert(world:remote("Request") == nil, "nothing else started")
			local callback = world:callback()
			assert(callback ~= nil, "a callback is in place, so Roblox doesn't auto-acknowledge")
			local box = world:receipt(1, GEMS_PRODUCT, "p-1")
			assert(box.result == WAIT, tostring(box.result))
			-- control: with the config fixed, the same receipt for a loaded player is granted
			local good = started()
			good:join(1)
			local granted = good:receipt(1, GEMS_PRODUCT, "p-1")
			assert(granted.result == GRANTED, tostring(granted.result))
			assert(stored(good, 1).wallet.balances.Gems == 100 and stored(good, 1).receipts["p-1"] ~= nil)
		end,
	},
	{
		name = "the holding callback is in place before any module loads or any WaitForChild",
		run = function()
			-- A require that throws stops the script before the real callback is assigned.
			local broken = started({ failRequire = "Shop.Receipts" })
			assert(broken.started == false and string.find(broken.startError, "Receipts", 1, true) ~= nil)
			assert(broken:callback() ~= nil and broken:receipt(1, GEMS_PRODUCT, "p-1").result == WAIT)
			-- A WaitForChild that never returns: the script is parked at its first yield.
			local parked = started({ blockShared = true })
			assert(parked.started == nil, "still waiting")
			assert(parked:callback() ~= nil and parked:receipt(1, GEMS_PRODUCT, "p-1").result == WAIT)
			-- control: a script that starts replaces the holding callback with the real one
			local world = started()
			assert(world.started == true, world.startError)
			world:join(1)
			assert(world:receipt(1, GEMS_PRODUCT, "p-1").result == GRANTED, "the real callback replaced it")
		end,
	},
}
