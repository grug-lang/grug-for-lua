local json = require("json")

-- CLI Arguments
local batch_size = tonumber(arg[1]) or 1000
local measured_seconds = tonumber(arg[2]) or 10

local utils = {}

local specializations = {}

-- Measures execution time of a function
function utils.benchmark(name, fn)
	print("Benchmarking " .. name .. "...")

	-- 1. Warmup phase: Run for exactly 1.0 second
	-- We use batch_size to avoid calling os.clock() too frequently
	local warmup_iterations = 0
	local warmup_start = os.clock()
	while os.clock() - warmup_start < 1.0 do
		for _ = 1, batch_size do
			fn()
		end
		warmup_iterations = warmup_iterations + batch_size
	end
	local actual_warmup_time = os.clock() - warmup_start

	-- 2. Calculate scaled iterations for the measured phase
	-- iterations = (iters / 1s) * measured_seconds
	local total_measured_iterations = math.floor((warmup_iterations / actual_warmup_time) * measured_seconds)

	-- 3. Actual measurement
	local start = os.clock()
	for _ = 1, total_measured_iterations do
		fn()
	end
	local finish = os.clock()

	local elapsed = finish - start

	table.insert(specializations, {
		name = name,
		elapsed = elapsed,
		iterations = total_measured_iterations,
		iters_per_sec = total_measured_iterations / elapsed,
	})
end

function utils.save_results()
	local path = "results.json"
	local f = assert(io.open(path, "w"))

	local data = {
		metadata = {
			batch_size = batch_size,
			target_duration = measured_seconds,
			lua_version = _VERSION,
			jit = (jit ~= nil),
		},
		specializations = specializations,
	}

	f:write(json.encode(data))
	f:close()

	print("Results saved to " .. path)
end

return utils
