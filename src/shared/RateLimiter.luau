--!strict
-- Per-key token bucket. Keys are usually a Player's UserId.
local RateLimiter = {}
RateLimiter.__index = RateLimiter

type Bucket = { tokens: number, last: number }

export type RateLimiter = typeof(setmetatable(
	{} :: {
		capacity: number,
		refill: number,
		clock: () -> number,
		buckets: { [any]: Bucket },
		refused: number,
	},
	RateLimiter
))

function RateLimiter.new(capacity: number, refillPerSecond: number, clock: () -> number): RateLimiter
	assert(capacity > 0 and refillPerSecond > 0, "capacity and refill must be positive")
	return setmetatable(
		{ capacity = capacity, refill = refillPerSecond, clock = clock, buckets = {}, refused = 0 },
		RateLimiter
	)
end

function RateLimiter.take(self: RateLimiter, key: any, cost: number?): boolean
	local now = self.clock()
	local amount = cost or 1
	local bucket = self.buckets[key]
	if bucket == nil then
		bucket = { tokens = self.capacity, last = now }
		self.buckets[key] = bucket
	end
	bucket.tokens = math.min(self.capacity, bucket.tokens + (now - bucket.last) * self.refill)
	bucket.last = now
	if bucket.tokens < amount then
		self.refused += 1
		return false
	end
	bucket.tokens -= amount
	return true
end

function RateLimiter.forget(self: RateLimiter, key: any)
	self.buckets[key] = nil
end

return RateLimiter
