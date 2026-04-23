local grug = require("grug")

local ffi = require("ffi")

local whitelisted_test = arg[1]
if whitelisted_test == "" then
	whitelisted_test = nil
end

local grug_tests_path = arg[2] or "../grug-tests"

local function print_traceback(err)
	io.stderr:write(debug.traceback(tostring(err)) .. "\n")
end

-- Use to print tables when debugging
local function dump(tbl, indent) -- luacheck: ignore
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

-- luacheck: push ignore
ffi.cdef([[
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

    enum grug_runtime_error_type {
        GRUG_ON_FN_STACK_OVERFLOW,
        GRUG_ON_FN_TIME_LIMIT_EXCEEDED,
        GRUG_ON_FN_GAME_FN_ERROR,
    };

    void grug_tests_runtime_error_handler(const char *reason, enum grug_runtime_error_type type, const char *on_fn_name, const char *on_fn_path);

    void grug_tests_run(const char *tests_dir_path, const char *mod_api_path, grug_state_vtable vtable, const char *whitelisted_test);
]])
-- luacheck: pop

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

local game_fn_error_reason = nil

local original_run_game_fn = grug._GrugEntity._run_game_fn

local runtime_error_type_values = {
	["STACK_OVERFLOW"] = 0,
	["TIME_LIMIT_EXCEEDED"] = 1,
	["GAME_FN_ERROR"] = 2,
}

local function custom_runtime_error_handler(reason, grug_runtime_error_type, on_fn_name, on_fn_path)
	local err = assert(runtime_error_type_values[grug_runtime_error_type])
	grug_lib.grug_tests_runtime_error_handler(reason, err, on_fn_name, on_fn_path)
end

-- We use pcall in entity callbacks because we can't propagate Lua errors to host fns.
local function handle_entity_pcall_err(ok, err)
	if not ok then
		local err_type = type(err) == "table" and err.type
		if
			err_type == "STACK_OVERFLOW"
			or err_type == "TIME_LIMIT_EXCEEDED"
			or err_type == "RERAISED_GAME_FN_ERROR"
		then
			grug_runtime_err = err
		else
			print_traceback(err)
		end
	end
end

local function c_to_lua_value(value, typ)
	if typ == "number" then
		return tonumber(value._number)
	elseif typ == "bool" then
		return value._bool
	elseif typ == "string" then
		return ffi.string(value._string)
	end
	return { __grug_type = "id", value = tonumber(value._id) }
end

