--!strict
-- The fake is what every store test stands on, so its UpdateAsync behaviour is checked here.
local FakeDataStore = require("../fakes/FakeDataStore")

return {
	{
		name = "a forced re-run runs the transform twice on fresh copies and keeps the second result",
		run = function()
			local ds = FakeDataStore.new({ k = { n = 1 } })
			local seen: { number } = {}
			ds:rerunNext(1)
			ds:UpdateAsync("k", function(stored: any)
				table.insert(seen, stored.n)
				stored.n += 10 -- mutating the copy must not leak into the next run
				return { n = #seen * 100 }
			end)
			assert(#seen == 2 and seen[1] == 1 and seen[2] == 1, "both runs see the stored value")
			assert(ds.records.k.n == 200, "the last run is the one committed")
			-- control: without the re-run the transform runs once
			ds:UpdateAsync("k", function(stored: any)
				return { n = stored.n + 1 }
			end)
			assert(ds.runs == 3 and ds.records.k.n == 201)
		end,
	},
	{
		name = "a write between the read and the write makes the transform run again on the new value",
		run = function()
			local records = {}
			local ds = FakeDataStore.new(records)
			local other = FakeDataStore.new(records) -- a second server on the same store
			ds:hookNext(function()
				other:UpdateAsync("k", function()
					return { n = 5 }
				end)
			end)
			ds:UpdateAsync("k", function(stored: any)
				return { n = (if stored then stored.n else 0) + 1 }
			end)
			assert(records.k.n == 6, `expected the re-run to build on 5, got {records.k.n}`)
			assert(ds.runs == 2, "the first run was thrown away")
		end,
	},
	{
		name = "commit-then-fail writes the result and still throws",
		run = function()
			local ds = FakeDataStore.new({})
			ds:commitThenFailNext(1, "timed out")
			local ok = pcall(function()
				ds:UpdateAsync("k", function()
					return { n = 1 }
				end)
			end)
			assert(ok == false, "the call throws")
			assert(ds.records.k ~= nil and ds.records.k.n == 1, "but the write landed")
			-- control: failNext throws before writing anything
			ds:failNext(1, "throttled")
			pcall(function()
				ds:UpdateAsync("j", function()
					return { n = 1 }
				end)
			end)
			assert(ds.records.j == nil)
		end,
	},
	{
		name = "a nil result cancels the write even when the record changed meanwhile",
		run = function()
			local records = { k = { n = 1 } }
			local ds = FakeDataStore.new(records)
			local other = FakeDataStore.new(records)
			ds:hookNext(function()
				other:UpdateAsync("k", function()
					return { n = 2 }
				end)
			end)
			ds:UpdateAsync("k", function()
				return nil
			end)
			assert(records.k.n == 2 and ds.runs == 1, "cancelled at once, the other write stands")
		end,
	},
}
