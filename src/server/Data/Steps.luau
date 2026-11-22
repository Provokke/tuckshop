--!strict
-- Schema migration steps. steps[i] takes data saved at schema i and returns it at schema i + 1.
-- Whenever Config.SchemaVersion goes up by one, add the step for the old version here.
-- ConfigCheck refuses to start the server unless there is exactly one step per bump.
--
-- Each step gets its own copy of the data and may change it in place, but it must not yield.
return {} :: { (data: { [string]: any }) -> { [string]: any } }