local LUA_TO_C_ARG = {
	table = function(c_arg, v)
		assert(v.__grug_type == "id")
		c_arg._id = v.value
	end,
	number = function(c_arg, v)
		c_arg._number = v
	end,
	boolean = function(c_arg, v)
		c_arg._bool = v
	end,
	string = function(c_arg, v)
		local b = ffi.new("char[?]", #v + 1)
		ffi.copy(b, v)
		c_arg._string = b
	end,
}

local function register_game_fns()
	for _, name in ipairs(game_fn_names) do
		local c_fn = grug_lib["game_fn_" .. name]
		local return_type = state.mod_api.game_functions[name].return_type

		state:register_game_fn(name, function(st, ...) -- luacheck: ignore
			local args = { ... }
			local c_args = ffi.new("GrugValueUnion[?]", math.max(#args, 1))

			for i, v in ipairs(args) do
				local setter = LUA_TO_C_ARG[type(v)]
				if not setter then
					error("Unsupported argument type: " .. type(v))
				end
				setter(c_args[i - 1], v)
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
		end)
	end
end

function callbacks.create_grug_state(mod_api_path_, mods_dir_path_)
	local mod_api_path = ffi.string(mod_api_path_)
	local mods_dir_path = ffi.string(mods_dir_path_)

	local new_state
	local ok, err = pcall(function()
		new_state = grug.init({
			runtime_error_handler = custom_runtime_error_handler,
			mod_api_path = mod_api_path,
			mods_dir_path = mods_dir_path,
		})
	end)

	if not ok then
		print_traceback(err)
		return nil
	end

	state = new_state
	register_game_fns()
	return ffi.cast("void*", 42)
end

function callbacks.destroy_grug_state(state_ptr) end -- luacheck: ignore

function callbacks.compile_grug_file(state_ptr, file_path_, error_out_) -- luacheck: ignore
	local file_path = ffi.string(file_path_)

	local file
	local ok, err = pcall(function()
		file = state:compile_grug_file(file_path)
	end)

	if not ok then
		-- Removes the leading path, like `./grug.lua:915: msg`.
		-- This way we can use `error("msg")` instead of `error("msg", 0)`.
		err = err:gsub("^.-:.-: ", "")

		last_error = ffi.new("char[?]", #err + 1)
		ffi.copy(last_error, err)
		error_out_[0] = last_error
		return nil
	end

	local file_id = #files + 1
	files[file_id] = file
	return ffi.cast("void*", file_id)
end

function callbacks.init_globals(state_ptr, file_id_) -- luacheck: ignore
	local file_id = tonumber(ffi.cast("uintptr_t", file_id_))

	assert(state)
	state.next_id = 42

	local grug_file = files[file_id]
	assert(grug_file)

	handle_entity_pcall_err(pcall(function()
		current_entity = grug_file:create_entity()
	end))
end

function callbacks.call_export_fn(state_ptr, file_id_, fn_name_, args, args_len_) -- luacheck: ignore
	local file_id = tonumber(ffi.cast("uintptr_t", file_id_))
	local fn_name = ffi.string(fn_name_)
	local args_len = tonumber(ffi.cast("uintptr_t", args_len_))

	local grug_file = files[file_id]
	assert(grug_file)
	assert(current_entity)

	local on_fn_decl = grug_file.on_fns[fn_name]
	assert(on_fn_decl)
	assert(#on_fn_decl.arguments == args_len)

	local lua_args = {}
	for i = 0, args_len - 1 do
		local argument_decl = on_fn_decl.arguments[i + 1]
		table.insert(lua_args, c_to_lua_value(args[i], argument_decl.type_name))
	end

	grug_runtime_err = nil
	handle_entity_pcall_err(pcall(function()
		current_entity:_run_on_fn(fn_name, unpack(lua_args))
	end))
end

local function make_io_callback(method)
	return function(state_ptr, input_path_, output_path_) -- luacheck: ignore
		local input_path = ffi.string(input_path_)
		local output_path = ffi.string(output_path_)
		assert(state)
		local ok, err = pcall(state[method], state, input_path, output_path)
		if not ok then
			print_traceback(err)
			return true
		end
		return false
	end
end

callbacks.dump_file_to_json = make_io_callback("dump_file_to_json")
callbacks.generate_file_from_json = make_io_callback("generate_file_from_json")

local function _test_run_game_fn(self, name, ...)
	local result = original_run_game_fn(self, name, ...)

	if game_fn_error_reason then
		local reason = game_fn_error_reason
		game_fn_error_reason = nil

		assert(state)
		state.runtime_error_handler(reason, "GAME_FN_ERROR", self.fn_name, self.file.relative_path)
		error({ type = "RERAISED_GAME_FN_ERROR", reason = reason })
	end

	return result
end

grug._GrugEntity._run_game_fn = _test_run_game_fn

function callbacks.game_fn_error(state_ptr, message_) -- luacheck: ignore
	game_fn_error_reason = ffi.string(message_)
end

local vtable = ffi.new("grug_state_vtable", {
	create_grug_state = callbacks.create_grug_state,
	destroy_grug_state = callbacks.destroy_grug_state,
	compile_grug_file = callbacks.compile_grug_file,
	init_globals = callbacks.init_globals,
	call_export_fn = callbacks.call_export_fn,
	dump_file_to_json = callbacks.dump_file_to_json,
	generate_file_from_json = callbacks.generate_file_from_json,
	game_fn_error = callbacks.game_fn_error,
})

grug_lib.grug_tests_run(grug_tests_path .. "/tests", grug_tests_path .. "/mod_api.json", vtable, whitelisted_test)
