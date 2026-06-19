local get_1
local print_number

local fns = {}

local e = {
	state = nil,
	me = nil,
	i = nil,
}

function fns.increment()
	e.i = (e.i + get_1(e.state))
end

function fns.print()
	print_number(e.state, e.i)
end

function fns.init(deps, state, me_id)
	get_1 = deps.get_1
	print_number = deps.print_number
	e.state = state
	e.me = { __grug_type = "id", value = me_id }
	e.i = 0
end

return fns
