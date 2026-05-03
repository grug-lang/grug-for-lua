local json = require("json")

-- CLI Arguments
local path = arg[1] or "results.json"
local batch_size = tonumber(arg[2]) or 1000
local measured_seconds = tonumber(arg[3]) or 10

local utils = {}

local specializations = {}

local clock = os.clock

function utils.log(...)
	print(...)
	io.flush()
end

-- Measures execution time of a function
function utils.benchmark(name, fn)
	utils.log("Benchmarking " .. name .. "...")

	utils.log("Warming up...")

	-- 1. Warmup phase: Run for exactly 1.0 second
	-- We use batch_size to avoid calling clock() too frequently
	local warmup_iterations = 0
	local warmup_start = clock()
	while clock() - warmup_start < 1.0 do
		for _ = 1, batch_size do
			fn()
		end
		warmup_iterations = warmup_iterations + batch_size
	end
	local actual_warmup_time = clock() - warmup_start

	-- 2. Calculate scaled iterations for the measured phase
	-- iterations = (iters / 1s) * measured_seconds
	local total_measured_iterations = math.floor((warmup_iterations / actual_warmup_time) * measured_seconds)

	utils.log("Measuring...")

	-- 3. Actual measurement
	local start = clock()
	for _ = 1, total_measured_iterations do
		fn()
	end
	local finish = clock()

	local elapsed = finish - start

	table.insert(specializations, {
		name = name,
		elapsed = elapsed,
		iterations = total_measured_iterations,
		iters_per_sec = total_measured_iterations / elapsed,
	})
end

function utils.save_results()
	local f = assert(io.open(path, "w"))

	local data = {
		metadata = {
			batch_size = batch_size,
			target_duration = measured_seconds,
			lua_version = _VERSION,
			jit_version = jit and jit.version,
		},
		specializations = specializations,
	}

	f:write(json.encode(data))
	f:close()

	utils.log("Results saved to " .. path .. "\n")
end

return utils
