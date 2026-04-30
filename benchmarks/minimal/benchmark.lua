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

-- ref.init({
-- 	get_1 = get_1,
-- 	print_number = print_number,
-- })

-- local ref_on_inc = ref.on_increment
-- utils.benchmark("lua reference", ref_on_inc)
-- ref.on_print()

local file = state:compile_grug_file("mymod/incrementer-Benchmark.grug")
local e = file:create_entity()

-- This makes its specialization run WAY faster:
-- LuaJIT: 6598194 -> 7020901 iterations
-- Lua 5.5: 3738735 -> 4166545 iterations
local on_inc = e.on_increment

-- TODO: REMOVE!
for i = 1, 83500 do -- TODO: Why does roughly this number of iterations have a 50% chance of slowing down the upcoming compiled chunk by 18 times?
	on_inc(e)
end

-- utils.benchmark("grug interpreter backend", function()
-- 	on_inc(e)
-- end)

-- e:on_print()

--[[ TODO: Make this work:
state.set_backend(transpiler_backend)

local file2 = state:compile_grug_file("mymod/incrementer-Benchmark.grug")
local e2 = file:create_entity()

local on_inc2 = e2.on_increment
]]
--

-- TODO: Replace with real transpilation
local chunk = assert(loadstring([[
	-- These aren't necessary for LuaJIT,
	-- but it speeds up Lua 5.5 by ~11%.
	local get_1
	local print_number

	local fns = {}

	local e = {
		i = 0,
	}

	function fns.on_increment()
		e.i = e.i + get_1()
	end

	function fns.on_print()
		print_number(nil, e.i)
	end

	function fns.init(deps)
		get_1 = deps.get_1
		print_number = deps.print_number
	end

	return fns
]]))()

chunk.init({
	get_1 = get_1,
	print_number = print_number,
})

local chunk_on_inc = chunk.on_increment
utils.benchmark("grug transpiler backend", chunk_on_inc)
chunk.on_print()

utils.save_results()
