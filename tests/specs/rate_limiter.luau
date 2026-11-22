--!strict
local FakeClock = require("../fakes/FakeClock")
local RateLimiter = require("../../src/shared/RateLimiter")

local function make(capacity: number, refill: number)
	local clock = FakeClock.new(0)
	local limiter = RateLimiter.new(capacity, refill, function()
		return clock:now()
	end)
	return limiter, clock
end

return {
	{
		name = "a full bucket allows exactly capacity takes then refuses",
		run = function()
			local limiter = make(3, 1)
			assert(limiter:take("k") == true)
			assert(limiter:take("k") == true)
			assert(limiter:take("k") == true)
			assert(limiter:take("k") == false, "fourth take should be refused")
			assert(limiter.refused == 1)
		end,
	},
	{
		name = "time refills the bucket",
		run = function()
			local limiter, clock = make(3, 2)
			for _ = 1, 3 do
				limiter:take("k")
			end
			assert(limiter:take("k") == false)
			clock:advance(1)
			assert(limiter:take("k") == true)
			assert(limiter:take("k") == true)
			assert(limiter:take("k") == false)
		end,
	},
	{
		name = "refill never exceeds capacity",
		run = function()
			local limiter, clock = make(3, 2)
			limiter:take("k")
			clock:advance(100)
			assert(limiter:take("k") == true)
			assert(limiter:take("k") == true)
			assert(limiter:take("k") == true)
			assert(limiter:take("k") == false)
		end,
	},
	{
		name = "forget resets one key while another stays drained",
		run = function()
			local limiter = make(2, 1)
			for _ = 1, 2 do
				limiter:take("a")
				limiter:take("b")
			end
			assert(limiter:take("a") == false)
			assert(limiter:take("b") == false)
			limiter:forget("a")
			assert(limiter:take("a") == true)
			assert(limiter:take("b") == false)
		end,
	},
}
