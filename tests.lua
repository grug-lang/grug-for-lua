local grug = require("grug")

local ffi = require("ffi")

local whitelisted_test = arg[1]
if whitelisted_test == "" then whitelisted_test = nil end

local grug_tests_path = arg[2] or "../grug-tests"

local function read(path)
    local file = assert(io.open(path, "r"))
    local data, err = file:read("*all")
    file:close()
    assert(data, err)
    return data
end

ffi.cdef[[
    typedef union {
        double _number;
        bool _bool;
        const char *_string;
        uint64_t _id;
    } GrugValueUnion;

    typedef struct {
        void* (*create_grug_state)(const char* mod_api_path, const char* mods_dir_path);
        void (*destroy_grug_state)(void* state_ptr);
        void* (*compile_grug_file)(void* state_ptr, const char* file_path, const char** error_out);
        void (*init_globals)(void* state_ptr, void* file_id);
        void (*call_export_fn)(void* state_ptr, void* file_id, const char* fn_name, GrugValueUnion* args, size_t args_len);
        bool (*dump_file_to_json)(void* state_ptr, const char* input_grug_path, const char* output_json_path);
        bool (*generate_file_from_json)(void* state_ptr, const char* input_json_path, const char* output_grug_path);
        void (*game_fn_error)(void* state_ptr, const char* reason);
    } grug_state_vtable;

    void grug_tests_run(const char *tests_dir_path, const char *mod_api_path, grug_state_vtable vtable, const char *whitelisted_test);
]]

local grug_lib = ffi.load(grug_tests_path .. "/build/libtests.so")

local callbacks = {}

local state = nil

local files = {} -- Ensures compiled files are not prematurely GCed.

local last_error = nil

function callbacks.create_grug_state(mod_api_path_, mods_dir_path_)
    local mod_api_path = ffi.string(mod_api_path_)
    local mods_dir_path = ffi.string(mods_dir_path_)

    local new_state
    local status, err = pcall(function()
        new_state = grug.init({
            mod_api_path=mod_api_path,
            mods_dir_path=mods_dir_path
        })
    end)

    if (not status) or (new_state == nil) then
        return nil
    end

    state = new_state

    return ffi.cast("void*", 42)
end

function callbacks.destroy_grug_state(state_ptr)
end

function callbacks.compile_grug_file(state_ptr, file_path_, error_out_)
    local file_path = ffi.string(file_path_)

    local file
    local status, err = pcall(function()
        file = state:compile_grug_file(file_path)
    end)

    if not status then
        -- Removes the leading path, like `./grug.lua:915: msg`.
        -- This way we can use `error("msg")` instead of `error("msg", 0)`.
        err = err:gsub("^.-:.-: ", "")

        last_error = ffi.new("char[?]", #err + 1)
        ffi.copy(last_error, err)
        error_out_[0] = last_error
        return nil
    end

    file_id = #files + 1
    files[file_id] = file
    return ffi.cast("void*", file_id)
end

function callbacks.init_globals(state_ptr, file_id)
end

function callbacks.call_export_fn(state_ptr, file_id, fn_name_, args, args_len)
end

function callbacks.dump_file_to_json(state_ptr, input_grug_path_, output_json_path_)
    local input_grug_path = ffi.string(input_grug_path_)
    local output_json_path = ffi.string(output_json_path_)

    assert(state)

    if pcall(function()
        state:dump_file_to_json(input_grug_path, output_json_path)
    end) then
        return false
    end

    return true
end

function callbacks.generate_file_from_json(state_ptr, input_json_path_, output_grug_path_)
    local input_json_path = ffi.string(input_json_path_)
    local output_grug_path = ffi.string(output_grug_path_)

    assert(state)

    if pcall(function()
        state:generate_file_from_json(input_json_path, output_grug_path)
    end) then
        return false
    end

    return true
end

function callbacks.game_fn_error(state_ptr, message_)
    local message = ffi.string(message_)

    print("Game function error: " .. ffi.string(message)) -- TODO: REMOVE!
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
    whitelisted_test
)
