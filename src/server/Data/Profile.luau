--!strict
-- The shape of one player's saved data: what a brand new profile holds, and how the session form
-- is turned into the stored form and back.
--
--   wallet   { balances, log }                   the Ledger's wallet
--   bought   { [itemId] = { window, count } }    purchases in the current rotation window
--   receipts { [PurchaseId] = time }             developer-product purchases already granted
--
-- Every field is plain data with string keys and dense arrays, so the stored form is the session
-- form. encode and decode copy every field, so a field added to defaultData is saved and loaded
-- without anyone having to remember to list it here.
local Profile = {}

type Data = { [string]: any }

export type Deps = {
	newWallet: () -> any, -- a wallet holding the starting balances
}

export type Profile = {
	defaultData: () -> Data,
	encode: (data: Data) -> Data,
	decode: (saved: Data) -> Data,
}

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[deepCopy(k)] = deepCopy(v)
	end
	return out
end

function Profile.new(deps: Deps): Profile
	-- The starting balances are part of the default data, so the claim that creates the record
	-- writes them. A player who leaves (or a server that crashes) before the first save still
	-- has them next time, and they are never granted twice.
	local function defaultData(): Data
		return { wallet = deps.newWallet(), bought = {}, receipts = {} }
	end

	-- Session form to stored form. Runs inside UpdateAsync transforms, so it must not yield.
	local function encode(data: Data): Data
		return deepCopy(data)
	end

	-- Stored form to session form. Data that isn't a table, or that lacks a wallet, is refused,
	-- so the load fails and the record is left alone instead of being opened as an empty profile
	-- (which would hand out the starting balances again).
	local function decode(saved: Data): Data
		if type(saved) ~= "table" then
			error("saved data is not a table")
		end
		if type(saved.wallet) ~= "table" or type(saved.wallet.balances) ~= "table" then
			error("saved data has no wallet")
		end
		local out = deepCopy(saved)
		if type(out.wallet.log) ~= "table" then
			out.wallet.log = {}
		end
		if type(out.bought) ~= "table" then
			out.bought = {}
		end
		if type(out.receipts) ~= "table" then
			out.receipts = {}
		end
		return out
	end

	return { defaultData = defaultData, encode = encode, decode = decode }
end

return Profile
