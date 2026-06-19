local assert_equals
local is_odd

local fns = {}

local e = {
	state = nil,
	me = nil,
}

function fns.run()
	local sum = 0
	local i = 0
	while (i < 1000) do
		local _brk = false
		repeat
			i = (i + 1)
			if is_odd(e.state, i) then
				do break end
			end
			sum = (sum + i)
			if (i >= 200) then
				_brk = true
				do break end
			end
		until true
		if _brk then break end
	end
	assert_equals(e.state, sum, 10100)
end

function fns.init(deps, state, me_id)
	assert_equals = deps.assert_equals
	is_odd = deps.is_odd
	e.state = state
	e.me = { __grug_type = "id", value = me_id }
end

return fns
