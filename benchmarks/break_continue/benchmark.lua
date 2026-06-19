local utils = dofile("../utils.lua")

local fns = {}

local function is_odd(_state, n)
	return n % 2 ~= 0
end
fns["is_odd"] = is_odd

local function assert_equals(_state, actual, expected)
	if actual ~= expected then
		print("ERROR: assertion failed\n")
		print("  Expected " .. expected .. ", got " .. actual .. "\n")
		os.exit(1)
	end
end
fns["assert_equals"] = assert_equals

local function benchmark(state, name)
	utils.log("Compiling grug code...")
	local file = state.mods["mymod"]["break_continue-Benchmark.grug"]
	local e = file:create_entity()

	local run = e.run
	utils.benchmark(name, run, e)
end

utils.benchmark_interpreter_and_transpiler({
	grug_files = { "mymod/break_continue-Benchmark.grug" },
}, benchmark, fns)

local function benchmark_ref(ref, name)
	local run = ref.run
	utils.benchmark(name, run)
end

utils.benchmark_safe_and_unsafe_lua_references(fns, benchmark_ref)

utils.save_results()
