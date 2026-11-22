--!strict
local Config = require("../../src/shared/Config")
local ConfigCheck = require("../../src/shared/ConfigCheck")
local Steps = require("../../src/server/Data/Steps")

-- Builds a config the checks accept, then lets a test break one thing.
local function good(): any
	return {
		SchemaVersion = 1,
		AutosaveSeconds = 60,
		LeaseSeconds = 180,
		LoadRetries = 5,
		CloseTimeoutSeconds = 25,
		LogLength = 25,
		ReceiptMemory = 200,
		Currencies = { Coins = { start = 100 }, Gems = { start = 0 } },
		Catalogue = {
			a = { name = "A", price = 10, currency = "Coins", pool = "p", limitPerWindow = 1 },
			b = { name = "B", price = 20, currency = "Gems", pool = "p" },
			c = { name = "C", price = 5, currency = "Coins", always = true },
		},
		Rotation = { WindowSeconds = 3600, Seed = 1, Pools = { p = 2 } },
		Products = { [7] = { grant = "Gems", amount = 50 } },
	}
end

local function hasProblem(problems: { string }, needle: string): boolean
	for _, p in problems do
		if string.find(p, needle, 1, true) then
			return true
		end
	end
	return false
end

-- Breaks the good config with `change`, and checks the problem is reported while the unbroken
-- config reports nothing.
local function flagged(change: (config: any) -> (), needle: string)
	local config = good()
	assert(#ConfigCheck.check(config, Steps) == 0, "control: the good config is clean")
	change(config)
	local problems = ConfigCheck.check(config, Steps)
	assert(hasProblem(problems, needle), `expected "{needle}", got: {table.concat(problems, "; ")}`)
end

return {
	{
		name = "the shipped config and migration steps have no problems",
		run = function()
			local problems = ConfigCheck.check(Config, Steps)
			assert(#problems == 0, table.concat(problems, "; "))
		end,
	},
	{
		name = "an item priced in a currency that doesn't exist is flagged",
		run = function()
			flagged(function(c)
				c.Catalogue.a.currency = "Gold"
			end, "unknown currency")
		end,
	},
	{
		name = "prices must be positive whole numbers",
		run = function()
			flagged(function(c)
				c.Catalogue.a.price = 0
			end, "price must be")
			flagged(function(c)
				c.Catalogue.a.price = 2.5
			end, "price must be")
			flagged(function(c)
				c.Catalogue.a.price = -3
			end, "price must be")
		end,
	},
	{
		name = "a pool with no slot count is flagged",
		run = function()
			flagged(function(c)
				c.Catalogue.a.pool = "other"
			end, 'pool "other" has no slot count')
		end,
	},
	{
		name = "a slot count bigger than its pool is flagged",
		run = function()
			flagged(function(c)
				c.Rotation.Pools.p = 3
			end, "lists 3 but the pool only has 2")
		end,
	},
	{
		name = "an item that is neither pooled nor always listed is flagged",
		run = function()
			flagged(function(c)
				c.Catalogue.c.always = nil
			end, "never listed")
		end,
	},
	{
		name = "receipt memory under 50 is flagged",
		run = function()
			flagged(function(c)
				c.ReceiptMemory = 49
			end, "ReceiptMemory")
			local config = good()
			config.ReceiptMemory = 50
			assert(#ConfigCheck.check(config, Steps) == 0, "50 is the smallest allowed")
		end,
	},
	{
		name = "a product that grants an unknown currency or a bad amount is flagged",
		run = function()
			flagged(function(c)
				c.Products[7].grant = "Rubies"
			end, "product 7: unknown currency")
			flagged(function(c)
				c.Products[7].amount = 1.5
			end, "product 7: amount")
		end,
	},
	{
		name = "migration steps that don't cover every schema bump are flagged",
		run = function()
			local config = good()
			config.SchemaVersion = 2
			assert(hasProblem(ConfigCheck.check(config, Steps), "needs exactly 1 migration step"))
			local step = function(d: any)
				return d
			end
			local ok = ConfigCheck.check(config, { step })
			assert(#ok == 0, table.concat(ok, "; ")) -- control
		end,
	},
	{
		name = "a SchemaVersion that isn't a whole number of 1 or more is flagged",
		run = function()
			for _, bad in { 0, 1.5, -1 } do
				local config = good()
				config.SchemaVersion = bad
				assert(hasProblem(ConfigCheck.check(config, Steps), "SchemaVersion must be"), tostring(bad))
			end
		end,
	},
	{
		name = "a lease shorter than two autosaves, no load retries, or a long close are flagged",
		run = function()
			flagged(function(c)
				c.LeaseSeconds = 100
			end, "LeaseSeconds")
			flagged(function(c)
				c.LoadRetries = 0
			end, "LoadRetries")
			flagged(function(c)
				c.CloseTimeoutSeconds = 29
			end, "CloseTimeoutSeconds")
		end,
	},
}
