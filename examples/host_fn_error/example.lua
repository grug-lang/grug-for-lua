local grug = dofile("../../grug.lua")

-- You can pass your own list_dir(path) and is_dir(path) instead:
-- grug.init({ fs = { list_dir = list_dir, is_dir = is_dir, } })
local state = grug.init({
	grug_files = { "animals/labrador-Dog.grug" },
	backend = arg[1] == "--interpreter" and dofile("../../alternative_backends/interpreter_backend.lua"),
})

state:register_fn("print_string", function(state, string)
	if string == "" then
		grug.game_fn_error("print_string() received an empty string")
	end
	print(string)
end)

local file = state.mods["animals"]["labrador-Dog.grug"]
local dog1 = file:create_entity()

state:update()
dog1:bark("woof")
dog1:bark("")
