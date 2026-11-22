--!strict
-- Schema upgrades. steps[i] turns schema i into schema i + 1.
local Migrations = {}

type Record = { schema: number, data: { [string]: any }, lease: any?, savedAt: number }

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

-- Returns the migrated data and readOnly. A record saved by a newer version of the game is
-- handed back untouched and read-only, so an old server never overwrites data it can't read.
function Migrations.run(
	record: Record,
	steps: { (data: { [string]: any }) -> { [string]: any } },
	current: number
): ({ [string]: any }, boolean)
	local data = deepCopy(record.data)
	if record.schema > current then
		return data, true
	end
	for version = math.max(record.schema, 1), current - 1 do
		local step = steps[version]
		if step == nil then
			error(`no migration step from schema {version} to {version + 1}`)
		end
		data = step(data)
	end
	return data, false
end

return Migrations
