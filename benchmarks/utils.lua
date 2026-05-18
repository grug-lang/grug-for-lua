package.path = package.path .. ";../../?.lua"

local grug = require("grug")
local interpreter_backend = require("alternative_backends/interpreter_backend")
local json = require("json")

-- Settings
local path = "results.json"
local measured_seconds = 1
local runs = 10

local utils = {}

local specializations = {}

local clock = os.clock

local selected_specialization = nil
local i = 1
while i <= #arg do
	if arg[i] == "--specialization" then
		selected_specialization = arg[i + 1]

		if not selected_specialization then
			error("Error: Missing value for --specialization")
		end

		break
	end

	i = i + 1
end
if not selected_specialization then
	error("Error: pass --specialization <specialization name>")
end

function utils.log(...)
	print(...)
	io.flush()
end

function utils.register_fns(state, fns)
	for fn_name, fn in pairs(fns) do
		state:register(fn_name, fn)
	end
end

local function get_batch_size(name)
	-- This is used to compare optimal grug to the Lua reference.
	local many = 10000000

	if name == "safe grug transpiler backend" then
		return 100000
	elseif name == "unsafe grug transpiler backend" then
		return many
	elseif name == "safe grug interpreter backend" then
		return 10000
	elseif name == "unsafe grug interpreter backend" then
		return 10000
	elseif name == "unsafe lua reference" then
		return many
	else
		error("Missing an elif")
	end
end

-- Measures execution time of a function
function utils.benchmark(name, fn, entity)
	utils.log("--- Benchmarking " .. name .. " ---")

	local batch_size = get_batch_size(name)
	utils.log("Using fixed batch size: " .. batch_size)

	utils.log("Warming up...")
	local warmup_start = clock()
	for _ = 1, batch_size do fn(entity) end
	local warmup_time = clock() - warmup_start
	utils.log("Warming up took " .. string.format("%.4f", warmup_time) .. "s")

	utils.log("Measuring " .. runs .. " runs of " .. batch_size .. " iterations each...")

	-- 3. Collect a time sample per run, then derive the median.
	local elapsed_times = {}

	for run = 1, runs do
		utils.log("Run " .. run .. "/" .. runs .. "...")

		collectgarbage("collect") -- normalize GC state between runs

		local start = clock()
		for _ = 1, batch_size do
			fn(entity)
		end
		local elapsed = clock() - start

		utils.log("Elapsed: " .. string.format("%.4f", elapsed) .. "s")
		table.insert(elapsed_times, elapsed)
	end

	-- 4. Sort and take the median (robust against lucky/unlucky outliers).
	table.sort(elapsed_times)
	local median_elapsed = elapsed_times[math.ceil(#elapsed_times / 2)]

	-- 5. Compute the coefficient of variation (stddev / mean), so high-noise runs are visible.
	local mean = 0
	for _, t in ipairs(elapsed_times) do
		mean = mean + t
	end
	mean = mean / #elapsed_times

	local variance = 0
	for _, t in ipairs(elapsed_times) do
		variance = variance + (t - mean) ^ 2
	end
	variance = variance / #elapsed_times
	local cv = math.sqrt(variance) / mean * 100

	if cv > 2 then
		utils.log(string.format("  WARNING: high variance (CV=%.1f%%) — results may be unreliable", cv))
	else
		utils.log(string.format("  Variance OK (CV=%.1f%%)", cv))
	end

	table.insert(specializations, {
		name = name,
		elapsed = median_elapsed,
		iterations = batch_size,
		iters_per_sec = batch_size / median_elapsed,
	})

	utils.log("--- Finished benchmarking " .. name .. " ---")
end

local ALL_CONFIGS = {
	{ name = "safe grug transpiler backend" },
	{ name = "unsafe grug transpiler backend", safe_mode = false },
	{ name = "safe grug interpreter backend", backend = interpreter_backend },
	{ name = "unsafe grug interpreter backend", backend = interpreter_backend, safe_mode = false },
}

local function get_config()
	for _, config in ipairs(ALL_CONFIGS) do
		if config.name == selected_specialization then
			return config
		end
	end

	error("Unknown specialization: " .. selected_specialization)
end

function utils.benchmark_interpreter_and_transpiler(grug_settings, benchmark)
	if selected_specialization == "unsafe lua reference" then
		return
	end

	local config = get_config()

	grug_settings.backend = config.backend
	grug_settings.safe_mode = config.safe_mode
	-- grug_settings.transpiler_dump = true -- Use to debug any NYIs
	local state = grug.init(grug_settings)
	benchmark(state, config.name)

	-- Verify the output of the unsafe transpiler matches the native reference implementation
	if config.name == "unsafe grug transpiler backend" then
		local generated_lua = state:get_transpiled_code()

		-- Look for reference.lua in the current directory
		local ref_file = io.open("reference.lua", "r")
		if not ref_file then
			error("Could not find or open reference.lua for verification")
		end
		local reference_content = ref_file:read("*a")
		ref_file:close()

		if generated_lua ~= reference_content then
			local out_file = assert(io.open("transpiler_output.lua", "w"))
			out_file:write(generated_lua)
			out_file:close()
			error(
				"Generated Lua code does not exactly match reference.lua!"
					.. " Saved output to 'transpiler_output.lua' for diffing."
			)
		else
			print("Unsafe grug transpiler backend successfully generated reference.lua.")
		end
	end
end

function utils.should_run_lua_reference()
	return selected_specialization == "unsafe lua reference"
end

function utils.save_results()
	local f = assert(io.open(path, "w"))

	local data = {
		metadata = {
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
