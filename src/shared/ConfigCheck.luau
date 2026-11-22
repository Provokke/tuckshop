--!strict
-- Start-up sanity checks for Config and the migration steps. Returns a list of problems, empty
-- when everything is fine.
local ConfigCheck = {}

local function isWhole(v: any, min: number): boolean
	return type(v) == "number" and v >= min and v % 1 == 0 and v < math.huge
end

function ConfigCheck.check(config: any, steps: { any }): { string }
	local problems: { string } = {}
	local function add(message: string)
		table.insert(problems, message)
	end

	local schema = config.SchemaVersion
	if type(schema) ~= "number" or schema < 1 or schema % 1 ~= 0 then
		add("SchemaVersion must be a whole number of 1 or more")
	else
		-- A missing step only shows up when an old record loads, so catch it at start-up instead.
		local count = 0
		for _ in steps do
			count += 1
		end
		local allFunctions = true
		for i = 1, schema - 1 do
			if type(steps[i]) ~= "function" then
				allFunctions = false
			end
		end
		if count ~= schema - 1 or not allFunctions then
			add(`SchemaVersion {schema} needs exactly {schema - 1} migration step(s), one per bump`)
		end
	end

	if config.LeaseSeconds < 2 * config.AutosaveSeconds then
		add("LeaseSeconds must be at least twice AutosaveSeconds")
	end
	if config.LoadRetries < 1 then
		add("LoadRetries must be at least 1")
	end
	if config.CloseTimeoutSeconds > 28 then
		add("CloseTimeoutSeconds must be 28 or less, BindToClose only gets about 30 seconds")
	end
	if not isWhole(config.LogLength, 1) then
		add("LogLength must be a whole number of 1 or more")
	end
	if not isWhole(config.ReceiptMemory, 50) then
		add("ReceiptMemory must be a whole number of 50 or more")
	end

	-- Pool sizes, counted from the catalogue.
	local poolSize: { [string]: number } = {}
	for id, item in config.Catalogue do
		if config.Currencies[item.currency] == nil then
			add(`item {id}: unknown currency "{tostring(item.currency)}"`)
		end
		if not isWhole(item.price, 1) then
			add(`item {id}: price must be a whole number of 1 or more`)
		end
		if item.limitPerWindow ~= nil and not isWhole(item.limitPerWindow, 1) then
			add(`item {id}: limitPerWindow must be a whole number of 1 or more`)
		end
		if item.pool ~= nil then
			poolSize[item.pool] = (poolSize[item.pool] or 0) + 1
			if config.Rotation.Pools[item.pool] == nil then
				add(`item {id}: pool "{tostring(item.pool)}" has no slot count in Rotation.Pools`)
			end
		elseif item.always ~= true then
			add(`item {id}: needs a pool or always = true, or it is never listed`)
		end
	end
	for pool, slots in config.Rotation.Pools do
		if not isWhole(slots, 0) then
			add(`Rotation.Pools.{pool} must be a whole number`)
		elseif slots > (poolSize[pool] or 0) then
			add(`Rotation.Pools.{pool} lists {slots} but the pool only has {poolSize[pool] or 0}`)
		end
	end
	if not isWhole(config.Rotation.WindowSeconds, 1) then
		add("Rotation.WindowSeconds must be a whole number of 1 or more")
	end

	for id, product in config.Products do
		if config.Currencies[product.grant] == nil then
			add(`product {id}: unknown currency "{tostring(product.grant)}"`)
		end
		if not isWhole(product.amount, 1) then
			add(`product {id}: amount must be a whole number of 1 or more`)
		end
	end

	return problems
end

return ConfigCheck
