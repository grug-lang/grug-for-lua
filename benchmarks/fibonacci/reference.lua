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
