--!strict
local fs = require("@lune/fs")
local process = require("@lune/process")

local passed, failed = 0, 0
local failures = {}

local names = fs.readDir("tests/specs")
table.sort(names)
for _, name in names do
	if string.match(name, "%.luau$") then
		local specs = require("./specs/" .. string.gsub(name, "%.luau$", ""))
		for _, spec in specs do
			local ok, err = pcall(spec.run)
			if ok then
				passed += 1
			else
				failed += 1
				table.insert(failures, `{name} :: {spec.name}\n    {tostring(err)}`)
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
