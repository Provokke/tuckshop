--!strict
-- Currency balances and the log of changes to them. A leaf: no requires, no clocks.
-- Balances are whole numbers only, so there is no rounding to argue about.
local Ledger = {}

export type Entry = { t: number, currency: string, delta: number, reason: string }
export type Wallet = { balances: { [string]: number }, log: { Entry } }

local MAX_BALANCE = 2 ^ 53 - 1 -- the largest whole number a double holds exactly

-- A wallet holding each currency's starting balance. `currencies` is the Config table.
function Ledger.new(currencies: { [string]: { start: number } }): Wallet
	local balances: { [string]: number } = {}
	for name, def in currencies do
		balances[name] = def.start
	end
	return { balances = balances, log = {} }
end

function Ledger.balance(wallet: Wallet, currency: string): number
	return wallet.balances[currency] or 0
end

-- Changes a balance by a whole-number `delta` and logs it. Refuses, changing nothing, with
-- "unknown_currency", "bad_delta" (not a finite whole number, or zero), "negative" (the balance
-- would go below zero) or "overflow". The log keeps the newest `logLength` entries, newest last.
function Ledger.apply(
	wallet: Wallet,
	currency: string,
	delta: number,
	reason: string,
	now: number,
	logLength: number
): (boolean, string?)
	local balance = wallet.balances[currency]
	if balance == nil then
		return false, "unknown_currency"
	end
	if
		type(delta) ~= "number"
		or delta ~= delta
		or delta % 1 ~= 0
		or delta == 0
		or math.abs(delta) == math.huge
	then
		return false, "bad_delta"
	end
	local after = balance + delta
	if after < 0 then
		return false, "negative"
	end
	if after > MAX_BALANCE then
		return false, "overflow"
	end
	wallet.balances[currency] = after
	table.insert(wallet.log, { t = now, currency = currency, delta = delta, reason = reason })
	while #wallet.log > logLength do
		table.remove(wallet.log, 1)
	end
	return true, nil
end

return Ledger
