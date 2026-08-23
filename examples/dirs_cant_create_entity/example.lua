local grug = dofile("../../grug.lua")

local state = grug.init({
	grug_files = { "animals/labrador-Dog.grug" },
	backend = arg[1] == "--interpreter" and dofile("../../alternative_backends/interpreter_backend.lua"),
})

state:register_fn("unreachable", function(state, string) end)

local dir = state.mods["animals"]

dir:create_entity()
