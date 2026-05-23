package.path = package.path .. ";../../?.lua"

local grug = require("grug")
local interpreter_backend = require("alternative_backends/interpreter_backend")
local json = require("json")

-- Settings
local path = "results.json"
local warmup_seconds = 0.1
local measured_seconds = 0.1

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

local function register_fns(state, fns)
	for fn_name, fn in pairs(fns) do
		state:register(fn_name, fn)
	end
end

-- Doubles batch size on every clock() call until a single batch
-- takes at least warmup_seconds. Returns the final batch size and
-- the elapsed time of the last (qualifying) batch.
local function detect_batch_size(fn, entity)
	local batch_size = 1
	while true do
		local start = clock()
		for _ = 1, batch_size do
			fn(entity)
		end
		local elapsed = clock() - start
		if elapsed >= warmup_seconds then
			return batch_size, elapsed
		end
		batch_size = batch_size * 2
	end
end

-- Measures execution time of a function
function utils.benchmark(name, fn, entity)
	utils.log("--- Benchmarking " .. name .. " ---")

	utils.log("Detecting batch size (doubling until one batch >= " .. warmup_seconds .. "s)...")
	local batch_size, actual_warmup_time = detect_batch_size(fn, entity)
	local warmup_iterations = batch_size
	utils.log("Batch size settled at " .. batch_size .. " (took " .. string.format("%.4f", actual_warmup_time) .. "s)")

	local total_measured_iterations = math.floor((warmup_iterations / actual_warmup_time) * measured_seconds)

	utils.log("Measuring " .. total_measured_iterations .. " iterations...")

	local start = clock()
	for _ = 1, total_measured_iterations do
		fn(entity)
	end
	local elapsed = clock() - start

	utils.log("Elapsed: " .. string.format("%.4f", elapsed) .. "s")

	table.insert(specializations, {
		name = name,
		elapsed = elapsed,
		iterations = total_measured_iterations,
		iters_per_sec = total_measured_iterations / elapsed,
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

function utils.benchmark_interpreter_and_transpiler(grug_settings, benchmark, fns)
	if selected_specialization == "unsafe lua reference" or selected_specialization == "safe lua reference" then
		return
	end

	local config = get_config()

	grug_settings.backend = config.backend
	grug_settings.safe_mode = config.safe_mode
	-- grug_settings.transpiler_dump = true -- Use to debug any NYIs
	local state = grug.init(grug_settings)

	register_fns(state, fns)

	benchmark(state, config.name)

	-- Verify the output of the transpiler matches the native reference implementation
	local expected_reference_file = nil
	if config.name == "unsafe grug transpiler backend" then
		expected_reference_file = "reference_unsafe.lua"
	elseif config.name == "safe grug transpiler backend" then
		expected_reference_file = "reference_safe.lua"
	end

	if expected_reference_file then
		local generated_lua = state:get_transpiled_code()

		local ref_file = io.open(expected_reference_file, "r")
		if not ref_file then
			error("Could not find or open " .. expected_reference_file .. " for verification")
		end
		local reference_content = ref_file:read("*a")
		ref_file:close()

		if generated_lua ~= reference_content then
			local out_file = assert(io.open("transpiler_output.lua", "w"))
			out_file:write(generated_lua)
			out_file:close()
			error(
				"Generated Lua code does not exactly match "
					.. expected_reference_file
					.. "!"
					.. " Saved output to 'transpiler_output.lua' for diffing"
			)
		else
			print("Successfully generated matching " .. expected_reference_file)
		end
	end
end

function utils.benchmark_safe_and_unsafe_lua_references(fns, benchmark)
	if selected_specialization == "unsafe lua reference" then
		local ref = require("reference_unsafe")
		ref.init(fns)
		benchmark(ref, "unsafe lua reference")
	elseif selected_specialization == "safe lua reference" then
		local ref = require("reference_safe")
		ref.init(fns)
		benchmark(ref, "safe lua reference")
	end
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
