local GrugFile = {}
GrugFile.__index = GrugFile

function GrugFile.new(
    relative_path,
    mod,
    global_variables,
    on_fns,
    helper_fns,
    game_fns,
    game_fn_return_types,
    state
)
    return setmetatable({
        relative_path        = relative_path,
        mod                  = mod,
        global_variables     = global_variables,
        on_fns               = on_fns,
        helper_fns           = helper_fns,
        game_fns             = game_fns,
        game_fn_return_types = game_fn_return_types,
        state                = state,
    }, GrugFile)
end

function GrugFile:create_entity()
    return Entity.new(self)
end
