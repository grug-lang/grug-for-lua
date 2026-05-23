local Dict
local List
local assert_fib
local dict_get
local dict_has_key
local dict_set
local list_append

local fns = {}

local e = {
	state = nil,
	me = nil,
	count = nil,
}

function fns.helper_fib(n, memo)
	if dict_has_key(e.state, memo, n) then
		do return dict_get(e.state, memo, n) end
	end
	local result = n
	if (n > 1) then
		result = (fns.helper_fib((n - 1), memo) + fns.helper_fib((n - 2), memo))
	end
	dict_set(e.state, memo, n, result)
	do return result end
end

function fns.helper_fib_list(n)
	local fib_list = List(e.state)
	local memo = Dict(e.state)
	local i = 0
	while (i <= n) do
		local _brk = false
		repeat
			list_append(e.state, fib_list, fns.helper_fib(i, memo))
			i = (i + 1)
		until true
		if _brk then break end
	end
	do return fib_list end
end

function fns.on_run()
	local fib_numbers = fns.helper_fib_list(e.count)
	assert_fib(e.state, fib_numbers)
end

function fns.init(deps, state, me_id)
	Dict = deps.Dict
	List = deps.List
	assert_fib = deps.assert_fib
	dict_get = deps.dict_get
	dict_has_key = deps.dict_has_key
	dict_set = deps.dict_set
	list_append = deps.list_append
	e.state = state
	e.me = { __grug_type = "id", value = me_id }
	e.count = 50
end

return fns
