--!strict
local Ledger = require("../../src/server/Shop/Ledger")

local currencies = { Coins = { start = 100 }, Gems = { start = 0 } }

return {
	{
		name = "a credit raises the balance and is logged",
		run = function()
			local wallet = Ledger.new(currencies)
			assert(Ledger.balance(wallet, "Coins") == 100 and Ledger.balance(wallet, "Gems") == 0)
			local ok, err = Ledger.apply(wallet, "Coins", 25, "coin pad", 10, 25)
			assert(ok == true and err == nil)
			assert(wallet.balances.Coins == 125 and wallet.balances.Gems == 0, "only Coins moved")
			assert(#wallet.log == 1)
			local entry = wallet.log[1]
			assert(
				entry.t == 10
					and entry.currency == "Coins"
					and entry.delta == 25
					and entry.reason == "coin pad"
			)
		end,
	},
	{
		name = "a debit lowers the balance",
		run = function()
			local wallet = Ledger.new(currencies)
			local ok = Ledger.apply(wallet, "Coins", -30, "buy", 1, 25)
			assert(ok == true)
			assert(wallet.balances.Coins == 70)
			assert(wallet.log[1].delta == -30)
		end,
	},
	{
		name = "an overdraw is refused and changes nothing, but an exact-balance debit works",
		run = function()
			local wallet = Ledger.new(currencies)
			local ok, err = Ledger.apply(wallet, "Coins", -101, "buy", 1, 25)
			assert(ok == false and err == "negative", tostring(err))
			assert(wallet.balances.Coins == 100 and #wallet.log == 0, "balance and log untouched")
			-- control
			local ok2 = Ledger.apply(wallet, "Coins", -100, "buy", 2, 25)
			assert(ok2 == true and wallet.balances.Coins == 0)
		end,
	},
	{
		name = "a delta that isn't a whole number is refused",
		run = function()
			local wallet = Ledger.new(currencies)
			for _, bad in { 1.5, -0.25, 0 / 0, math.huge, -math.huge, 0 } do
				local ok, err = Ledger.apply(wallet, "Coins", bad, "x", 1, 25)
				assert(ok == false and err == "bad_delta", `{bad}: {tostring(err)}`)
			end
			local ok3, err3 = Ledger.apply(wallet, "Coins", "5" :: any, "x", 1, 25)
			assert(ok3 == false and err3 == "bad_delta", "a string is not a number")
			assert(wallet.balances.Coins == 100 and #wallet.log == 0)
			-- control
			assert(Ledger.apply(wallet, "Coins", 2, "x", 1, 25) == true and wallet.balances.Coins == 102)
		end,
	},
	{
		name = "an unknown currency is refused",
		run = function()
			local wallet = Ledger.new(currencies)
			local ok, err = Ledger.apply(wallet, "Rubies", 5, "x", 1, 25)
			assert(ok == false and err == "unknown_currency", tostring(err))
			assert(wallet.balances.Rubies == nil and #wallet.log == 0, "nothing was created")
			assert(Ledger.balance(wallet, "Rubies") == 0, "an unknown currency reads as zero")
			-- control
			assert(Ledger.apply(wallet, "Gems", 5, "x", 1, 25) == true and wallet.balances.Gems == 5)
		end,
	},
	{
		name = "the log is trimmed to its length, keeping the newest last",
		run = function()
			local wallet = Ledger.new(currencies)
			for i = 1, 5 do
				assert(Ledger.apply(wallet, "Coins", i, "r" .. i, i, 3) == true)
			end
			assert(#wallet.log == 3, `{#wallet.log}`)
			assert(
				wallet.log[1].reason == "r3" and wallet.log[2].reason == "r4" and wallet.log[3].reason == "r5"
			)
			assert(wallet.balances.Coins == 115, "trimming the log never changes the balance")
		end,
	},
	{
		name = "a balance can't grow past the largest whole number a double holds exactly",
		run = function()
			local wallet = Ledger.new(currencies)
			wallet.balances.Gems = 9007199254740990
			local ok, err = Ledger.apply(wallet, "Gems", 5, "x", 1, 25)
			assert(ok == false and err == "overflow", tostring(err))
			assert(wallet.balances.Gems == 9007199254740990)
			-- control: a credit that stays under the limit works
			assert(Ledger.apply(wallet, "Gems", 1, "x", 1, 25) == true)
			assert(wallet.balances.Gems == 9007199254740991)
		end,
	},
}
