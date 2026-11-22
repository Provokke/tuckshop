--!strict
local MemoryStore = require("../../src/server/Data/MemoryStore")

return {
	{
		name = "UpdateAsync stores a copy, so later edits to the original don't leak in",
		run = function()
			local store = MemoryStore.new()
			local value = { gold = 1, nested = { n = 1 } }
			store:UpdateAsync("k", function()
				return value
			end)
			value.gold = 99
			value.nested.n = 99
			local seen: any
			store:UpdateAsync("k", function(current: any)
				seen = current
				return nil
			end)
			assert(seen.gold == 1 and seen.nested.n == 1, "stored data should be unaffected")
		end,
	},
	{
		name = "a nil result cancels the write, a table result replaces the record",
		run = function()
			local store = MemoryStore.new()
			store:UpdateAsync("k", function()
				return nil
			end)
			assert(store.records.k == nil, "cancelled write stored nothing")
			store:UpdateAsync("k", function()
				return { v = 2 }
			end)
			assert(store.records.k.v == 2)
			store:UpdateAsync("k", function(current: any)
				return { v = current.v + 1 }
			end)
			assert(store.records.k.v == 3, "the transform sees the stored record")
		end,
	},
}
