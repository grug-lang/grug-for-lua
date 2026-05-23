package.path = package.path .. ";../?.lua"

local utils = require("../utils")

local fns = {}

local function is_odd(_state, n)
	return n % 2 ~= 0
end
fns["is_odd"] = is_odd

local function assert_equals(_state, actual, expected)
	if actual ~= expected then
		io.stderr:write("ERROR: assertion failed\n")
		io.stderr:write("  Expected " .. expected .. ", got " .. actual .. "\n")
		os.exit(1)
	end
end
fns["assert_equals"] = assert_equals

local function benchmark(state, name)
	utils.register_fns(state, fns)

	utils.log("Compiling grug code...")
	local file = state.mods["mymod"]["break_continue-Benchmark.grug"]
	local e = file:create_entity()

	local on_run = e.on_run
	utils.benchmark(name, on_run, e)
end

utils.benchmark_interpreter_and_transpiler({
	grug_files = { "mymod/break_continue-Benchmark.grug" },
}, benchmark)

if utils.should_run_lua_reference() then
	local ref = require("reference")

	ref.init({
		is_odd = is_odd,
		assert_equals = assert_equals,
	})

	local on_run = ref.on_run
	utils.benchmark("unsafe lua reference", on_run)
end

utils.save_results()
