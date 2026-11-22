--!strict
-- In-memory stand-in for a DataStore, used in Studio so the demo runs without API access.
-- It copies on the way in and out, like the real thing, so shared references can't leak through.
local MemoryStore = {}
MemoryStore.__index = MemoryStore

export type MemoryStore = typeof(setmetatable({} :: { records: { [string]: any } }, MemoryStore))

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

function MemoryStore.new(): MemoryStore
	return setmetatable({ records = {} }, MemoryStore)
end

-- Same contract as GlobalDataStore:UpdateAsync: a nil result cancels the write.
function MemoryStore.UpdateAsync(self: MemoryStore, key: string, transform: (any) -> any): any
	local current = deepCopy(self.records[key])
	local result = transform(current)
	if result == nil then
		return current
	end
	self.records[key] = deepCopy(result)
	return deepCopy(result)
end

return MemoryStore
