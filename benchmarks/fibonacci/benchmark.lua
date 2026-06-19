local utils = dofile("../utils.lua")

local fns = {}

local function List(_state)
	return {}
end
fns["List"] = List

local function Dict(_state)
	return {}
end
fns["Dict"] = Dict

local function push(t, value)
	t[#t + 1] = value
end

local function list_append(_state, list, val)
	push(list, val)
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
		print("ERROR: generated Fibonacci sequence is incorrect\n")
		print("  Expected #list to be 51, got " .. #list .. "\n")
		os.exit(1)
	end

	local expected = 12586269025
	if list[51] ~= expected then
		print("ERROR: generated Fibonacci sequence is incorrect\n")
		print("  Expected list[51] to be " .. expected .. ", got " .. list[51] .. "\n")
		os.exit(1)
	end
end

local function assert_fib(_, list)
	assert_fib_list(list)
end
fns["assert_fib"] = assert_fib

local function benchmark(state, name)
	utils.log("Compiling grug code...")
	local file = state.mods["mymod"]["fib-Benchmark.grug"]
	local e = file:create_entity()

	local run = e.run
	utils.benchmark(name, run, e)
end

utils.benchmark_interpreter_and_transpiler({
	grug_files = { "mymod/fib-Benchmark.grug" },
}, benchmark, fns)

local function benchmark_ref(ref, name)
	local run = ref.run
	utils.benchmark(name, run)
end

utils.benchmark_safe_and_unsafe_lua_references(fns, benchmark_ref)

utils.save_results()
