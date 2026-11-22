--!strict
-- Deep copy and deep equality for test snapshots.
local Deep = {}

function Deep.copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[Deep.copy(k)] = Deep.copy(v)
	end
	return out
end

function Deep.equal(a: any, b: any): boolean
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end
	for k, v in a do
		if not Deep.equal(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

return Deep
