local grug = {}
grug.__index = grug

local function read(path)
    local file = assert(io.open(path, "r"))
    local data, err = file:read("*all")
    file:close()
    assert(data, err)
    return data
end

-- TODO: REMOVE!
local function dump(tbl, indent)
    indent = indent or 0
    local prefix = string.rep("  ", indent)

    if type(tbl) ~= "table" then
        print(prefix .. tostring(tbl))
        return
    end

    print(prefix .. "{")
    for k, v in pairs(tbl) do
        io.write(prefix .. "  [" .. tostring(k) .. "] = ")
        if type(v) == "table" then
            dump(v, indent + 1)
        else
            print(tostring(v))
        end
    end
    print(prefix .. "}")
end

local function check_custom_id_is_pascal(type_name)
    -- Validate that a custom ID type name is in PascalCase

    if type_name == nil or type_name == "" then
        error("type_name is empty")
    end

    local first_char = type_name:sub(1, 1)

    if first_char:match("%l") then
        error("'" .. type_name .. "' seems like a custom ID type, but it doesn't start in Uppercase")
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
end

local function assert_mod_api() -- TODO: Add missing params
    -- TODO: Implement
end

function grug.init(settings)
    local runtime_error_handler = settings.runtime_error_handler or default_runtime_error_handler
    local mod_api_path = settings.mod_api_path or "mod_api.json"
    local mods_dir_path = settings.mods_dir_path or "mods"
    local on_fn_time_limit_ms = settings.on_fn_time_limit_ms or 100
    local packages = settings.packages or {}

    local mod_api_text = read(mod_api_path)
    local mod_api = json.decode(mod_api_text)
    assert_mod_api()

    if type(mod_api) ~= "table" then
        return nil
    end

    if type(mod_api.entities) ~= "table" then
        return nil
    end
    for k, v in pairs(mod_api.entities) do
        if type(v) ~= "table" then
            return nil
        end
    end

    if type(mod_api.game_functions) ~= "table" then
        return nil
    end

    return setmetatable({
        runtime_error_handler = runtime_error_handler,
        mods_dir_path = mods_dir_path,
        on_fn_time_limit_ms = on_fn_time_limit_ms,
        mod_api = mod_api
    }, grug)
end
