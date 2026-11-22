--!strict
-- Saves racing each other and the release. Each "thread" is a coroutine; the fake's hook parks a
-- call between its read and its write, so the tests can run other calls in that window.
local Deep = require("../fakes/Deep")
local FakeClock = require("../fakes/FakeClock")
local StoreServer = require("../fakes/StoreServer")

-- encode copies, as the shipped encode does, so a payload never aliases the live session data.
local function server(records: any, clock: any, jobId: string, overrides: { [string]: any }?)
	local all: { [string]: any } = {
		encode = function(data: any)
			return Deep.copy(data)
		end,
		decode = function(saved: any)
			return Deep.copy(saved)
		end,
	}
	for k, v in overrides or {} do
		all[k] = v
	end
	return StoreServer.new(records, clock, jobId, all)
end

-- Starts fn in its own coroutine and runs it until it first yields or returns.
local function start(fn: () -> ()): thread
	local thread = coroutine.create(fn)
	StoreServer.resume(thread)
	return thread
end

local function parkNextCall(ds: any)
	ds:hookNext(function()
		coroutine.yield()
	end)
end

return {
	{
		name = "an autosave parked mid-call can't land after a newer save",
		run = function()
			local records = {}
			local store, ds = server(records, FakeClock.new(0), "JOB")
			local session = store:load("p1")
			assert(session ~= nil)
			parkNextCall(ds)
			local autosave = start(function()
				session:save()
			end)
			-- A trade commits while the autosave is in flight, and its save is asked for.
			session.data.gold = 1
			local tradeSaved: boolean? = nil
			start(function()
				tradeSaved = session:save()
			end)
			assert(ds.calls == 2, `the trade save must queue behind the autosave, calls={ds.calls}`)
			StoreServer.resume(autosave)
			assert(tradeSaved == true, "the queued save ran once the autosave finished")
			assert(ds.calls == 3)
			assert(records.p1.data.gold == 1, `stored gold should be 1, got {records.p1.data.gold}`)
		end,
	},
	{
		name = "a save that waited for budget writes the data as it is after the wait",
		run = function()
			local records = {}
			local parked = false
			local store, _ds = server(records, FakeClock.new(0), "JOB", {
				budget = function(_kind: string)
					if parked then
						parked = false
						coroutine.yield() -- the server is busy: this call waits for budget
					end
					return 100
				end,
			})
			local session = store:load("p1")
			assert(session ~= nil)
			parked = true
			local autosave = start(function()
				session:save()
			end)
			session.data.gold = 1
			start(function()
				session:save()
			end)
			StoreServer.resume(autosave)
			assert(records.p1.data.gold == 1, `stored gold should be 1, got {records.p1.data.gold}`)
			-- control: the session itself still says 1, so the store matches memory
			assert(session.data.gold == 1)
		end,
	},
	{
		name = "a re-run of the save transform writes the session as it is at the re-run",
		run = function()
			local records = {}
			local store, ds = server(records, FakeClock.new(0), "JOB")
			local session = store:load("p1")
			assert(session ~= nil)
			ds:rerunNext(1)
			ds:hookNext(function()
				session.data.gold = 2 -- changed while the first run's write was in flight
			end)
			assert(session:save() == true)
			assert(ds.runs == 3, "load once, save twice")
			assert(records.p1.data.gold == 2, `stored gold should be 2, got {records.p1.data.gold}`)
		end,
	},
	{
		name = "a release queued behind a save runs after it, and a later save writes nothing",
		run = function()
			local records = {}
			local store, ds = server(records, FakeClock.new(0), "JOB")
			local session = store:load("p1")
			assert(session ~= nil)
			parkNextCall(ds)
			local autosave = start(function()
				session:save()
			end)
			session.data.gold = 3
			local released: boolean? = nil
			start(function()
				released = session:release()
			end)
			local lateSave: boolean? = nil
			start(function()
				lateSave = session:save()
			end)
			StoreServer.resume(autosave)
			assert(released == true, "the release landed")
			assert(lateSave == false, "nothing is saved after the release")
			assert(session.lost == false, "a save after the release is not a lost lease")
			assert(ds.calls == 3, `load, save, release only, calls={ds.calls}`)
			assert(records.p1.lease == nil and records.p1.data.gold == 3)
		end,
	},
	{
		name = "every transform writes the same record when UpdateAsync runs it twice",
		run = function()
			local function play(rerun: boolean): any
				local records = {}
				local store, ds = server(records, FakeClock.new(0), "JOB")
				if rerun then
					ds:rerunNext(100)
				end
				local session = store:load("p1")
				assert(session ~= nil)
				session.data.gold = 4
				assert(session:save() == true)
				session.data.gold = 5
				assert(session:release() == true)
				local again = store:load("p1")
				assert(again ~= nil)
				return records
			end
			local once, twice = play(false), play(true)
			assert(Deep.equal(once, twice), "a re-run must not change what is stored")
			assert(twice.p1.data.gold == 5)
		end,
	},
}
