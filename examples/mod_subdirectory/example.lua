local grug = dofile("../../grug.lua")

local function is_dir(path)
	if path == "mods/animals" then
		return true
	elseif path == "mods/animals/dogs" then
		return true
	elseif path == "mods/animals/dogs/labrador-Dog.grug" then
		return false
	else
		-- luacov: disable
		error('Missing elseif for is_dir("' .. path .. '")')
		-- luacov: enable
	end
end

local function list_dir(path)
	if path == "mods" then
		return { "animals" }
	elseif path == "mods/animals" then
		return { "dogs" }
	elseif path == "mods/animals/dogs" then
		return { "labrador-Dog.grug" }
	else
		-- luacov: disable
		error('Missing elseif for list_dir("' .. path .. '")')
		-- luacov: enable
	end
end

local state = grug.init({
	fs = {
		list_dir = list_dir,
		is_dir = is_dir,
	},
	backend = arg[1] == "--interpreter" and dofile("../../alternative_backends/interpreter_backend.lua"),
})

state:register_fn("print_string", function(state, string)
	print(string)
end)

local file = state.mods["animals"]["dogs"]["labrador-Dog.grug"]
local dog = file:create_entity()

dog:bark("woof")
