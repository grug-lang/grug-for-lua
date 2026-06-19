local utils = dofile("../utils.lua")

local fns = {}

local function get_1(_state)
	return 1
end
fns["get_1"] = get_1

local function print_number(_state, nbr)
	utils.log("  Iterations: " .. nbr)
end
fns["print_number"] = print_number

local function benchmark(state, name)
	utils.log("Compiling grug code...")
	local file = state.mods["mymod"]["incrementer-Benchmark.grug"]
	local e = file:create_entity()

	local inc = e.increment
	utils.benchmark(name, inc, e)
	e:print()
end

utils.benchmark_interpreter_and_transpiler({
	grug_files = { "mymod/incrementer-Benchmark.grug" },
}, benchmark, fns)

local function benchmark_ref(ref, name)
	local inc = ref.increment
	utils.benchmark(name, inc)
	ref.print()
end

utils.benchmark_safe_and_unsafe_lua_references(fns, benchmark_ref)

utils.save_results()
