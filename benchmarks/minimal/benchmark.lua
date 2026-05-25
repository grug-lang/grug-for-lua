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

	local on_inc = e.on_increment
	utils.benchmark(name, on_inc, e)
	e:on_print()
end

utils.benchmark_interpreter_and_transpiler({
	grug_files = { "mymod/incrementer-Benchmark.grug" },
}, benchmark, fns)

local function benchmark_ref(ref, name)
	local on_inc = ref.on_increment
	utils.benchmark(name, on_inc)
	ref.on_print()
end

utils.benchmark_safe_and_unsafe_lua_references(fns, benchmark_ref)

utils.save_results()
