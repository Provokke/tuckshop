--!strict
-- Game pass ownership, cached per player. A factory: the ownership check and the wait come in as
-- functions (the entry script wraps MarketplaceService:UserOwnsGamePassAsync and task.wait), so
-- the rules can be tested.
--
-- A check that errors counts as "not owned", so a service outage never gives a perk away, and is
-- tried again every 30 s for up to 3 minutes while the player is here, so an outage at join
-- doesn't take away a perk they paid for. A pass already seen as owned stays owned through a
-- failed check. A finished purchase counts at once and is then confirmed with the server.
local Passes = {}
Passes.__index = Passes

export type Deps = {
	passes: { [number]: { perk: string } }, -- Config.GamePasses
	owns: (userId: number, passId: number) -> boolean, -- may yield, may error
	wait: (seconds: number) -> (), -- task.wait
}

export type Passes = typeof(setmetatable(
	{} :: {
		deps: Deps,
		owned: { [number]: { [number]: boolean } },
		-- the refresh running for each player; forget clears it, which stops that refresh
		checking: { [number]: {} },
	},
	Passes
))

local RETRY_SECONDS = 30
local RETRIES = 6

function Passes.new(deps: Deps): Passes
	return setmetatable({ deps = deps, owned = {}, checking = {} }, Passes)
end

local function markOwned(self: Passes, userId: number, passId: number)
	local owned = self.owned[userId]
	if owned == nil then
		owned = {}
		self.owned[userId] = owned
	end
	owned[passId] = true
end

-- Checks every configured pass for the player, then tries the failed ones again until they work,
-- the retries run out or the player is forgotten. Yields, so the entry script spawns it. Id 0 (or
-- below) is the placeholder in Config and is never asked about. A newer refresh for the same
-- player takes over from this one.
function Passes.refresh(self: Passes, userId: number)
	local deps = self.deps
	local token = {}
	self.checking[userId] = token
	local pending: { number } = {}
	for passId in deps.passes do
		if passId > 0 then
			table.insert(pending, passId)
		end
	end
	for attempt = 0, RETRIES do
		if attempt > 0 then
			deps.wait(RETRY_SECONDS)
			if self.checking[userId] ~= token then
				return
			end
		end
		local failed: { number } = {}
		for _, passId in pending do
			local ok, owned = pcall(deps.owns, userId, passId)
			if self.checking[userId] ~= token then
				return -- they left (or a newer refresh started) while the check was out
			end
			if not ok then
				table.insert(failed, passId)
			elseif owned == true then
				markOwned(self, userId, passId)
			end
		end
		pending = failed
		if #pending == 0 then
			break
		end
	end
	self.checking[userId] = nil
end

-- A purchase finished (PromptGamePassPurchaseFinished with wasPurchased = true): owned from now on.
function Passes.bought(self: Passes, userId: number, passId: number)
	if self.deps.passes[passId] == nil or passId <= 0 then
		return
	end
	markOwned(self, userId, passId)
end

-- After `bought`, asks the server whether the pass really is owned. The finished event updates
-- the cache UserOwnsGamePassAsync reads, so a check that works and says "not owned" means the
-- event was wrong, and the pass is taken back. A check that errors keeps it. Yields.
function Passes.confirm(self: Passes, userId: number, passId: number)
	if self.deps.passes[passId] == nil or passId <= 0 then
		return
	end
	local ok, owned = pcall(self.deps.owns, userId, passId)
	if ok and owned ~= true then
		local entry = self.owned[userId]
		if entry ~= nil then
			entry[passId] = nil
		end
	end
end

function Passes.has(self: Passes, userId: number, perk: string): boolean
	local owned = self.owned[userId]
	if owned == nil then
		return false
	end
	for passId, def in self.deps.passes do
		if def.perk == perk and owned[passId] == true then
			return true
		end
	end
	return false
end

-- PlayerRemoving: drops what is cached for them and stops a refresh still running.
function Passes.forget(self: Passes, userId: number)
	self.owned[userId] = nil
	self.checking[userId] = nil
end

return Passes
