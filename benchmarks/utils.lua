package.path = package.path .. ";../../?.lua"

local grug = require("grug")
local interpreter_backend = require("alternative_backends/interpreter_backend")
local json = require("json")

-- CLI Arguments
local path = arg[1] or "results.json"
local batch_size = tonumber(arg[2]) or 1000
local warmup_seconds = tonumber(arg[3]) or 1
local measured_seconds = tonumber(arg[4]) or 1
local runs = tonumber(arg[5]) or 10

local utils = {}

local specializations = {}

local clock = os.clock

function utils.log(...)
	print(...)
	io.flush()
end

function utils.register_fns(state, fns)
	for fn_name, fn in pairs(fns) do
		state:register(fn_name, fn)
	end
end

-- Measures execution time of a function
function utils.benchmark(name, fn, entity)
	utils.log("--- Benchmarking " .. name .. " ---")

	utils.log("Warming up...")

	-- 1. Warmup phase
	-- We use batch_size to avoid calling clock() too frequently
	local warmup_iterations = 0
	local warmup_start = clock()
	while clock() - warmup_start < warmup_seconds do
		for _ = 1, batch_size do
			fn(entity)
		end
		warmup_iterations = warmup_iterations + batch_size
	end
	local actual_warmup_time = clock() - warmup_start

	-- 2. Calculate scaled iterations for the measured phase
	-- iterations = (iters / 1s) * measured_seconds
	local total_measured_iterations = math.floor((warmup_iterations / actual_warmup_time) * measured_seconds)

	utils.log("Measuring...")

	-- 3. Actual measurement (repeat multiple times, keep fastest)
	local best_elapsed = math.huge

	for run = 1, runs do
		utils.log("Run " .. run .. "/" .. runs .. "...")

		local start = clock()

		for _ = 1, total_measured_iterations do
			fn(entity)
		end

		local elapsed = clock() - start

		utils.log("Elapsed: " .. elapsed .. " seconds")

		if elapsed < best_elapsed then
			best_elapsed = elapsed
		end
	end

	local elapsed = best_elapsed

	table.insert(specializations, {
		name = name,
		elapsed = elapsed,
		iterations = total_measured_iterations,
		iters_per_sec = total_measured_iterations / elapsed,
	})

	utils.log("--- Finished benchmarking " .. name .. " ---")
end

local configs = {
	{ name = "safe grug transpiler backend" },
	{ name = "unsafe grug transpiler backend", safe_mode = false },
	{ name = "safe grug interpreter backend", backend = interpreter_backend },
	{ name = "unsafe grug interpreter backend", backend = interpreter_backend, safe_mode = false },
}

function utils.benchmark_interpreter_and_transpiler(grug_settings, benchmark)
	for _, config in ipairs(configs) do
		grug_settings.backend = config.backend
		grug_settings.safe_mode = config.safe_mode
		-- grug_settings.transpiler_dump = true -- Use to debug any NYIs
		local state = grug.init(grug_settings)
		benchmark(state, config.name)
	end
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
