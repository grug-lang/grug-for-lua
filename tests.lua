local ffi = require("ffi")

local grug_tests_path = arg[1] or "../grug-tests"

ffi.cdef[[
    typedef union {
        double _number;
        bool _bool;
        const char *_string;
        uint64_t _id;
    } GrugValueUnion;

    typedef struct {
        void* (*create_grug_state)(const char* tests_path, const char* mod_api_path);
        void (*destroy_grug_state)(void* state_ptr);
        void* (*compile_grug_file)(void* state_ptr, const char* path, const char** out_err);
        void (*init_globals)(void* state_ptr, void* file_id);
        void (*call_export_fn)(void* state_ptr, void* file_id, const char* on_fn_name, GrugValueUnion* args, size_t args_len);
        bool (*dump_file_to_json)(void* state_ptr, const char* input_grug_path, const char* output_json_path);
        bool (*generate_file_from_json)(void* state_ptr, const char* input_json_path, const char* output_grug_path);
        void (*game_fn_error)(void* state_ptr, const char* reason);
    } grug_state_vtable;

    void grug_tests_run(const char *tests_dir_path, const char *mod_api_path, grug_state_vtable vtable, const char *whitelisted_test);
]]

local grug_lib = ffi.load(grug_tests_path .. "/build/libtests.so")

local callbacks = {}

function callbacks.create_grug_state(tests_path, mod_api_path)
    print("Test Runner: Initializing Grug State...") -- TODO: REMOVE!
    return ffi.cast("void*", 42)
end

function callbacks.destroy_grug_state(state_ptr)
    print("Test Runner: Destroying Grug State") -- TODO: REMOVE!
end

function callbacks.compile_grug_file(state_ptr, path, out_err)
    return nil
end

function callbacks.init_globals(state_ptr, file_id)
end

function callbacks.call_export_fn(state_ptr, file_id, on_fn_name, args, args_len)
end

function callbacks.dump_file_to_json(state_ptr, input_path, output_path)
    return true
end

function callbacks.generate_file_from_json(state_ptr, input_path, output_path)
    return true
end

function callbacks.game_fn_error(state_ptr, reason)
    print("Game Function Error: " .. ffi.string(reason)) -- TODO: REMOVE!
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
