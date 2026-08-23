local grug = dofile("../../grug.lua")

local function list_dir(path) end

local state = grug.init({
	fs = {
		list_dir = list_dir,
	},
	backend = arg[1] == "--interpreter" and dofile("../../alternative_backends/interpreter_backend.lua"),
})

local mods = state.mods
