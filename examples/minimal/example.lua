local grug = dofile("../../grug.lua")

-- You can pass your own list_dir(path) and is_dir(path) instead:
-- grug.init({ fs = { list_dir = list_dir, is_dir = is_dir, } })
local state = grug.init({
	grug_files = { "animals/labrador-Dog.grug" },
})

state:register("print_string", function(state, string)
	print(string)
end)

local file = state.mods["animals"]["labrador-Dog.grug"]
local dog1 = file:create_entity()
local dog2 = file:create_entity()

while true do
	state:update()
	dog1:bark("woof")
	dog2:bark("arf")
end
