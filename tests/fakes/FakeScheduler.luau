--!strict
-- A small cooperative scheduler over a FakeClock, standing in for task.spawn and task.wait.
-- spawn runs a function (or resumes a thread) straight away, as task.spawn does. wait parks the
-- running thread until the clock reaches its wake time. advance moves the clock forward and
-- wakes parked threads in time order. An error in any thread is raised in the test.
local FakeScheduler = {}
FakeScheduler.__index = FakeScheduler

type Sleeper = { thread: thread, at: number }

export type FakeScheduler = typeof(setmetatable({} :: { clock: any, sleeping: { Sleeper } }, FakeScheduler))

function FakeScheduler.new(clock: any): FakeScheduler
	return setmetatable({ clock = clock, sleeping = {} }, FakeScheduler)
end

local function resume(thread: thread)
	local ok, err = coroutine.resume(thread)
	if not ok then
		error(err, 0)
	end
end

function FakeScheduler.spawn(_self: FakeScheduler, fn: (() -> ()) | thread)
	if type(fn) == "thread" then
		resume(fn)
	else
		resume(coroutine.create(fn))
	end
end

function FakeScheduler.wait(self: FakeScheduler, seconds: number)
	table.insert(self.sleeping, { thread = coroutine.running(), at = self.clock:now() + seconds })
	coroutine.yield()
end

function FakeScheduler.advance(self: FakeScheduler, seconds: number)
	local target = self.clock:now() + seconds
	while true do
		local soonest: number? = nil
		for i, sleeper in self.sleeping do
			if sleeper.at <= target and (soonest == nil or sleeper.at < self.sleeping[soonest].at) then
				soonest = i
			end
		end
		if soonest == nil then
			break
		end
		local sleeper = table.remove(self.sleeping, soonest)
		if sleeper.at > self.clock:now() then
			self.clock:advance(sleeper.at - self.clock:now())
		end
		resume(sleeper.thread)
	end
	self.clock:advance(target - self.clock:now())
end

return FakeScheduler
