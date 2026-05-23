local _clock = os.clock
local _start_time = 0
local _time_limit_sec = 0

local get_1
local print_number

local fns = {}

local e = {
	me = nil,
	i = nil,
}

function fns.on_increment()
	e.i = (e.i + get_1(nil))
end

function fns.on_print()
	print_number(nil, e.i)
end

function fns.init(deps, me_id)
	get_1 = deps.get_1
	print_number = deps.print_number
	_time_limit_sec = deps._time_limit_sec
	e.me = { __grug_type = "id", value = me_id }
	e.i = 0
end

return fns
