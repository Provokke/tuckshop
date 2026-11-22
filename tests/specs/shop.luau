--!strict
local Ledger = require("../../src/server/Shop/Ledger")
local Rotation = require("../../src/server/Shop/Rotation")
local Shop = require("../../src/server/Shop/Shop")

-- Window 0 lists (computed with an independent xorshift32): boots_skin, cape_skin, lucky_charm,
-- night_lantern, shield_skin, tuck_basket. Window 1 lists boots_skin, cape_skin, night_lantern,
-- speed_tonic, sword_skin, tuck_basket.
local catalogue = {
	sword_skin = { name = "Sword", price = 250, currency = "Coins", pool = "skins", limitPerWindow = 1 },
	shield_skin = { name = "Shield", price = 250, currency = "Coins", pool = "skins", limitPerWindow = 1 },
	cape_skin = { name = "Cape", price = 400, currency = "Coins", pool = "skins", limitPerWindow = 1 },
	hat_skin = { name = "Hat", price = 150, currency = "Coins", pool = "skins", limitPerWindow = 1 },
	boots_skin = { name = "Boots", price = 5, currency = "Gems", pool = "skins", limitPerWindow = 1 },
	speed_tonic = { name = "Tonic", price = 60, currency = "Coins", pool = "boosts", limitPerWindow = 3 },
	lucky_charm = { name = "Charm", price = 3, currency = "Gems", pool = "boosts", limitPerWindow = 2 },
	sturdy_shield = { name = "Boost", price = 90, currency = "Coins", pool = "boosts", limitPerWindow = 3 },
	night_lantern = { name = "Lantern", price = 120, currency = "Coins", pool = "boosts" },
	tuck_basket = { name = "Basket", price = 30, currency = "Coins", always = true, limitPerWindow = 5 },
}
local rotationConfig = { WindowSeconds = 3600, Seed = 7351, Pools = { skins = 3, boosts = 2 } }
local currencies = { Coins = { start = 100 }, Gems = { start = 0 } }

local function setup(coins: number?)
	local w: any = { now = 0, grants = {}, grantResult = true }
	w.data = { wallet = Ledger.new(currencies), bought = {}, owned = {}, receipts = {} }
	if coins ~= nil then
		w.data.wallet.balances.Coins = coins
	end
	w.shop = Shop.new({
		ledger = Ledger,
		rotation = Rotation,
		catalogue = catalogue,
		rotationConfig = rotationConfig,
		clock = function()
			return w.now
		end,
		logLength = 25,
		grant = function(key: any, itemId: string, count: number)
			table.insert(w.grants, `{key}:{itemId}:{count}`)
			if w.grantResult == true then
				return true, nil
			end
			return false, "no_room"
		end,
	})
	return w
end

