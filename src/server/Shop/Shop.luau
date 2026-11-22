--!strict
-- Buying from the shop. A factory: the ledger, the rotation and the item hand-over come in as
-- dependencies, so the rules can be tested without a game.
--
-- The price is read from the catalogue here and never from the caller: `purchase` has no price
-- parameter.
local Shop = {}
Shop.__index = Shop

type Item = {
	name: string,
	price: number,
	currency: string,
	pool: string?,
	always: boolean?,
	limitPerWindow: number?,
}

export type Deps = {
	ledger: any, -- the Ledger module
	rotation: any, -- the Rotation module
	catalogue: { [string]: Item },
	rotationConfig: any,
	clock: () -> number,
	logLength: number,
	-- Hands the item to the player. Returns false and a reason when it can't (for example, no room).
	grant: (key: any, itemId: string) -> (boolean, string?),
}

export type Shop = typeof(setmetatable({} :: { deps: Deps }, Shop))

function Shop.new(deps: Deps): Shop
	return setmetatable({ deps = deps }, Shop)
end

-- `data` is the session data: { wallet, bought }. Returns true, or false and one of "not_listed",
-- "limit", "negative" (can't afford it), "grant_failed", or a ledger error.
--
-- Checks, then debits, then grants. The window allowance is used up before the grant runs, so a
-- grant that yields can't let a second purchase slip through the limit; both are put back if the
-- grant fails.
function Shop.purchase(self: Shop, key: any, data: any, itemId: string): (boolean, string?)
	local deps = self.deps
	local item = if type(itemId) == "string" then deps.catalogue[itemId] else nil
	if item == nil then
		return false, "not_listed"
	end
	local now = deps.clock()
	local listed = deps.rotation.listing(deps.catalogue, deps.rotationConfig, now)
	if table.find(listed, itemId) == nil then
		return false, "not_listed"
	end

	local window = deps.rotation.window(now, deps.rotationConfig.WindowSeconds)
	local record = data.bought[itemId]
	local count = if record ~= nil and record.window == window then record.count else 0
	if item.limitPerWindow ~= nil and count >= item.limitPerWindow then
		return false, "limit"
	end

	local debited, err =
		deps.ledger.apply(data.wallet, item.currency, -item.price, `buy:{itemId}`, now, deps.logLength)
	if not debited then
		return false, err
	end
	local before = record
	data.bought[itemId] = { window = window, count = count + 1 }

	local ok, granted = pcall(deps.grant, key, itemId)
	if not ok or granted ~= true then
		-- Put everything back: the charge, and the allowance.
		deps.ledger.apply(data.wallet, item.currency, item.price, `refund:{itemId}`, now, deps.logLength)
		data.bought[itemId] = before
		return false, "grant_failed"
	end
	return true, nil
end

return Shop
