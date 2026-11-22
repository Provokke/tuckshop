--!strict
local FakeClock = {}
FakeClock.__index = FakeClock

export type FakeClock = typeof(setmetatable({} :: { t: number }, FakeClock))

function FakeClock.new(start: number?): FakeClock
	return setmetatable({ t = start or 0 }, FakeClock)
end

function FakeClock.now(self: FakeClock): number
	return self.t
end

function FakeClock.advance(self: FakeClock, seconds: number)
	self.t += seconds
end

return FakeClock
