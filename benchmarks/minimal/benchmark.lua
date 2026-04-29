package.path = package.path .. ";../?.lua;../../?.lua"

local utils = require("utils")
local grug = require("grug")
local ref = require("reference")

local state = grug.init()

local function get_1(_state)
	return 1
end
state:register("get_1", get_1)

local function print_number(_state, nbr)
	print("  Iterations: " .. nbr)
end
state:register("print_number", print_number)

ref.init({
	get_1 = get_1,
	print_number = print_number,
})

local ref_on_inc = ref.on_increment
utils.benchmark("lua reference", ref_on_inc)
ref.on_print()

local file = state:compile_grug_file("mymod/incrementer-Benchmark.grug")
local e = file:create_entity()

-- This makes its specialization run WAY faster:
-- LuaJIT: 6598194 -> 7020901 iterations
-- Lua 5.5: 3738735 -> 4166545 iterations
local on_inc = e.on_increment

utils.benchmark("grug interpreter backend", function()
	on_inc(e)
end)

e:on_print()

utils.save_results()
