--!strict
-- Argument checks for remote handlers. Every function takes `any` and answers true or false.
local Validate = {}

local function isFiniteNumber(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

function Validate.isInteger(v: any, min: number, max: number): boolean
	if not isFiniteNumber(v) then
		return false
	end
	return v % 1 == 0 and v >= min and v <= max
end

function Validate.isString(v: any, maxLen: number): boolean
	return type(v) == "string" and #v <= maxLen
end

function Validate.isUnitVector(v: any): boolean
	if typeof(v) ~= "Vector3" then
		return false
	end
	local x, y, z = v.X, v.Y, v.Z
	if not (isFiniteNumber(x) and isFiniteNumber(y) and isFiniteNumber(z)) then
		return false
	end
	local magnitude = math.sqrt(x * x + y * y + z * z)
	return magnitude >= 0.999 and magnitude <= 1.001
end

function Validate.isOneOf(v: any, set: { [string]: any }): boolean
	return type(v) == "string" and set[v] ~= nil
end

return Validate
