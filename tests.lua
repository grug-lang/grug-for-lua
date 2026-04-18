local ffi = require("ffi")

local grug_tests_path = arg[1] or "../grug-tests"

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

ffi.cdef[[
    typedef union {
        double _number;
        bool _bool;
        const char *_string;
        uint64_t _id;
    } GrugValueUnion;

    typedef struct {
        void* (*create_grug_state)(const char* mod_api_path, const char* mods_dir);
        void (*destroy_grug_state)(void* state);
        void* (*compile_grug_file)(void* state, const char* file_path, const char** error_out);
        void (*init_globals)(void* state, void* file_id);
        void (*call_export_fn)(void* state, void* file_id, const char* fn_name, GrugValueUnion* args, size_t args_len);
        bool (*dump_file_to_json)(void* state, const char* input_grug_path, const char* output_json_path);
        bool (*generate_file_from_json)(void* state, const char* input_json_path, const char* output_grug_path);
        void (*game_fn_error)(void* state, const char* reason);
    } grug_state_vtable;

    void grug_tests_run(const char *tests_dir_path, const char *mod_api_path, grug_state_vtable vtable, const char *whitelisted_test);
]]

local grug_lib = ffi.load(grug_tests_path .. "/build/libtests.so")

local callbacks = {}

function callbacks.create_grug_state(mod_api_path_, mods_dir_)
    local mods_dir = ffi.string(mods_dir_)

    local mod_api_path = ffi.string(mod_api_path_)

    local json = require("json")
    local mod_api_file = io.open(mod_api_path, "r")
    if not mod_api_file then
        print("Failed to open mod_api_path: " .. tostring(mod_api_path))
        return nil
    end

    local mod_api_content, err = mod_api_file:read("*all")
    if not mod_api_content then
        print("Failed to read mod_api file: " .. tostring(err))
        mod_api_file:close()
        return nil
    end

    mod_api_file:close()
    local mod_api = json.decode(mod_api_content)

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

    return ffi.cast("void*", 42)
end

function callbacks.destroy_grug_state(state)
end

function callbacks.compile_grug_file(state, file_path_, error_out_)
    return nil
end

function callbacks.init_globals(state, file_id)
end

function callbacks.call_export_fn(state, file_id, fn_name_, args, args_len)
end

function callbacks.dump_file_to_json(state, input_grug_path_, output_json_path_)
    return true
end

function callbacks.generate_file_from_json(state, input_json_path_, output_grug_path_)
    return true
end

function callbacks.game_fn_error(state, message_)
    print("Game Function Error: " .. ffi.string(message_)) -- TODO: REMOVE!
end

local vtable = ffi.new("grug_state_vtable", {
    create_grug_state = callbacks.create_grug_state,
    destroy_grug_state = callbacks.destroy_grug_state,
    compile_grug_file = callbacks.compile_grug_file,
    init_globals = callbacks.init_globals,
    call_export_fn = callbacks.call_export_fn,
    dump_file_to_json = callbacks.dump_file_to_json,
    generate_file_from_json = callbacks.generate_file_from_json,
    game_fn_error = callbacks.game_fn_error
})

grug_lib.grug_tests_run(
    grug_tests_path .. "/tests",
    grug_tests_path .. "/mod_api.json",
    vtable,
    nil -- whitelisted_test
)
