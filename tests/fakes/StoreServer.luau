--!strict
-- Builds one "server": a Store over a FakeDataStore that shares `records` with any other server
-- built on the same table. Each load gets the next nonce ("1", "2", ...), so a session's lease
-- owner reads "<jobId>:<n>".
local FakeDataStore = require("./FakeDataStore")
local Lease = require("../../src/server/Data/Lease")
local Migrations = require("../../src/server/Data/Migrations")
local Store = require("../../src/server/Data/Store")

local StoreServer = {}

function StoreServer.defaultData(): { [string]: any }
	return { gold = 0, wallet = { balances = {}, log = {} }, bought = {}, receipts = {} }
end

-- Resumes a thread that was queued behind another session call, and lets its errors through.
function StoreServer.resume(thread: thread)
	local ok, err = coroutine.resume(thread)
	if not ok then
		error(err, 0)
	end
end

function StoreServer.new(records: any, clock: any, jobId: string, overrides: { [string]: any }?)
	local ds = FakeDataStore.new(records)
	local waits: { number } = {}
	local logs: { string } = {}
	local nonces = 0
	local deps: any = {
		dataStore = ds,
		lease = Lease,
		migrations = Migrations,
		clock = function()
			return clock:now()
		end,
		wait = function(seconds: number)
			table.insert(waits, seconds)
		end,
		budget = function(_kind: string)
			return 100
		end,
		jobId = jobId,
		nonce = function()
			nonces += 1
			return tostring(nonces)
		end,
		resume = StoreServer.resume,
		leaseSeconds = 180,
		retries = 3,
		retryBase = 1,
		schema = 1,
		steps = {},
		defaultData = StoreServer.defaultData,
		log = function(message: string)
			table.insert(logs, message)
		end,
	}
	if overrides then
		for k, v in overrides do
			deps[k] = v
		end
	end
	return Store.new(deps), ds, waits, logs, deps
end

return StoreServer
