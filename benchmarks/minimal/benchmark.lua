package.path = package.path .. ";../?.lua;../../?.lua"

local ref = require("reference")
local utils = require("utils")

local fns = {}

local function get_1(_state)
	return 1
end
fns["get_1"] = get_1

local function print_number(_state, nbr)
	utils.log("  Iterations: " .. nbr)
end
fns["print_number"] = print_number

do
	ref.init({
		get_1 = get_1,
		print_number = print_number,
	})

	local on_inc = ref.on_increment
	utils.benchmark("unsafe lua reference", on_inc)
	ref.on_print()
end

utils.benchmark_interpreter_and_transpiler({
	grug_files = { "mymod/incrementer-Benchmark.grug" },
}, function(state, name)
	utils.register_fns(state, fns)

	utils.log("Compiling grug code...")
	local file = state.mods["mymod"]["incrementer-Benchmark.grug"]
	local e = file:create_entity()

	local on_inc = e.on_increment
	utils.benchmark(name, function()
		on_inc(e)
	end)
	e:on_print()
end)

utils.save_results()
