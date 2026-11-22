--!strict
local roblox = require("@lune/roblox")
local Validate = require("../../src/shared/Validate")

local V3 = roblox.Vector3

return {
	{
		name = "isInteger accepts an in-range integer",
		run = function()
			assert(Validate.isInteger(5, 1, 10) == true)
			assert(Validate.isInteger(1, 1, 10) == true)
			assert(Validate.isInteger(10, 1, 10) == true)
		end,
	},
	{
		name = "isInteger refuses floats, NaN, inf and wrong types",
		run = function()
			assert(Validate.isInteger(2.5, 1, 10) == false)
			assert(Validate.isInteger(0 / 0, 1, 10) == false)
			assert(Validate.isInteger(math.huge, 1, math.huge) == false)
			assert(Validate.isInteger("5", 1, 10) == false)
		end,
	},
	{
		name = "isInteger refuses out-of-range values",
		run = function()
			assert(Validate.isInteger(0, 1, 10) == false)
			assert(Validate.isInteger(11, 1, 10) == false)
		end,
	},
	{
		name = "isString accepts a short string",
		run = function()
			assert(Validate.isString("abc", 3) == true)
			assert(Validate.isString("", 3) == true)
		end,
	},
	{
		name = "isString refuses too long and wrong types",
		run = function()
			assert(Validate.isString("abcd", 3) == false)
			assert(Validate.isString(12, 3) == false)
			assert(Validate.isString(nil, 3) == false)
		end,
	},
	{
		name = "isUnitVector accepts unit vectors",
		run = function()
			assert(Validate.isUnitVector(V3.new(1, 0, 0)) == true)
			assert(Validate.isUnitVector(V3.new(0, 0.6, 0.8)) == true)
		end,
	},
	{
		name = "isUnitVector refuses wrong length",
		run = function()
			assert(Validate.isUnitVector(V3.new(2, 0, 0)) == false)
			assert(Validate.isUnitVector(V3.new(0, 0, 0)) == false)
		end,
	},
	{
		name = "isUnitVector refuses NaN, inf and wrong types",
		run = function()
			assert(Validate.isUnitVector(V3.new(0 / 0, 0, 0)) == false)
			assert(Validate.isUnitVector(V3.new(math.huge, 0, 0)) == false)
			assert(Validate.isUnitVector({ X = 1, Y = 0, Z = 0 }) == false)
			assert(Validate.isUnitVector("up") == false)
		end,
	},
	{
		name = "isOneOf accepts a member of the set",
		run = function()
			assert(Validate.isOneOf("move", { move = true, split = true }) == true)
		end,
	},
	{
		name = "isOneOf refuses non-members and wrong types",
		run = function()
			assert(Validate.isOneOf("steal", { move = true, split = true }) == false)
			assert(Validate.isOneOf(5, { move = true }) == false)
		end,
	},
}
