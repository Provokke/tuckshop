--!strict
--[[
	Developer-product receipts. This is the money path: it must never grant a purchase twice, and
	never lose one that was paid for. Roblox keeps calling ProcessReceipt for a purchase until it
	gets "PurchaseGranted", possibly on another server, so everything here is built around being
	called again.

	The rules:
	1. No live session for the player: NotProcessedYet. Roblox retries later, possibly on another
	   server. A session that is read-only (saved by a newer version of the game) or that has lost
	   its lease counts as no session, because nothing it did would be saved.
	2. Unknown product: log it and return NotProcessedYet. Never grant a guess.
	3. The PurchaseId is not yet in session.data.receipts: run the grant. If it errors (pcall) or
	   returns false: NotProcessedYet with nothing recorded. On success, record
	   receipts[PurchaseId] = now, and trim the oldest entries past `memory`. The grant and the
	   record happen with no yield between them, so a second call can't slip in between.
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
	getSession: (userId: number) -> any?, -- the live session (with .data and :save()), nil if not loaded
	products: { [number]: (session: any) -> boolean }, -- grant functions, by product id
	memory: number, -- how many PurchaseIds to remember (Config.ReceiptMemory)
	clock: () -> number,
	log: (message: string) -> (),
}

export type Receipts = typeof(setmetatable({} :: { deps: Deps, granting: { [string]: boolean } }, Receipts))

function Receipts.new(deps: Deps): Receipts
	return setmetatable({ deps = deps, granting = {} }, Receipts)
end

-- Drops the oldest ids until at most `memory` remain. The id just recorded is never dropped.
-- Entries with the same time are dropped in id order, which only matters when more than `memory`
-- purchases land in one second.
local function trim(receipts: { [string]: number }, memory: number, keep: string)
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
		if id ~= keep then
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
		trim(receipts, deps.memory, purchaseId)
	end

	local saved, result = pcall(function(): boolean
		return session:save()
	end)
	if not saved then
		deps.log(`save failed for receipt {purchaseId}: {tostring(result)}`)
		return "NotProcessedYet"
	end
	if result == true then
		return "PurchaseGranted"
	end
	return "NotProcessedYet"
end

return Receipts
