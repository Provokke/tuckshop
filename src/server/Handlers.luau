--!strict
-- What the client may ask the server for. A factory: everything arrives as a dependency, so the
-- checks can be tested without remotes.
--
-- Clients send intent only: an action name and, for a purchase, an item id. Every call is checked
-- with Validate and then the per-player rate limiter before anything else, and a call that fails
-- either is dropped and counted. Nothing is sent back about why. The client learns the result
-- from the next Sync, which carries the real balances and listing.
local Handlers = {}
Handlers.__index = Handlers

export type Deps = {
	validate: any, -- the Validate module
	limiter: any, -- a RateLimiter, keyed by UserId
	getSession: (userId: number) -> any?, -- the live session, read-only ones included
	writableSession: (userId: number) -> any?, -- the live session only if it can be saved
	shop: any, -- a Shop
	rotation: any, -- the Rotation module
	catalogue: { [string]: any },
	rotationConfig: any,
	clock: () -> number,
	send: (userId: number, payload: any) -> (), -- one Sync to one player
}

export type Handlers = typeof(setmetatable({} :: { deps: Deps, dropped: number }, Handlers))

local ACTIONS: { [string]: boolean } = { buy = true, listing = true }
local MAX_ITEM_ID = 40

function Handlers.new(deps: Deps): Handlers
	return setmetatable({ deps = deps, dropped = 0 }, Handlers)
end

-- What one player is shown: their balances, the items listed now with their prices, how long
-- until the shop changes, and whether their session is view-only. nil if they have no session.
function Handlers.view(self: Handlers, userId: number): any?
	local deps = self.deps
	local session = deps.getSession(userId)
	if session == nil then
		return nil
	end
	local now = deps.clock()
	local ids, secondsLeft = deps.rotation.listing(deps.catalogue, deps.rotationConfig, now)
	local window = deps.rotation.window(now, deps.rotationConfig.WindowSeconds)
	local items = {}
	for _, id in ids do
		local item = deps.catalogue[id]
		local bought = session.data.bought[id]
		table.insert(items, {
			id = id,
			name = item.name,
			price = item.price,
			currency = item.currency,
			pool = item.pool,
			limit = item.limitPerWindow,
			bought = if bought ~= nil and bought.window == window then bought.count else 0,
		})
	end
	return {
		balances = table.clone(session.data.wallet.balances),
		listing = items,
		secondsLeft = secondsLeft,
		viewOnly = session.readOnly == true,
	}
end

-- Sends the player their current view, if they have a session.
function Handlers.push(self: Handlers, userId: number)
	local view = self:view(userId)
	if view ~= nil then
		self.deps.send(userId, view)
	end
end

-- One call from a client. Returns nothing.
function Handlers.handle(self: Handlers, userId: number, action: any, arg: any)
	local deps = self.deps
	local v = deps.validate
	local valid = v.isString(action, 16) and v.isOneOf(action, ACTIONS)
	if valid and action == "buy" then
		valid = v.isString(arg, MAX_ITEM_ID)
	end
	if not valid or not deps.limiter:take(userId) then
		self.dropped += 1
		return
	end
	if action == "buy" then
		local session = deps.writableSession(userId)
		if session == nil then
			self.dropped += 1
			self:push(userId) -- a view-only player just sees their shop unchanged
			return
		end
		deps.shop:purchase(userId, session.data, arg)
	end
	self:push(userId)
end

return Handlers
