--!strict
--[[
	Developer-product receipts. This is the money path: it must never grant a purchase twice, and
	never lose one that was paid for. Roblox keeps calling ProcessReceipt for a purchase until it
	gets "PurchaseGranted", possibly on another server, so everything here is built around being
	called again.

	The rules:
	1. No live session for the player: NotProcessedYet. Roblox retries later, possibly on another
	   server. A session that is read-only (saved by a newer version of the game) or that has lost
	   its lease counts as no session, because nothing it did would be saved. getSession may yield
	   to wait for a session that is still loading, so a receipt that arrives as the player joins
	   is granted once their data is in rather than left for their next purchase.
	2. Unknown product: log it and return NotProcessedYet. Never grant a guess.
	3. The PurchaseId is not yet in session.data.receipts: run the grant. If it errors (pcall) or
	   returns false: NotProcessedYet with nothing recorded. On success, record
	   receipts[PurchaseId] = now, and trim the oldest entries past `memory`. The grant and the
	   record happen with no yield between them, so a second call can't slip in between. An id
	   is never trimmed until a save that carries it has landed (this session remembers which of
	   its ids haven't), so a receipt still waiting for its retry can't be forgotten and granted
	   again. Until then the list can run over `memory`.
	4. Recorded (now or on an earlier try): call session:save(). Return PurchaseGranted only if
	   save returns true, which means the write landed with this session's lease. Otherwise
	   NotProcessedYet. A retry then finds the id recorded and only saves again, so the grant never
	   runs twice.

	A grant function must either succeed completely or change nothing, because a grant that
	returns false is treated as not having happened. If a grant yields, a second call for the same
	PurchaseId meanwhile gets NotProcessedYet instead of running the grant again.
]]
local Receipts = {}
Receipts.__index = Receipts

export type Receipt = { PlayerId: number, ProductId: number, PurchaseId: string }
export type Result = "PurchaseGranted" | "NotProcessedYet"

export type Deps = {
	getSession: (userId: number) -> any?, -- the live session (with .data and :save()), or nil; may yield
	products: { [number]: (session: any) -> boolean }, -- grant functions, by product id
	memory: number, -- how many PurchaseIds to remember (Config.ReceiptMemory)
	clock: () -> number,
	log: (message: string) -> (),
}

export type Receipts = typeof(setmetatable(
	{} :: {
		deps: Deps,
		granting: { [string]: boolean },
		-- by session: ids recorded in its data that no landed save has carried yet
		unsaved: { [any]: { [string]: boolean } },
	},
	Receipts
))

function Receipts.new(deps: Deps): Receipts
	-- Weak keys: a session that has been released and dropped takes its entry with it.
	local unsaved = setmetatable({}, { __mode = "k" }) :: any
	return setmetatable({ deps = deps, granting = {}, unsaved = unsaved }, Receipts)
end

-- Drops the oldest ids until at most `memory` remain, skipping any id in `keep` (recorded, not
-- yet saved; the id just recorded is always one of them). Entries with the same time are dropped
-- in id order, which only matters when more than `memory` purchases land in one second.
local function trim(receipts: { [string]: number }, memory: number, keep: { [string]: boolean })
	local ids: { string } = {}
	for id in receipts do
		table.insert(ids, id)
	end
	if #ids <= memory then
		return
	end
	table.sort(ids, function(a: string, b: string): boolean
		if receipts[a] ~= receipts[b] then
			return receipts[a] < receipts[b]
		end
		return a < b
	end)
	local excess = #ids - memory
	for _, id in ids do
		if excess == 0 then
			break
		end
		if not keep[id] then
			receipts[id] = nil
			excess -= 1
		end
	end
end

function Receipts.process(self: Receipts, receipt: Receipt): Result
	local deps = self.deps
	local userId, purchaseId = receipt.PlayerId, receipt.PurchaseId
	if type(purchaseId) ~= "string" or purchaseId == "" then
		deps.log(`receipt for {tostring(userId)} has no usable PurchaseId`)
		return "NotProcessedYet"
	end

	local session = deps.getSession(userId)
	if session == nil or session.lost == true or session.readOnly == true then
		return "NotProcessedYet"
	end

	local grant = deps.products[receipt.ProductId]
	if grant == nil then
		deps.log(`unknown product {tostring(receipt.ProductId)} in receipt {purchaseId} for {userId}`)
		return "NotProcessedYet"
	end

	local receipts: { [string]: number } = session.data.receipts
	if receipts[purchaseId] == nil then
		local flight = `{userId}:{purchaseId}`
		if self.granting[flight] then
			return "NotProcessedYet" -- another call is granting this one; Roblox will ask again
		end
		self.granting[flight] = true
		local ok, granted = pcall(grant, session)
		self.granting[flight] = nil
		if not ok then
			deps.log(`grant for product {receipt.ProductId} failed for {userId}: {tostring(granted)}`)
			return "NotProcessedYet"
		end
		if granted ~= true then
			return "NotProcessedYet"
		end
		-- The grant may have yielded, and the session may have been lost or replaced meanwhile.
		-- Record against the session that was granted to, and let the save say whether it landed.
		receipts[purchaseId] = deps.clock()
		local unsaved = self.unsaved[session]
		if unsaved == nil then
			unsaved = {}
			self.unsaved[session] = unsaved
		end
		unsaved[purchaseId] = true
		trim(receipts, deps.memory, unsaved)
	end

	local saved, result = pcall(function(): boolean
		return session:save()
	end)
	if not saved then
		deps.log(`save failed for receipt {purchaseId}: {tostring(result)}`)
		return "NotProcessedYet"
	end
	if result == true then
		-- This save was built after the id was recorded, so the id is in the store now.
		local unsaved = self.unsaved[session]
		if unsaved ~= nil then
			unsaved[purchaseId] = nil
		end
		return "PurchaseGranted"
	end
	return "NotProcessedYet"
end

return Receipts
