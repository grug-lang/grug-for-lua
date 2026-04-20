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

local game_fn_names = {
    "nothing",
    "magic",
    "initialize",
    "initialize_bool",
    "identity",
    "max",
    "say",
    "sin",
    "cos",
    "mega",
    "get_false",
    "set_is_happy",
    "mega_f32",
    "mega_i32",
    "draw",
    "blocked_alrm",
    "spawn",
    "spawn_d",
    "has_resource",
    "has_entity",
    "has_string",
    "get_opponent",
    "get_os",
    "set_d",
    "set_opponent",
    "motherload",
    "motherload_subless",
    "offset_32_bit_f32",
    "offset_32_bit_i32",
    "offset_32_bit_string",
    "print_csv",
    "talk",
    "get_position",
    "set_position",
    "cause_game_fn_error",
    "call_on_b_fn",
    "store",
    "retrieve",
    "box_number",
}

for _, name in ipairs(game_fn_names) do
    ffi.cdef("uint64_t game_fn_" .. name .. "(void* state_ptr, GrugValueUnion* args);")
end

local grug_lib = ffi.load(grug_tests_path .. "/build/libtests.so")

local callbacks = {}

local state = nil

local files = {} -- Ensures compiled files are not prematurely GCed.

local last_error = nil

local current_entity = nil

local grug_runtime_err = nil

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

    register_game_fns()

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

function callbacks.init_globals(state_ptr, file_id_)
    local file_id = tonumber(ffi.cast("uintptr_t", file_id_))

    assert(state)
    state.next_id = 42

    local grug_file = files[file_id]
    assert(grug_file)

    current_entity = grug_file:create_entity()
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

-- TODO: Use this in all 5 spots that call traceback.print_exc() in Python
local function print_traceback(err)
    io.stderr:write(debug.traceback(tostring(err)) .. "\n")
end

local function c_to_lua_value(value, typ)
    -- TODO: Check that commenting out any of these branches causes tests to fail
    if typ == "number" then
        return tonumber(value._number)
    elseif typ == "bool" then
        return value._bool -- TODO: Should this use tonumber()?
        -- TODO: Gemini suggested this:
        -- return value._bool ~= 0 and value._bool ~= false
    elseif typ == "string" then
        return ffi.string(value._string)
    end
    return tonumber(value._id)
end

function callbacks.call_export_fn(state_ptr, file_id_, fn_name_, args, args_len_)
    local file_id = tonumber(ffi.cast("uintptr_t", file_id_))
    local fn_name = ffi.string(fn_name_)
    local args_len = tonumber(ffi.cast("uintptr_t", args_len_))

    local grug_file = files[file_id]
    assert(grug_file)
    assert(current_entity)

    local on_fn_decl = grug_file.on_fns[fn_name]
    assert(on_fn_decl)

    assert(#on_fn_decl.arguments == args_len)

    -- Convert C arguments to Lua values
    local lua_args = {}
    for i = 0, args_len - 1 do
        local argument_decl = on_fn_decl.arguments[i + 1]
        local c_val = args[i]
        table.insert(lua_args, c_to_lua_value(c_val, argument_decl.type_name))
    end

    -- Execute with error handling
    -- We use pcall because propagating Lua errors through a C boundary (FFI callback)
    -- is undefined behavior/unstable in many environments.
    grug_runtime_err = nil
    local status, err = pcall(function()
        current_entity:_run_on_fn(fn_name, unpack(lua_args))
    end)

    if not status then
        -- Exception catching
        if type(err) == "table" and (
            err.type == "TIME_LIMIT_EXCEEDED" or 
            err.type == "STACK_OVERFLOW" or 
            err.type == "RERAISED_GAME_FN_ERROR"
        ) then
            grug_runtime_err = err
        else
            print_traceback(err)
        end
    end
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

function register_game_fns()
    for _, name in ipairs(game_fn_names) do
        local c_fn = grug_lib["game_fn_" .. name]
        local game_fn_entry = state.mod_api.game_functions[name]
        local return_type = game_fn_entry and game_fn_entry.return_type

        local fn = function(st, ...)
            local args = {...}
            local c_args = ffi.new("GrugValueUnion[?]", math.max(#args, 1))
            for i, v in ipairs(args) do
                local t = type(v)
                if t == "number" then
                    c_args[i-1]._number = v
                elseif t == "boolean" then
                    c_args[i-1]._bool = v
                elseif t == "string" then
                    local b = ffi.new("char[?]", #v + 1)
                    ffi.copy(b, v)
                    c_args[i-1]._string = b
                else
                    c_args[i-1]._id = v
                end
            end
            local result_u64 = c_fn(nil, c_args)
            if grug_runtime_err ~= nil then
                error(grug_runtime_err)
            end
            local tmp = ffi.new("uint64_t[1]")
            tmp[0] = result_u64
            local union = ffi.new("GrugValueUnion")
            ffi.copy(union, tmp, ffi.sizeof("GrugValueUnion"))
            return c_to_lua_value(union, return_type)
        end

        state:_register_game_fn(name, fn)
    end
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
