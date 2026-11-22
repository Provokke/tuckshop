--!strict
-- Session lease rules. A lease says "this session owns this record until expiresAt".
--
-- The owner is one session, not one server. The entry script makes it from the server's JobId
-- and a fresh GUID for every load, so two sessions for the same player on the same server (a
-- quick leave and rejoin) can never both think they hold the record.
--
-- UpdateAsync may call a transform more than once, so the transforms must be pure and must not
-- mutate `stored`. They build a new table.
local Lease = {}

export type LeaseInfo = { owner: string, expiresAt: number }
export type Record = {
	schema: number,
	data: { [string]: any },
	lease: LeaseInfo?,
	savedAt: number,
	-- The owner whose release last landed. Owners are never reused, so a release retry that finds
	-- its own owner here knows its earlier attempt was committed even though the call errored.
	releasedBy: string?,
}

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = deepCopy(v)
	end
	return out
end

local function build(stored: Record, data: { [string]: any }, lease: LeaseInfo?, now: number): Record
	return {
		schema = stored.schema,
		data = data,
		lease = lease,
		savedAt = now,
		releasedBy = stored.releasedBy,
	}
end

-- Load transform. Outcomes: "new", "taken" (no lease, or this session's own lease from an
-- earlier attempt that landed), "stolen" (an expired lease), or "held" (a live lease from any
-- other session: returns nil, so UpdateAsync cancels).
-- A new record carries schema 0: the caller stamps the real schema version.
function Lease.claim(
	stored: Record?,
	owner: string,
	now: number,
	leaseSeconds: number,
	defaultData: () -> { [string]: any }
): (Record?, string)
	local mine: LeaseInfo = { owner = owner, expiresAt = now + leaseSeconds }
	if stored == nil then
		return { schema = 0, data = defaultData(), lease = mine, savedAt = now }, "new"
	end
	local theirs = stored.lease
	local outcome = "taken"
	if theirs ~= nil and theirs.owner ~= owner then
		if theirs.expiresAt > now then
			return nil, "held"
		end
		outcome = "stolen"
	end
	return build(stored, deepCopy(stored.data), mine, now), outcome
end

local function owns(stored: Record?, owner: string): boolean
	return stored ~= nil and stored.lease ~= nil and stored.lease.owner == owner
end

-- Autosave transform. "saved", or "lost" when the lease is missing or not ours (returns nil).
function Lease.refresh(
	stored: Record?,
	owner: string,
	now: number,
	leaseSeconds: number,
	data: { [string]: any },
	writeData: boolean
): (Record?, string)
	if stored == nil or not owns(stored, owner) then
		return nil, "lost"
	end
	local nextData = if writeData then deepCopy(data) else deepCopy(stored.data)
	return build(stored, nextData, { owner = owner, expiresAt = now + leaseSeconds }, now), "saved"
end

-- Leave transform. Writes data (if writeData), clears the lease and stamps releasedBy.
-- "released", or "lost" when the lease is missing or not ours (returns nil). A retry whose
-- earlier attempt already landed is "released" and writes nothing.
function Lease.release(
	stored: Record?,
	owner: string,
	now: number,
	data: { [string]: any },
	writeData: boolean
): (Record?, string)
	if stored ~= nil and stored.releasedBy == owner then
		return nil, "released"
	end
	if stored == nil or not owns(stored, owner) then
		return nil, "lost"
	end
	local nextData = if writeData then deepCopy(data) else deepCopy(stored.data)
	local record = build(stored, nextData, nil, now)
	record.releasedBy = owner
	return record, "released"
end

return Lease
