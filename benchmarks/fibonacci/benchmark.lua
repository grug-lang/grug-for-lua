package.path = package.path .. ";../?.lua;../../?.lua"

local utils = require("utils")
local grug = require("grug")
local ref = require("reference")

local state = grug.init({
	grug_files = { "mymod/fib-Benchmark.grug" },
})

local function List(_state)
	return {}
end
state:register("List", List)

local function Dict(_state)
	return {}
end
state:register("Dict", Dict)

local function list_append(_state, list, val)
	table.insert(list, val)
end
state:register("list_append", list_append)

local function dict_has_key(_state, dict, key)
	return dict[key] ~= nil
end
state:register("dict_has_key", dict_has_key)

local function dict_get(_state, dict, key)
	return dict[key]
end
state:register("dict_get", dict_get)

local function dict_set(_state, dict, key, val)
	dict[key] = val
end
state:register("dict_set", dict_set)

local function assert_fib_list(list)
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

local function assert_fib(_, list)
	assert_fib_list(list)
end
state:register("assert_fib", assert_fib)

ref.init({
	List = List,
	Dict = Dict,
	list_append = list_append,
	dict_has_key = dict_has_key,
	dict_get = dict_get,
	dict_set = dict_set,
	assert_fib = assert_fib,
})

local ref_on_run = ref.on_run
utils.benchmark("lua reference", ref_on_run)

print("Compiling grug code...")
io.flush()
local file = state.mods["mymod"]["fib-Benchmark.grug"]
local e = file:create_entity()
local on_run = e.on_run

utils.benchmark("grug interpreter backend", function()
	on_run(e)
end)

utils.save_results()

-- TODO: Benchmark grug transpiler backend
