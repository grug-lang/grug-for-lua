-- These aren't necessary for LuaJIT,
-- but it speeds up Lua 5.5 by ~11%.
local get_1
local print_number

local fns = {}

local e = {
	i = 0,
}

function fns.on_increment()
	e.i = e.i + get_1()
end

function fns.on_print()
	print_number(nil, e.i)
end

function fns.init(deps)
	get_1 = deps.get_1
	print_number = deps.print_number
end

return fns
