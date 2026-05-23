local _clock = os.clock
local _start_time = 0
local _time_limit_sec = 0

local assert_equals
local is_odd

local fns = {}

local e = {
	me = nil,
}

function fns.on_run()
	_start_time = _clock()
	local sum = 0
	local i = 0
	while (i < 1000) do
		local _brk = false
		repeat
			i = (i + 1)
			if is_odd(nil, i) then
				do break end
			end
			sum = (sum + i)
			if (i >= 200) then
				_brk = true
				do break end
			end
		until true
		if _brk then break end
		if _clock() - _start_time > _time_limit_sec then
			error({ type = "TIME_LIMIT_EXCEEDED", reason = string.format("Took longer than %g milliseconds to run", _time_limit_sec * 1000) }, 0)
		end
	end
	assert_equals(nil, sum, 10100)
end

function fns.init(deps, me_id)
	assert_equals = deps.assert_equals
	is_odd = deps.is_odd
	_time_limit_sec = deps._time_limit_sec
	e.me = { __grug_type = "id", value = me_id }
end

return fns
