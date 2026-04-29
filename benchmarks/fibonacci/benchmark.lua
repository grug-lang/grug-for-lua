package.path = package.path .. ";../?.lua;../../?.lua"

local utils = require("utils")
local grug = require("grug")

local state = grug.init()

state:register("List", function(_)
	return {}
end)
state:register("Dict", function(_)
	return {}
end)

state:register("list_append", function(_, list, val)
	table.insert(list, val)
end)

state:register("dict_has_key", function(_, dict, key)
	return dict[key] ~= nil
end)

state:register("dict_get", function(_, dict, key)
	return dict[key]
end)

state:register("dict_set", function(_, dict, key, val)
	dict[key] = val
end)

local function assert_fib(list)
	if #list ~= 51 then
		io.stderr:write("ERROR: generated Fibonacci sequence is incorrect\n")
		io.stderr:write("  Expected #list to be 51, got " .. #list .. "\n")
		os.exit(1)
	end
	local expected = 12586269025
	if list[51] ~= expected then
		io.stderr:write("ERROR: generated Fibonacci sequence is incorrect\n")
		io.stderr:write("  Expected list[51] to be " .. expected .. ", got " .. list[51] .. "\n")
		os.exit(1)
	end
end

state:register("assert_fib", function(_, list)
	assert_fib(list)
end)

local file = state:compile_grug_file("mymod/fib-Benchmark.grug")
local e = file:create_entity()
local on_run = e.on_run

local function lua_helper_fib(n, memo)
	if memo[n] then
		return memo[n]
	end

	local result = n
	if n > 1 then
		result = lua_helper_fib(n - 1, memo) + lua_helper_fib(n - 2, memo)
	end

	memo[n] = result
	return result
end

local function lua_helper_fib_list(n)
	local fib_list = {}

	local memo = {}

	for i = 0, n do
		table.insert(fib_list, lua_helper_fib(i, memo))
	end

	return fib_list
end

local lua_entity = { count = 50 }
local function lua_reference()
	local fib_numbers = lua_helper_fib_list(lua_entity.count)
	assert_fib(fib_numbers)
end

utils.benchmark("lua reference", lua_reference)
utils.benchmark("grug interpreter backend", function()
	on_run(e)
end)

utils.save_results()
