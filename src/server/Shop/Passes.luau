--!strict
-- Game pass ownership, cached per player. A factory: the ownership check comes in as a function
-- (the entry script wraps MarketplaceService:UserOwnsGamePassAsync), so the rules can be tested.
--
-- A check that errors counts as "not owned" and is tried again on the next refresh, so a service
-- outage never gives a perk away. A pass already seen as owned stays owned through a failed check.
local Passes = {}
Passes.__index = Passes

export type Deps = {
	passes: { [number]: { perk: string } }, -- Config.GamePasses
	owns: (userId: number, passId: number) -> boolean, -- may yield, may error
}

export type Passes = typeof(setmetatable(
	{} :: { deps: Deps, owned: { [number]: { [number]: boolean } } },
	Passes
))

function Passes.new(deps: Deps): Passes
	return setmetatable({ deps = deps, owned = {} }, Passes)
end

-- Checks every configured pass for the player. Yields. Id 0 (or below) is the placeholder in
-- Config and is never asked about.
function Passes.refresh(self: Passes, userId: number)
	local result: { [number]: boolean } = {}
	for passId in self.deps.passes do
		if passId > 0 then
			local ok, owned = pcall(self.deps.owns, userId, passId)
			result[passId] = ok and owned == true
		end
	end
	-- Don't lose a purchase made while the checks were running.
	local before = self.owned[userId]
	if before ~= nil then
		for passId, was in before do
			if was then
				result[passId] = true
			end
		end
	end
	self.owned[userId] = result
end

-- A purchase finished (PromptGamePassPurchaseFinished with wasPurchased = true): owned from now on.
function Passes.bought(self: Passes, userId: number, passId: number)
	if self.deps.passes[passId] == nil or passId <= 0 then
		return
	end
	local owned = self.owned[userId]
	if owned == nil then
		owned = {}
		self.owned[userId] = owned
	end
	owned[passId] = true
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

function Passes.forget(self: Passes, userId: number)
	self.owned[userId] = nil
end

return Passes
