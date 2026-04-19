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

function grug:compile_grug_file(grug_file_relative_path)
    local grug_file_absolute_path = self.mods_dir_path .. '/' .. grug_file_relative_path

    local text = read(grug_file_absolute_path)

    local tokens = tokenize(text)

    local ast = Parser.new(tokens):parse()
end

function grug.init(settings)
    -- local runtime_error_handler = settings.runtime_error_handler or default_runtime_error_handler -- TODO: USE!
    local mod_api_path = settings.mod_api_path or "mod_api.json"
    local mods_dir_path = settings.mods_dir_path or "mods"
    -- local on_fn_time_limit_ms = settings.on_fn_time_limit_ms or 100 -- TODO: USE!
    -- local packages = settings.packages or {} -- TODO: USE!

    local mod_api_text = read(mod_api_path)
    local mod_api = json.decode(mod_api_text)

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
        mods_dir_path = mods_dir_path,
    }, grug)
end
