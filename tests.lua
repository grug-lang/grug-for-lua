local ffi
do
	-- ffi for LuaJIT
	local ok, result = pcall(require, "ffi")
	if ok then
		ffi = result
	else
		-- cffi-lua for standard Lua
		ok, result = pcall(require, "cffi")
		if ok then
			ffi = result
		else
			print('Error: require("ffi") and require("cffi") both returned nil.\n')
			os.exit(1)
		end
	end
end

local grug = require("grug")
local interpreter_backend = require("alternative_backends/interpreter_backend")

local whitelisted_test = arg[1]
if whitelisted_test == "" then
	whitelisted_test = nil
end

local grug_tests_path = arg[2] or "../grug-tests"

local function push(t, value)
	t[#t + 1] = value
end

local function dump_to_str(tbl, indent, seen)
	indent = indent or 0
	seen = seen or {}
	local prefix = string.rep("  ", indent)

	if type(tbl) ~= "table" then
		return prefix .. tostring(tbl)
	end

	-- Prevents infinite recursion on cyclic tables
	if seen[tbl] then
		return prefix .. "<cycle>"
	end
	seen[tbl] = true

	local out = { prefix .. "{" }

	for k, v in pairs(tbl) do
		local line = prefix .. "  [" .. tostring(k) .. "] = "

		if type(v) == "table" then
			push(out, line)
			push(out, dump_to_str(v, indent + 1, seen))
		else
			push(out, line .. tostring(v))
		end
	end

	push(out, prefix .. "}")
	return table.concat(out, "\n")
end

local function print_traceback(err)
	print(debug.traceback(dump_to_str(err)) .. "\n")
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
		void* (*create_grug_state)(const char* mod_api_path, const char* mods_dir_path, bool safe_mode);
		void (*destroy_grug_state)(void* state_ptr);
		void* (*compile_grug_file)(void* state_ptr, const char* file_path, const char** error_out);
		void (*destroy_grug_file)(void* state_ptr, void* file_id);
		void* (*create_entity)(void* state_ptr, void* file_id, const char** error_out);
		void (*destroy_entity)(void* state_ptr, void* entity_id);
		void (*update)(void* state_ptr, const char** error_out);
		void (*call_export_fn)(void* state_ptr, void* entity_id, const char* fn_name, GrugValueUnion* args, size_t args_len);
		bool (*grug_to_json)(void* state_ptr, const char* input_grug_buffer, char* output_json_buffer, size_t output_buffer_len);
		bool (*json_to_grug)(void* state_ptr, const char* input_json_buffer, char* output_grug_buffer, size_t output_buffer_len);
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

local host_fn_names = {
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
	"assert_state_is_not_null",
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

for _, name in ipairs(host_fn_names) do
	ffi.cdef("uint64_t game_fn_" .. name .. "(void* state_ptr, GrugValueUnion* args);")
end

local grug_lib = ffi.load(grug_tests_path .. "/build/libtests.so")

local current_config = nil

local callbacks = {}

local states = {} -- int -> state
local files = {} -- int -> GrugFile
local entities = {} -- int -> Entity

local last_file_id = nil

local grug_runtime_err = nil

local host_fn_error_reason = nil

local runtime_error_type_values = {
	["STACK_OVERFLOW"] = 0,
	["TIME_LIMIT_EXCEEDED"] = 1,
	["GAME_FN_ERROR"] = 2,
}

local function custom_runtime_error_handler(reason, grug_runtime_error_type, export_fn_name, export_fn_path)
	local err = assert(runtime_error_type_values[grug_runtime_error_type])
	grug_lib.grug_tests_runtime_error_handler(reason, err, export_fn_name, export_fn_path)
end

-- Convert to string and extract only the numeric digits.
-- This works around a cffi bug with ffi.cast("uintptr_t", state_ptr_)
-- where it appends '\0', which caused tonumber() to always return nil.
local function cdata_to_number(v)
	return assert(tonumber(tostring(v):match("%d+")))
end

local function to_uintptr(state_ptr_)
	return cdata_to_number(ffi.cast("uintptr_t", state_ptr_))
end

local function c_to_lua_value(value, typ)
	if typ == "number" then
		return tonumber(value._number)
	elseif typ == "bool" then
		return value._bool
	elseif typ == "string" then
		return ffi.string(value._string)
	end
	return { __grug_type = "id", value = cdata_to_number(value._id) }
end

-- LuaJIT's ffi null-terminates ffi.copy(dst, src):
-- > All bytes of the string plus a zero-terminator
-- > are copied to dst (i.e. #str+1 bytes).
-- Source: https://luajit.org/ext_ffi_api.html#ffi_copy
--
-- This copy_str() function exists because I have observed
-- that cffi does *not* add the null-terminator. :(
local function copy_str(buf, str)
	local str_len = #str
	ffi.copy(buf, str, str_len)
	buf[str_len] = 0
end

local function string_buf(str)
	local buf = ffi.new("char[?]", #str + 1)
	copy_str(buf, str)
	return buf
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
		c_arg._string = string_buf(v)
	end,
}

local function _raise_host_fn_error_if_needed(state)
	if not host_fn_error_reason then
		return
	end

	local reason = host_fn_error_reason
	host_fn_error_reason = nil

	assert(state._executed_file)
	assert(state._executed_entity)

	state.runtime_error_handler(
		reason,
		"GAME_FN_ERROR",
		state._executed_entity.fn_name,
		state._executed_file.relative_path
	)

	error({ type = "RERAISED_GAME_FN_ERROR", reason = reason })
end

local function register_fn(state, name)
	local c_fn = grug_lib["game_fn_" .. name]
	local return_type = state.mod_api.host_functions[name].return_type

	state:register(name, function(st, ...) -- luacheck: ignore
		local args = { ... }
		local c_args = ffi.new("GrugValueUnion[?]", math.max(#args, 1))

		for i, v in ipairs(args) do
			local setter = LUA_TO_C_ARG[type(v)]
			if not setter then
				error("Unsupported argument type: " .. type(v))
			end
			setter(c_args[i - 1], v)
		end

		local result_u64 = c_fn(ffi.cast("void*", st.id), c_args)

		_raise_host_fn_error_if_needed(st)

		if grug_runtime_err ~= nil then
			error(grug_runtime_err)
		end

		local tmp = ffi.new("uint64_t[1]")
		tmp[0] = result_u64

		local union = ffi.new("GrugValueUnion")
		ffi.copy(ffi.cast("void*", union), tmp, ffi.sizeof("GrugValueUnion"))

		return c_to_lua_value(union, return_type)
	end)
end

local function register_fns(state)
	for _, name in ipairs(host_fn_names) do
		register_fn(state, name)
	end
end

local function is_dir(path)
	if path == ".grug_tmp_code_reloading/code_reloading" then
		return true
	elseif path == ".grug_tmp_reloading_empty_file/reloading_empty_file" then
		return true
	elseif path == ".grug_tmp_code_reloading/code_reloading/input-D.grug" then
		return false
	elseif path == ".grug_tmp_reloading_empty_file/reloading_empty_file/input-D.grug" then
		return false
	else
		error('Missing elseif for is_dir("' .. path .. '")')
	end
end

local function list_dir(path)
	if path == ".grug_tmp_code_reloading" then
		return { "code_reloading" }
	elseif path == ".grug_tmp_reloading_empty_file" then
		return { "reloading_empty_file" }
	elseif path == ".grug_tmp_code_reloading/code_reloading" then
		return { "input-D.grug" }
	elseif path == ".grug_tmp_reloading_empty_file/reloading_empty_file" then
		return { "input-D.grug" }
	else
		error('Missing elseif for list_dir("' .. path .. '")')
	end
end

function callbacks.create_grug_state(mod_api_path_, mods_dir_path_, safe_mode)
	local mod_api_path = ffi.string(mod_api_path_)
	local mods_dir_path = ffi.string(mods_dir_path_)

	local state
	local ok, err = pcall(function()
		state = grug.init({
			runtime_error_handler = custom_runtime_error_handler,
			mod_api_path = mod_api_path,
			mods_dir_path = mods_dir_path,
			export_fn_time_limit_ms = 1000,
			fs = {
				list_dir = list_dir,
				is_dir = is_dir,
			},
			safe_mode = safe_mode,
			backend = current_config.backend,
		})
	end)

	if not ok then
		print_traceback(err)
		return nil
	end

	local state_id = #states + 1
	states[state_id] = state
	state.id = state_id -- Assign ID to the state for C pointer recovery during host_fn calls

	register_fns(state)

	return ffi.cast("void*", state_id)
end

function callbacks.destroy_grug_state(state_ptr_)
	states[to_uintptr(state_ptr_)] = nil
end

local function get_c_error_string(err)
	return string_buf(err)
end

-- Turns `./grug.lua:731: Expected token` into `Expected token`.
-- This allows grug.lua to use `error("msg")` instead of `error("msg", 0)`.
local function get_msg_from_lua_error(err)
	return err:gsub("^.-:.-: ", "")
end

function callbacks.compile_grug_file(state_ptr_, file_path_, error_out_)
	local file_path = ffi.string(file_path_)

	local state = assert(states[to_uintptr(state_ptr_)])

	local file
	local ok, err = pcall(function()
		if file_path == "code_reloading/input-D.grug" then
			state:_update()
			file = state.mods["code_reloading"]["input-D.grug"]
		else
			file = state:_recompile_with_hot_reload(file_path)
		end
	end)

	if not ok then
		err = get_msg_from_lua_error(err)
		error_out_[0] = get_c_error_string(err)
		return nil
	end

	local file_id = #files + 1
	files[file_id] = file
	last_file_id = file_id
	error_out_[0] = nil
	return ffi.cast("void*", file_id)
end

function callbacks.destroy_grug_file(_state_ptr_, file_id_)
	local file_id = to_uintptr(file_id_)

	-- Asserts that file.entities has weak keys
	collectgarbage()
	local count = 0
	for _entity in pairs(files[file_id].entities) do -- luacheck: ignore
		count = count + 1
	end
	assert(count == 0)

	files[file_id] = nil
end

function callbacks.create_entity(state_ptr_, file_id_, error_out_)
	local state = assert(states[to_uintptr(state_ptr_)])

	grug_runtime_err = nil

	state.next_id = 42

	local file = files[to_uintptr(file_id_)]

	local entity
	local ok, err = pcall(function()
		entity = file:create_entity()
	end)

	if not ok then
		local err_type = type(err) == "table" and err.type
		if
			err_type == "STACK_OVERFLOW"
			or err_type == "TIME_LIMIT_EXCEEDED"
			or err_type == "RERAISED_GAME_FN_ERROR"
		then
			error_out_[0] = get_c_error_string(err.reason)

			-- Necessary, as C doesn't propagate exceptions.
			grug_runtime_err = err

			return ffi.cast("void*", -1)
		else
			print_traceback(err)
			return ffi.cast("void*", -1)
		end
	end

	local entity_id = #entities + 1
	entities[entity_id] = entity
	error_out_[0] = nil
	return ffi.cast("void*", entity_id)
end

function callbacks.destroy_entity(_state_ptr_, entity_id_)
	entities[to_uintptr(entity_id_)] = nil
end

function callbacks.update(state_ptr_, error_out_)
	local state = assert(states[to_uintptr(state_ptr_)])

	local file
	local ok, err = pcall(function()
		state:_update()
	end)

	if not ok then
		err = get_msg_from_lua_error(err)
		error_out_[0] = get_c_error_string(err)
		return
	end

	-- We have to manually overwrite the old file in the files list,
	-- purely because test_grug.py tries to emulate the grug implementation.
	file = state.mods["code_reloading"]["input-D.grug"]
	files[last_file_id] = file

	error_out_[0] = nil
end

-- LuaJIT only has unpack(), whereas Lua 5.1 only has table.unpack()
local unpacker = unpack or table.unpack

function callbacks.call_export_fn(_state_ptr_, entity_id_, fn_name_, args, args_len_)
	local fn_name = ffi.string(fn_name_)
	local args_len = to_uintptr(args_len_)

	grug_runtime_err = nil

	local entity = entities[to_uintptr(entity_id_)]

	local file = entity.file

	local export_fn_decl = file.export_fns[fn_name]
	assert(#export_fn_decl.arguments == args_len)

	local lua_args = {}
	for i = 0, args_len - 1 do
		local argument_decl = export_fn_decl.arguments[i + 1]
		push(lua_args, c_to_lua_value(args[i], argument_decl.type_name))
	end

	local ok, err = pcall(function()
		local export_fn = entity[fn_name]
		export_fn(entity, unpacker(lua_args))
	end)

	if not ok then
		local err_type = type(err) == "table" and err.type
		if
			err_type == "STACK_OVERFLOW"
			or err_type == "TIME_LIMIT_EXCEEDED"
			or err_type == "RERAISED_GAME_FN_ERROR"
		then
			-- Necessary, as C doesn't propagate exceptions.
			grug_runtime_err = err
		else
			error(dump_to_str(err))
		end
	end
end

local function make_io_callback(method)
	return function(state_ptr_, input_buffer_, output_buffer_, output_buffer_len_)
		local state = assert(states[to_uintptr(state_ptr_)])
		local output_buffer_len = cdata_to_number(output_buffer_len_)

		local input_text = ffi.string(input_buffer_)
		local ok, result = pcall(state[method], state, input_text)
		if not ok then
			print_traceback(result)
			return true
		end

		assert(type(result) == "string")
		local result_len = #result

		-- Check if we have space for result + null terminator
		if result_len + 1 > output_buffer_len then
			print_traceback(
				string.format(
					"%s: output buffer too small (need %d bytes, have %d)",
					method,
					result_len + 1,
					output_buffer_len
				)
			)
			return true
		end

		copy_str(output_buffer_, result)
		return false
	end
end

callbacks.grug_to_json = make_io_callback("grug_to_json")
callbacks.json_to_grug = make_io_callback("json_to_grug")

function callbacks.host_fn_error(_state_ptr_, reason_)
	host_fn_error_reason = ffi.string(reason_)
end

-- Create a table to anchor the C callback closures
local vtable_anchors = {
	create_grug_state = ffi.cast("void* (*)(const char*, const char*, bool)", callbacks.create_grug_state),
	destroy_grug_state = ffi.cast("void (*)(void*)", callbacks.destroy_grug_state),
	compile_grug_file = ffi.cast("void* (*)(void*, const char*, const char**)", callbacks.compile_grug_file),
	destroy_grug_file = ffi.cast("void (*)(void*, void*)", callbacks.destroy_grug_file),
	create_entity = ffi.cast("void* (*)(void*, void*, const char**)", callbacks.create_entity),
	destroy_entity = ffi.cast("void (*)(void*, void*)", callbacks.destroy_entity),
	update = ffi.cast("void (*)(void*, const char**)", callbacks.update),
	call_export_fn = ffi.cast("void (*)(void*, void*, const char*, GrugValueUnion*, size_t)", callbacks.call_export_fn),
	grug_to_json = ffi.cast("bool (*)(void*, const char*, char*, size_t)", callbacks.grug_to_json),
	json_to_grug = ffi.cast("bool (*)(void*, const char*, char*, size_t)", callbacks.json_to_grug),
	game_fn_error = ffi.cast("void (*)(void*, const char*)", callbacks.game_fn_error),
}

local vtable = ffi.new("grug_state_vtable")

-- Assign the anchored closures to the struct
vtable.create_grug_state = vtable_anchors.create_grug_state
vtable.destroy_grug_state = vtable_anchors.destroy_grug_state
vtable.compile_grug_file = vtable_anchors.compile_grug_file
vtable.destroy_grug_file = vtable_anchors.destroy_grug_file
vtable.create_entity = vtable_anchors.create_entity
vtable.destroy_entity = vtable_anchors.destroy_entity
vtable.update = vtable_anchors.update
vtable.call_export_fn = vtable_anchors.call_export_fn
vtable.grug_to_json = vtable_anchors.grug_to_json
vtable.json_to_grug = vtable_anchors.json_to_grug
vtable.game_fn_error = vtable_anchors.game_fn_error

local function reset_state()
	states = {}
	files = {}
	entities = {}
	last_file_id = nil
	grug_runtime_err = nil
	host_fn_error_reason = nil
end

local configs = {
	{ name = "grug transpiler backend" },
	{ name = "grug interpreter backend", backend = interpreter_backend },
}

for _, config in ipairs(configs) do
	current_config = config
	print("=== Testing " .. config.name .. " ===")

	grug_lib.grug_tests_run(grug_tests_path .. "/tests", grug_tests_path .. "/mod_api.json", vtable, whitelisted_test)

	assert(#states == 0)
	assert(#files == 0)
	assert(#entities == 0)

	reset_state()
end
