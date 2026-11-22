--!strict
return table.freeze({
	DataStoreName = "TuckshopPlayerData_v1", -- change it and every player starts fresh
	SchemaVersion = 1, -- bump when the saved data shape changes, and add a migration step
	AutosaveSeconds = 60, -- how often each session is written
	LeaseSeconds = 180, -- must be well over AutosaveSeconds, or a busy server loses its own lock
	LoadRetries = 5, -- attempts to load a profile before giving up
	RetryBaseSeconds = 1, -- doubles each retry: 1, 2, 4, 8 (five attempts, four waits)
	CloseTimeoutSeconds = 25, -- BindToClose gets about 30 s in total, leave headroom
	LogLength = 25, -- ledger entries kept per player, newest last
	ReceiptMemory = 200, -- developer-product purchase ids kept per player, for retries
	Currencies = table.freeze({
		Coins = table.freeze({ start = 100, colour = { 240, 190, 60 } }),
		Gems = table.freeze({ start = 0, colour = { 90, 170, 255 } }),
	}),
	-- id -> item. `pool` items rotate in and out of the shop; `always` items are always listed.
	-- limitPerWindow caps how many a player can buy in one rotation window.
	Catalogue = table.freeze({
		sword_skin = table.freeze({
			name = "Ember Sword Skin",
			price = 250,
			currency = "Coins",
			pool = "skins",
			limitPerWindow = 1,
		}),
		shield_skin = table.freeze({
			name = "Frostguard Shield Skin",
			price = 250,
			currency = "Coins",
			pool = "skins",
			limitPerWindow = 1,
		}),
		cape_skin = table.freeze({
			name = "Dusk Cape",
			price = 400,
			currency = "Coins",
			pool = "skins",
			limitPerWindow = 1,
		}),
		hat_skin = table.freeze({
			name = "Lantern Hat",
			price = 150,
			currency = "Coins",
			pool = "skins",
			limitPerWindow = 1,
		}),
		boots_skin = table.freeze({
			name = "Moss Boots",
			price = 5,
			currency = "Gems",
			pool = "skins",
			limitPerWindow = 1,
		}),
		speed_tonic = table.freeze({
			name = "Speed Tonic",
			price = 60,
			currency = "Coins",
			pool = "boosts",
			limitPerWindow = 3,
		}),
		lucky_charm = table.freeze({
			name = "Lucky Charm",
			price = 3,
			currency = "Gems",
			pool = "boosts",
			limitPerWindow = 2,
		}),
		sturdy_shield = table.freeze({
			name = "Sturdy Shield Boost",
			price = 90,
			currency = "Coins",
			pool = "boosts",
			limitPerWindow = 3,
		}),
		night_lantern = table.freeze({
			name = "Night Lantern",
			price = 120,
			currency = "Coins",
			pool = "boosts",
			limitPerWindow = 2,
		}),
		tuck_basket = table.freeze({
			name = "Tuckshop Basket",
			price = 30,
			currency = "Coins",
			always = true,
			limitPerWindow = 5,
		}),
	}),
	Rotation = table.freeze({
		WindowSeconds = 3600, -- the shop changes once an hour
		Seed = 7351, -- the same on every server, so they all show the same stock
		Pools = table.freeze({ skins = 3, boosts = 2 }), -- how many of each pool are listed
	}),
	-- Developer products by id: what a purchase grants. 0 is a placeholder that nothing buys;
	-- put your own product ids here.
	Products = table.freeze({
		[0] = table.freeze({ grant = "Gems", amount = 100 }),
	}),
	-- Game passes by id. 0 is a placeholder; put your own pass ids here.
	GamePasses = table.freeze({
		[0] = table.freeze({ perk = "DoubleCoins" }),
	}),
	CoinPad = table.freeze({
		Tag = "TuckshopCoinPad", -- any part with this tag is a coin pad
		Reward = 10, -- Coins per touch
		CooldownSeconds = 3, -- per player
	}),
	Limits = table.freeze({ BurstPerPlayer = 10, RefillPerSecond = 4 }), -- remote rate limit per player
})