return {
	{
		name = "a purchase debits the price and hands over the item",
		run = function()
			local w = setup(500)
			local ok, err = w.shop:purchase(7, w.data, "shield_skin")
			assert(ok == true and err == nil, tostring(err))
			assert(w.data.wallet.balances.Coins == 250, "debited 250")
			assert(#w.grants == 1 and w.grants[1] == "7:shield_skin:1", w.grants[1])
			assert(w.data.bought.shield_skin.count == 1 and w.data.bought.shield_skin.window == 0)
			assert(w.data.owned.shield_skin == 1, "the item is kept in the same data as the charge")
			assert(w.data.wallet.log[1].reason == "buy:shield_skin" and w.data.wallet.log[1].delta == -250)
		end,
	},
	{
		name = "an item that isn't listed right now is refused with no charge",
		run = function()
			local w = setup(500)
			local ok, err = w.shop:purchase(7, w.data, "sword_skin") -- not in window 0
			assert(ok == false and err == "not_listed", tostring(err))
			local ok2, err2 = w.shop:purchase(7, w.data, "no_such_item")
			assert(ok2 == false and err2 == "not_listed", tostring(err2))
			local ok3, err3 = w.shop:purchase(7, w.data, 12 :: any)
			assert(ok3 == false and err3 == "not_listed", tostring(err3))
			assert(w.data.wallet.balances.Coins == 500 and #w.grants == 0 and #w.data.wallet.log == 0)
			-- control: in the window that does list it, the same call works
			w.now = 3600
			assert(w.shop:purchase(7, w.data, "sword_skin") == true)
			assert(w.data.wallet.balances.Coins == 250 and #w.grants == 1)
		end,
	},
	{
		name = "the limit per window is reached, then works again in the next window",
		run = function()
			local w = setup(5000)
			assert(w.shop:purchase(7, w.data, "shield_skin") == true)
			local ok, err = w.shop:purchase(7, w.data, "shield_skin")
			assert(ok == false and err == "limit", tostring(err))
			assert(w.data.wallet.balances.Coins == 4750 and #w.grants == 1, "the second try cost nothing")
			-- boots_skin is listed in both windows, so it can be bought again after the window turns
			assert(w.shop:purchase(7, w.data, "boots_skin") == false, "no gems yet") -- control for below
			w.data.wallet.balances.Gems = 20
			assert(w.shop:purchase(7, w.data, "boots_skin") == true)
			assert(w.shop:purchase(7, w.data, "boots_skin") == false, "limit 1 per window")
			w.now = 3600
			assert(w.shop:purchase(7, w.data, "boots_skin") == true, "a new window, a new allowance")
			assert(w.data.wallet.balances.Gems == 10 and w.data.bought.boots_skin.window == 1)
			assert(w.data.bought.boots_skin.count == 1, "the count restarted")
		end,
	},
	{
		name = "a player who can't afford an item is refused, and the same purchase works after a credit",
		run = function()
			local w = setup(399)
			local ok, err = w.shop:purchase(7, w.data, "cape_skin")
			assert(ok == false and err == "negative", tostring(err))
			assert(w.data.wallet.balances.Coins == 399 and #w.grants == 0)
			assert(w.data.bought.cape_skin == nil, "a refused purchase doesn't use up the limit")
			-- control
			Ledger.apply(w.data.wallet, "Coins", 1, "gift", 0, 25)
			assert(w.shop:purchase(7, w.data, "cape_skin") == true)
			assert(w.data.wallet.balances.Coins == 0 and #w.grants == 1)
		end,
	},
	{
		name = "a failed grant leaves the balance where it started, with a debit and a refund in the log",
		run = function()
			local w = setup(500)
			w.grantResult = false
			local ok, err = w.shop:purchase(7, w.data, "cape_skin")
			assert(ok == false and err == "grant_failed", tostring(err))
			assert(w.data.wallet.balances.Coins == 500, "back to where it started")
			local log = w.data.wallet.log
			assert(#log == 2, `{#log}`)
			assert(log[1].delta == -400 and log[1].reason == "buy:cape_skin")
			assert(log[2].delta == 400 and log[2].reason == "refund:cape_skin")
			assert(w.data.bought.cape_skin == nil, "and the limit isn't used up")
			assert(w.data.owned.cape_skin == nil, "and the item isn't kept")
			-- control: with the grant working again, the same purchase goes through
			w.grantResult = true
			assert(w.shop:purchase(7, w.data, "cape_skin") == true and w.data.wallet.balances.Coins == 100)
			assert(w.data.owned.cape_skin == 1)
		end,
	},
	{
		name = "a grant that throws is refunded the same way",
		run = function()
			local w = setup(500)
			local shop = Shop.new({
				ledger = Ledger,
				rotation = Rotation,
				catalogue = catalogue,
				rotationConfig = rotationConfig,
				clock = function()
					return w.now
				end,
				logLength = 25,
				grant = function()
					error("boom")
				end,
			})
			local ok, err = shop:purchase(7, w.data, "cape_skin")
			assert(ok == false and err == "grant_failed", tostring(err))
			assert(w.data.wallet.balances.Coins == 500 and w.data.bought.cape_skin == nil)
		end,
	},
	{
		name = "the price always comes from the catalogue, never from the caller",
		run = function()
			local w = setup(1000)
			-- purchase has no price parameter; extra arguments are ignored
			local purchase: any = w.shop.purchase
			local ok = purchase(w.shop, 7, w.data, "shield_skin", 1)
			assert(ok == true)
			assert(w.data.wallet.balances.Coins == 750, "250 was debited, not 1")
			assert(w.data.wallet.log[1].delta == -250)
			-- control: the catalogue's price is what moves the charge
			local pricey = table.clone(catalogue)
			pricey.shield_skin = { name = "Shield", price = 300, currency = "Coins", pool = "skins" }
			local w2 = setup(1000)
			w2.shop.deps.catalogue = pricey
			assert(w2.shop:purchase(7, w2.data, "shield_skin") == true)
			assert(w2.data.wallet.balances.Coins == 700)
		end,
	},
	{
		name = "each item bought is counted in the player's data, and a failed hand-over takes back only its own",
		run = function()
			local w = setup(1000)
			assert(w.shop:purchase(7, w.data, "night_lantern") == true)
			assert(w.shop:purchase(7, w.data, "night_lantern") == true)
			assert(w.data.owned.night_lantern == 2 and w.grants[2] == "7:night_lantern:2", w.grants[2])
			w.grantResult = false
			assert(w.shop:purchase(7, w.data, "night_lantern") == false)
			assert(w.data.owned.night_lantern == 2, "the two already handed over are kept")
			assert(w.data.wallet.balances.Coins == 760, "and only their price was taken")
			-- control: the third goes through once the hand-over works
			w.grantResult = true
			assert(w.shop:purchase(7, w.data, "night_lantern") == true and w.data.owned.night_lantern == 3)
			assert(w.data.wallet.balances.Coins == 640)
		end,
	},
	{
		name = "a server whose clock is behind can't reset an allowance used up in a later window",
		run = function()
			local w = setup(1000)
			w.now = 3601 -- window 1
			for _ = 1, 5 do
				assert(w.shop:purchase(7, w.data, "tuck_basket") == true)
			end
			assert(w.shop:purchase(7, w.data, "tuck_basket") == false, "limit 5 reached")
			w.now = 3599 -- the player hops to a server two seconds behind: window 0
			local ok, err = w.shop:purchase(7, w.data, "tuck_basket")
			assert(ok == false and err == "limit", tostring(err))
			assert(
				w.data.bought.tuck_basket.window == 1 and w.data.bought.tuck_basket.count == 5,
				"record kept"
			)
			assert(w.data.wallet.balances.Coins == 850 and #w.grants == 5, "nothing charged or handed over")
			-- control: the next window along gives a fresh allowance
			w.now = 7200
			assert(w.shop:purchase(7, w.data, "tuck_basket") == true)
			assert(w.data.bought.tuck_basket.window == 2 and w.data.bought.tuck_basket.count == 1)
			assert(w.data.wallet.balances.Coins == 820)
		end,
	},
}
