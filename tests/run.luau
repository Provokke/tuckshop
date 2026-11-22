--!strict
local fs = require("@lune/fs")
local process = require("@lune/process")

local passed, failed = 0, 0
local failures = {}

-- Runs a spec in its own thread. A spec that yields and is never resumed would otherwise stop
-- the runner silently with exit code 0, so that counts as a failure.
local function runSpec(run: () -> ()): (boolean, string)
	local thread = coroutine.create(run)
	local ok, err = coroutine.resume(thread)
	if not ok then
		return false, tostring(err)
	end
	if coroutine.status(thread) ~= "dead" then
		return false, "the test yielded and never finished"
	end
	return true, ""
end

local names = fs.readDir("tests/specs")
table.sort(names)
for _, name in names do
	if string.match(name, "%.luau$") then
		local specs = require("./specs/" .. string.gsub(name, "%.luau$", ""))
		for _, spec in specs do
			local ok, err = runSpec(spec.run)
			if ok then
				passed += 1
			else
				failed += 1
				table.insert(failures, `{name} :: {spec.name}\n    {err}`)
			end
		end
	end
end

print(`{passed} passed, {failed} failed`)
for _, line in failures do
	print("FAILED " .. line)
end
if failed > 0 then
	process.exit(1)
end
