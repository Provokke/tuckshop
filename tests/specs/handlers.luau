--!strict
-- What a client can and can't make the server do.
local FakeClock = require("../fakes/FakeClock")
local Handlers = require("../../src/server/Handlers")
local Ledger = require("../../src/server/Shop/Ledger")
local RateLimiter = require("../../src/shared/RateLimiter")
local Rotation = require("../../src/server/Shop/Rotation")
local Shop = require("../../src/server/Shop/Shop")
local Validate = require("../../src/shared/Validate")

-- Window 0 lists boots_skin, cape_skin, lucky_charm, night_lantern, shield_skin and tuck_basket.
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

local function setup(): any
	local w: any = { clock = FakeClock.new(0), sent = {}, grants = {} }
	w.sessions = {
		[1] = {
			data = {
				wallet = { balances = { Coins = 1000, Gems = 0 }, log = {} },
				bought = {},
				receipts = {},
			},
		},
		[2] = {
			readOnly = true,
			data = {
				wallet = { balances = { Coins = 1000, Gems = 0 }, log = {} },
				bought = {},
				receipts = {},
			},
		},
	}
	local function now(): number
		return w.clock:now()
	end
	local shop = Shop.new({
		ledger = Ledger,
		rotation = Rotation,
		catalogue = catalogue,
		rotationConfig = rotationConfig,
		clock = now,
		logLength = 25,
		grant = function(key: any, itemId: string)
			table.insert(w.grants, `{key}:{itemId}`)
			return true, nil
		end,
	})
	w.handlers = Handlers.new({
		validate = Validate,
		limiter = RateLimiter.new(3, 1, now),
		getSession = function(userId: number)
			return w.sessions[userId]
		end,
		writableSession = function(userId: number)
			local s = w.sessions[userId]
			if s == nil or s.readOnly == true then
				return nil
			end
			return s
		end,
		shop = shop,
		rotation = Rotation,
		catalogue = catalogue,
		rotationConfig = rotationConfig,
		clock = now,
		send = function(userId: number, payload: any)
			table.insert(w.sent, { userId = userId, payload = payload })
		end,
	})
	return w
end

return {
	{
		name = "a buy request charges the catalogue price, grants the item and sends the new balances",
		run = function()
			local w = setup()
			w.handlers:handle(1, "buy", "shield_skin")
			assert(w.sessions[1].data.wallet.balances.Coins == 750)
			assert(#w.grants == 1 and w.grants[1] == "1:shield_skin")
			assert(#w.sent == 1 and w.sent[1].userId == 1)
			assert(w.sent[1].payload.balances.Coins == 750, "the sync carries the real balance")
			assert(w.sent[1].payload.viewOnly == false)
		end,
	},
	{
		name = "malformed requests are dropped and counted, and a well-formed one still works",
		run = function()
			local w = setup()
			local bad: { { any } } = {
				{ 12, "shield_skin" },
				{ "delete_everything", nil },
				{ "buy", 12 },
				{ "buy", nil },
				{ "buy", string.rep("x", 41) },
				{ "buy", { "shield_skin" } },
				{ nil, nil },
			}
			for i, args in bad do
				w.clock:advance(10) -- never the rate limit
				w.handlers:handle(1, args[1], args[2])
				assert(w.handlers.dropped == i, `request {i} was not dropped`)
			end
			assert(w.sessions[1].data.wallet.balances.Coins == 1000 and #w.grants == 0 and #w.sent == 0)
			-- control
			w.handlers:handle(1, "buy", "shield_skin")
			assert(w.sessions[1].data.wallet.balances.Coins == 750 and #w.sent == 1)
		end,
	},
	{
		name = "requests past the rate limit are dropped, and work again after a refill",
		run = function()
			local w = setup()
			for _ = 1, 3 do
				w.handlers:handle(1, "listing")
			end
			assert(#w.sent == 3)
			w.handlers:handle(1, "buy", "tuck_basket") -- the fourth in the same instant
			assert(w.handlers.dropped == 1 and #w.sent == 3)
			assert(w.sessions[1].data.wallet.balances.Coins == 1000, "nothing was bought")
			w.clock:advance(1)
			w.handlers:handle(1, "buy", "tuck_basket")
			assert(w.sessions[1].data.wallet.balances.Coins == 970 and #w.sent == 4)
		end,
	},
	{
		name = "a view-only session can look at the shop but can't buy",
		run = function()
			local w = setup()
			w.handlers:handle(2, "buy", "shield_skin")
			assert(w.sessions[2].data.wallet.balances.Coins == 1000 and #w.grants == 0)
			assert(#w.sent == 1 and w.sent[1].payload.viewOnly == true, "they are shown the shop, view-only")
			-- control: the same request from a normal session buys
			w.handlers:handle(1, "buy", "shield_skin")
			assert(w.sessions[1].data.wallet.balances.Coins == 750 and #w.grants == 1)
		end,
	},
	{
		name = "a player with no session gets nothing and changes nothing",
		run = function()
			local w = setup()
			w.handlers:handle(99, "buy", "shield_skin")
			w.handlers:handle(99, "listing")
			assert(#w.grants == 0 and #w.sent == 0)
			-- control: a player with a session is answered
			w.handlers:handle(1, "listing")
			assert(#w.sent == 1)
		end,
	},
	{
		name = "the listing shows the items in this window with their prices and what has been bought",
		run = function()
			local w = setup()
			w.handlers:handle(1, "buy", "shield_skin")
			w.handlers:handle(1, "listing")
			local view = w.sent[2].payload
			local ids = {}
			for _, item in view.listing do
				table.insert(ids, item.id)
			end
			assert(
				table.concat(ids, ",")
					== "boots_skin,cape_skin,lucky_charm,night_lantern,shield_skin,tuck_basket"
			)
			assert(view.secondsLeft == 3600)
			local shield: any
			local cape: any
			for _, item in view.listing do
				if item.id == "shield_skin" then
					shield = item
				elseif item.id == "cape_skin" then
					cape = item
				end
			end
			assert(shield.price == 250 and shield.bought == 1 and shield.limit == 1)
			assert(cape.price == 400 and cape.bought == 0 and cape.currency == "Coins")
			-- the next window: the count of what was bought restarts
			w.clock:advance(3600)
			w.handlers:push(1)
			local later = w.sent[#w.sent].payload
			assert(later.secondsLeft == 3600)
			for _, item in later.listing do
				assert(item.bought == 0, item.id)
			end
		end,
	},
}
