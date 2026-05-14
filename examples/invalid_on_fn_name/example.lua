package.path = package.path .. ";../../?.lua"

local grug = require("grug")

local state = grug.init({
	grug_files = { "animals/labrador-Dog.grug" },
})

state:register("print_string", function(state, string)
	print(string)
end)

local file = state.mods["animals"]["labrador-Dog.grug"]
local e = file:create_entity()
e:on_nonexistent()
