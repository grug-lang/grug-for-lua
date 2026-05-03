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

utils.log("Compiling grug code...")
local file = state.mods["mymod"]["fib-Benchmark.grug"]
local e = file:create_entity()
local on_run = e.on_run

utils.benchmark("grug interpreter backend", function()
	on_run(e)
end)

--[[ TODO: Make this work:
state.set_backend(transpiler_backend)

local file2 = state.mods["mymod"]["fib-Benchmark.grug"]
local e2 = file:create_entity()

local on_inc2 = e2.on_run
]]
--

-- TODO: Replace with real transpilation
local loader = load or loadstring -- Lua 5.1 uses loadstring; 5.2+ uses load
local chunk = assert(loader([[
	local List
	local Dict
	local list_append
	local dict_has_key
	local dict_get
	local dict_set
	local assert_fib

	local fns = {}

	local e = {
		count = 50,
	}

	local function helper_fib(n, memo)
		if dict_has_key(nil, memo, n) then
			return dict_get(nil, memo, n)
		end

		local result = n
		if n > 1 then
			result = helper_fib(n - 1, memo) + helper_fib(n - 2, memo)
		end

		dict_set(nil, memo, n, result)
		return result
	end

	local function helper_fib_list(n)
		local fib_list = List()

		local memo = Dict()

		local i = 0
		while i <= n do
			list_append(nil, fib_list, helper_fib(i, memo))
			i = i + 1
		end

		return fib_list
	end

	function fns.on_run()
		local fib_numbers = helper_fib_list(e.count)
		assert_fib(nil, fib_numbers)
	end

	function fns.init(deps)
		List = deps.List
		Dict = deps.Dict
		list_append = deps.list_append
		dict_has_key = deps.dict_has_key
		dict_get = deps.dict_get
		dict_set = deps.dict_set
		assert_fib = deps.assert_fib
	end

	return fns
]]))()

chunk.init({
	List = List,
	Dict = Dict,
	list_append = list_append,
	dict_has_key = dict_has_key,
	dict_get = dict_get,
	dict_set = dict_set,
	assert_fib = assert_fib,
})

local chunk_on_run = chunk.on_run
utils.benchmark("grug transpiler backend", chunk_on_run)

utils.save_results()
