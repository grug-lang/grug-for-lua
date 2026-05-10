local GrugFile = {}
GrugFile.__index = function(self, key)
	-- Allow method lookups
	if GrugFile[key] then
		return GrugFile[key]
	end

	error(("GrugFile '%s' is not a directory and cannot be indexed"):format(self.relative_path), 2)
end

function GrugFile.new(
	relative_path,
	mod,
	global_variables,
	on_fns,
	helper_fns,
	game_fns,
	game_fn_return_types,
	state,
	version
)
	return setmetatable({
		relative_path = relative_path,
		mod = mod,
		global_variables = global_variables,
		on_fns = on_fns,
		helper_fns = helper_fns,
		game_fns = game_fns,
		game_fn_return_types = game_fn_return_types,
		state = state,
		version = version,
		entities = setmetatable({}, { __mode = "k" }), -- Files shouldn't keep entities alive.
	}, GrugFile)
end

function GrugFile:create_entity()
	return GrugEntity.new(self)
end
