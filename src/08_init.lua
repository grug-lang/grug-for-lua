local grug = {}
grug.__index = grug

local function read(path)
    local file = assert(io.open(path, "r"))
    local data, err = file:read("*all")
    file:close()
    assert(data, err)
    return data
end

local function write(path, text)
    local file = assert(io.open(path, "w"))
    local ok, err = file:write(text)
    file:close()
    assert(ok, err)
end

local function check_custom_id_is_pascal(type_name)
    -- Validate that a custom ID type name is in PascalCase

    if type_name == nil or type_name == "" then
        error("type_name is empty")
    end

    if type_name:sub(1, 1):match("%l") then
        error("'" .. type_name .. "' seems like a custom ID type, but it doesn't start in Uppercase")
    end

    local bad_char = type_name:match("[^%a%d]")
    if bad_char then
        error("'" .. type_name .. "' seems like a custom ID type, but it contains '" .. bad_char .. "', which isn't uppercase/lowercase/a digit")
    end
end

local function get_file_entity_type(grug_filename)
    -- Extract and validate the entity type from a grug filename.
    -- Example: "furnace-BlockEntity.grug" -> "BlockEntity"

    local dash_index = grug_filename:find("%-") -- escape hyphen in pattern

    if not dash_index or dash_index == #grug_filename then
        error("'" .. grug_filename .. "' is missing an entity type in its name")
    end

    local period_index = grug_filename:find("%.", dash_index + 1)

    if not period_index then
        error("'" .. grug_filename .. "' is missing a period in its filename")
    end

    local entity_type = grug_filename:sub(dash_index + 1, period_index - 1)

    if entity_type == "" then
        error("'" .. grug_filename .. "' is missing an entity type in its name")
    end

    check_custom_id_is_pascal(entity_type)

    return entity_type
end

function grug:compile_grug_file(grug_file_relative_path)
    local grug_file_absolute_path = self.mods_dir_path .. '/' .. grug_file_relative_path

    local text = read(grug_file_absolute_path)

    local tokens = tokenize(text)

    local ast = Parser.new(tokens):parse()

    local mod = grug_file_relative_path:match("([^/]+)")

    local filename = grug_file_relative_path:match("([^/]+)$")
    local entity_type = get_file_entity_type(filename)

    TypePropagator.new(ast, mod, entity_type, self.mod_api):fill()

    local global_variables, on_fns, helper_fns = {}, {}, {}
    for _, stmt in ipairs(ast) do
        if stmt.stmt_type == "VariableStatement" then
            table.insert(global_variables, stmt)
        elseif stmt.stmt_type == "OnFn" then
            on_fns[stmt.fn_name] = stmt
            stmt.fn_name = nil
        elseif stmt.stmt_type == "HelperFn" then
            helper_fns[stmt.fn_name] = stmt
            stmt.fn_name = nil
        end
    end

    local game_fn_return_types = {}
    for name, decl in pairs(self.mod_api.game_functions) do
        game_fn_return_types[name] = decl.return_type
    end

    return GrugFile.new(
        grug_file_relative_path,
        mod,
        global_variables,
        on_fns,
        helper_fns,
        self.game_fns,
        game_fn_return_types,
        self
    )
end

function grug:dump_file_to_json(input_grug_path, output_json_path)
    local grug_text = read(input_grug_path)

    local tokens = tokenize(grug_text)

    local ast = Parser.new(tokens):parse()

    local json_text = ast_to_json_text(ast)

    write(output_json_path, json_text)
end

function grug:generate_file_from_json(input_json_path, output_grug_path)
    local json_text = read(input_json_path)

    local ast = json.decode(json_text)

    local grug_text = ast_to_grug(ast)

    write(output_grug_path, grug_text)
end

function grug:_register_game_fn(name, fn)
    self.game_fns[name] = fn
end

local function assert_on_functions_sorted(entity_name, on_functions)
    local keys = {}
    for _, fn in ipairs(on_functions) do
        table.insert(keys, fn.name)
    end

    local sorted_keys = { unpack(keys) }
    table.sort(sorted_keys)

    for i, actual in ipairs(keys) do
        local expected = sorted_keys[i]
        if actual ~= expected then
            error(string.format(
                "Error: on_functions for entity '%s' must be sorted alphabetically in mod_api.json, " ..
                "so '%s' must come before '%s'",
                entity_name, expected, actual
            ))
        end
    end
end

local function assert_mod_api(mod_api)
    local entities = mod_api.entities
    if type(entities) ~= "table" then
        error("Error: 'entities' must be a JSON object")
    end

    for entity_name, entity in pairs(entities) do
        if type(entity) ~= "table" then
            error(string.format("Error: entity '%s' must be a JSON object", entity_name))
        end

        local on_functions = entity.on_functions
        if on_functions ~= nil then
            if type(on_functions) ~= "table" then
                error(string.format(
                    "Error: 'on_functions' for entity '%s' must be a JSON array",
                    entity_name
                ))
            end

            assert_on_functions_sorted(entity_name, on_functions)
        end
    end

    local game_functions = mod_api.game_functions
    if type(game_functions) ~= "table" then
        error("Error: 'game_functions' must be a JSON object")
    end
end

local function default_runtime_error_handler(reason, grug_runtime_error_type, on_fn_name, on_fn_path)
    print("grug runtime error in " .. on_fn_name .. "(): " .. reason .. ", in " .. on_fn_path)
end

function grug.init(settings)
    local runtime_error_handler = settings.runtime_error_handler or default_runtime_error_handler
    local mod_api_path          = settings.mod_api_path          or "mod_api.json"
    local mods_dir_path         = settings.mods_dir_path         or "mods"
    local on_fn_time_limit_ms   = settings.on_fn_time_limit_ms   or 100
    local packages              = settings.packages               or {}

    local mod_api_text = read(mod_api_path)
    local mod_api = json.decode(mod_api_text)

    if type(mod_api) ~= "table" then
        error("Error: mod API JSON root must be an object")
    end

    assert_mod_api(mod_api)

    return setmetatable({
        runtime_error_handler = runtime_error_handler,
        mods_dir_path         = mods_dir_path,
        on_fn_time_limit_ms   = on_fn_time_limit_ms,
        mod_api               = mod_api,
        game_fns              = {},
        next_id               = 0,
        fn_depth              = 0,
    }, grug)
end
