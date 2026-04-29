package.path = package.path .. ";../?.lua;../../?.lua"

local utils = require("utils")
local grug = require("grug")

local state = grug.init()

state:register("get_1", function(_state)
	return 1
end)

state:register("print_number", function(_state, nbr)
	print(nbr)
end)

local file = state:compile_grug_file("mymod/incrementer-Benchmark.grug")
local e = file:create_entity()

local lua_entity = { i = 0 }
local function lua_reference()
	lua_entity.i = lua_entity.i + 1
end

utils.benchmark("Lua reference", lua_reference)
print(lua_entity.i)

-- This makes its specialization run WAY faster:
-- PUC Lua: 3738735 -> 4166545 iterations
-- LuaJIT: 6598194 -> 7020901 iterations
local on_inc = e.on_increment

utils.benchmark("grug interpreter backend", function()
	on_inc(e)
end)
e:on_print()

utils.save_results()
