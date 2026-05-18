package.path = package.path .. ";../?.lua"

local utils = require("../utils")

local fns = {}

local function List(_state)
	return {}
end
fns["List"] = List

local function Dict(_state)
	return {}
end
fns["Dict"] = Dict

local function list_append(_state, list, val)
	table.insert(list, val)
end
fns["list_append"] = list_append

local function dict_has_key(_state, dict, key)
	return dict[key] ~= nil
end
fns["dict_has_key"] = dict_has_key

local function dict_get(_state, dict, key)
	return dict[key]
end
fns["dict_get"] = dict_get

local function dict_set(_state, dict, key, val)
	dict[key] = val
end
fns["dict_set"] = dict_set

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
fns["assert_fib"] = assert_fib

local function benchmark(state, name)
	utils.register_fns(state, fns)

	utils.log("Compiling grug code...")
	local file = state.mods["mymod"]["fib-Benchmark.grug"]
	local e = file:create_entity()

	local on_run = e.on_run
	utils.benchmark(name, on_run, e)
end

utils.benchmark_interpreter_and_transpiler({
	grug_files = { "mymod/fib-Benchmark.grug" },
}, benchmark)

if utils.should_run_lua_reference() then
	local ref = require("reference")

	ref.init({
		List = List,
		Dict = Dict,
		list_append = list_append,
		dict_has_key = dict_has_key,
		dict_get = dict_get,
		dict_set = dict_set,
		assert_fib = assert_fib,
	})

	local on_run = ref.on_run
	utils.benchmark("unsafe lua reference", on_run)
end

utils.save_results()
