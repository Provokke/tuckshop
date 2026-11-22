--!strict
-- What a new profile holds and how it is stored.
local Deep = require("../fakes/Deep")
local FakeClock = require("../fakes/FakeClock")
local Profile = require("../../src/server/Data/Profile")
local StoreServer = require("../fakes/StoreServer")

local function profile(): any
	return Profile.new({
		newWallet = function()
			return { balances = { Coins = 100, Gems = 0 }, log = {} }
		end,
	})
end

return {
	{
		name = "a new profile already holds the starting balances",
		run = function()
			local data = profile().defaultData()
			assert(data.wallet.balances.Coins == 100 and data.wallet.balances.Gems == 0)
			assert(next(data.bought) == nil and next(data.receipts) == nil)
			-- control: two new profiles never share a table
			local other = profile().defaultData()
			other.wallet.balances.Coins = 1
			assert(data.wallet.balances.Coins == 100)
		end,
	},
	{
		name = "starting balances are written by the first claim, once, even if the player leaves at once",
		run = function()
			local p = profile()
			local records: any = {}
			local store = StoreServer.new(records, FakeClock.new(0), "JOB", {
				defaultData = p.defaultData,
				encode = p.encode,
				decode = p.decode,
			})
			local first, outcome = store:load("p1")
			assert(first ~= nil and outcome == "new", outcome)
			assert(records.p1.data.wallet.balances.Coins == 100, "the claim itself wrote the balances")
			assert(first:release() == true) -- they left before any save
			local again, outcome2 = store:load("p1")
			assert(again ~= nil and outcome2 == "taken", outcome2)
			assert(again.data.wallet.balances.Coins == 100, "granted once, not again")
		end,
	},
	{
		name = "encode and decode keep every field, and the stored form shares nothing with the session",
		run = function()
			local p = profile()
			local data = p.defaultData()
			data.wallet.balances.Coins = 7
			data.bought.sword_skin = { window = 4, count = 1 }
			data.receipts["abc"] = 12
			data.settings = { music = false }
			local stored = p.encode(data)
			assert(Deep.equal(stored, data), "every field is stored, including ones the module doesn't know")
			stored.wallet.balances.Coins = 0
			assert(data.wallet.balances.Coins == 7, "encode copies")
			assert(Deep.equal(p.decode(p.encode(data)), data), "and the round trip is whole")
		end,
	},
	{
		name = "data that isn't a table, or has no wallet, is refused instead of opened as a fresh profile",
		run = function()
			local p = profile()
			assert(pcall(p.decode, "oops") == false)
			assert(pcall(p.decode, { bought = {} }) == false, "no wallet")
			-- control: a whole record decodes
			assert(pcall(p.decode, p.defaultData()) == true)
			-- a record missing the optional fields gets them filled in
			local out = p.decode({ wallet = { balances = { Coins = 3 } } })
			assert(out.wallet.balances.Coins == 3 and next(out.bought) == nil and next(out.receipts) == nil)
			assert(#out.wallet.log == 0)
		end,
	},
}
