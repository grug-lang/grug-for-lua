local grug = dofile("../../grug.lua")

local state = grug.init({
	grug_files = { "animals/labrador-Dog.grug" },
	backend = arg[1] == "--interpreter" and dofile("../../alternative_backends/interpreter_backend.lua"),
})

state:register_fn("unreached", function(state, string) end)

local file = state.mods["animals"]["labrador-Dog.grug"]
local e = file:create_entity()
e:nonexistent()
