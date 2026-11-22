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
	{
		name = "a receipt that arrives while the player's data is still loading is granted once it loads",
		run = function()
			local world = started()
			world.ds:hookNext(function()
				world.sched:wait(5) -- the claim made by the join is slow
			end)
			world:join(1)
			local box = world:receipt(1, GEMS_PRODUCT, "p-1")
			assert(box.result == nil, "waiting for the load")
			world.sched:advance(6)
			assert(box.result == GRANTED, tostring(box.result or box.error))
			assert(stored(world, 1).wallet.balances.Gems == 100 and stored(world, 1).receipts["p-1"] ~= nil)
			-- control: a player who isn't on this server is answered at once
			local other = world:receipt(2, GEMS_PRODUCT, "p-2")
			assert(other.result == WAIT and stored(world, 2) == nil)
		end,
	},
	{
		name = "an item bought with Coins is saved with the charge and is still owned after a rejoin",
		run = function()
			local world = started()
			local player = world:join(1)
			world:request(1, "buy", "tuck_basket") -- 30 Coins, always listed
			assert(player.attributes.Owns_tuck_basket == 1, "handed over")
			world:leave(1)
			local data = stored(world, 1)
			assert(data.wallet.balances.Coins == 70, `Coins {data.wallet.balances.Coins}`)
			assert(data.bought.tuck_basket.count == 1)
			assert(data.owned ~= nil and data.owned.tuck_basket == 1, "the item was saved with the charge")
			local again = world:join(1)
			assert(again ~= player and again.attributes.Owns_tuck_basket == 1, "and is restored on load")
			-- control: a second purchase counts on from what was restored
			world:request(1, "buy", "tuck_basket")
			assert(again.attributes.Owns_tuck_basket == 2 and world.players[1] == again)
			world:leave(1)
			assert(stored(world, 1).owned.tuck_basket == 2 and stored(world, 1).wallet.balances.Coins == 40)
		end,
	},
	{
		name = "the coin pad pays 10 Coins, and 20 only with a pass the server confirms",
		run = function()
			local config = configWithProduct()
			config.GamePasses = { [77] = { perk = "DoubleCoins" } }
			local world = FakeGame.new({ config = config })
			local pad = world:addPad()
			world:start()
			world:join(1)
			local function coins(): number
				return world.synced[#world.synced].payload.balances.Coins
			end
			world:touch(pad, 1)
			assert(coins() == 110, `{coins()}`)
			-- a finished-purchase event the server can't confirm doesn't double the pad
			world:passFinished(1, 77, true)
			world.sched:advance(3)
			world:touch(pad, 1)
			assert(coins() == 120, `{coins()} after an unconfirmed purchase`)
			-- control: a purchase the server confirms does
			world.passOwned["1:77"] = true
			world:passFinished(1, 77, true)
			world.sched:advance(3)
			world:touch(pad, 1)
			assert(coins() == 140, `{coins()} after a confirmed purchase`)
		end,
	},
	{
		name = "a pass check that fails at join is tried again, so the perk arrives without a rejoin",
		run = function()
			local config = configWithProduct()
			config.GamePasses = { [77] = { perk = "DoubleCoins" } }
			local world = FakeGame.new({ config = config })
			local pad = world:addPad()
			world:start()
			world.passOwned["1:77"] = "error" -- the service is down as they join
			world:join(1)
			world:touch(pad, 1)
			assert(world.synced[#world.synced].payload.balances.Coins == 110, "not doubled while unknown")
			world.passOwned["1:77"] = true -- the service is back
			world.sched:advance(30)
			world:touch(pad, 1)
			assert(world.synced[#world.synced].payload.balances.Coins == 130, "doubled after the retry")
			assert(#world.passChecks == 2, `{#world.passChecks} checks`)
		end,
	},
}
