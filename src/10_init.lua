local grug = {}
grug.__index = function(self, key)
	-- property-style access: state.mods
	if key == "mods" then
		if self._mods == nil then
			self:_update()
		end

		assert(self._mods, "mods not initialized")
		return self._mods
	end

	-- normal method lookup
	return grug[key]
end

local function is_computercraft_checker()
	if not os or not os.version then -- luacheck: ignore os
		return false
	end

	-- CC: Tweaked added this function. CC did not have it.
	-- CC: Tweaked doesn't discard trailing newlines,
	-- so doesn't need CC's byte reading workaround.
	if os.epoch then -- luacheck: ignore os
		return false
	end

	local version = os.version() -- luacheck: ignore os

	-- Computers use CraftOS, whereas Turtles use TurtleOS.
	return version:find("CraftOS") or version:find("TurtleOS")
end

local is_computercraft = is_computercraft_checker()

local function _read_computercraft(path)
	-- We use binary mode to preserve the trailing newline
	-- at the end of the file.
	-- ComputerCraft 1.33 replaces Lua's default io API
	-- with its own io API that uses CC its fs API.
	--
	-- This workaround might not be necessary for OpenComputers,
	-- but the main goal is to support Tekkit Classic's CC.
	--
	-- ComputerCraft strips the trailing newline here:
	-- https://github.com/dan200/ComputerCraft/blob/
	-- bbe7a4c11c4c0fc5ae3c040c3374cf8a52922b64/src/
	-- main/java/dan200/computercraft/core/apis/
	-- handles/EncodedInputHandle.java#L83-L103
	local file, err = io.open(path, "rb")
	assert(file, "failed to open file: " .. path .. " (" .. tostring(err) .. ")")

	-- ComputerCraft 1.33 its io.read()
	-- can't read more than one byte at a time.
	local byte = file:read(1)

	local data = ""
	while byte do
		data = data .. string.char(byte)
		byte = file:read(1)
	end

	file:close()
	return data
end

local function _read(path)
	if is_computercraft then
		return _read_computercraft(path)
	end

	local file, err = io.open(path, "r")
	assert(file, "failed to open file: " .. path .. " (" .. tostring(err) .. ")")

	local data, read_err = file:read("*a")
	file:close()
	assert(data, read_err)
	return data
end

function grug:_recompile_with_hot_reload(rel_path, existing)
	local new_file = self:_compile_grug_file(rel_path)
	-- Notify the backend: migrate entity data on hot reload, no-op on fresh compile.
	self.backend:insert_file(new_file, existing)
	return new_file
end

local function luajit_remake_gmatch(s, pattern)
	-- This implementation only supports the pattern "[^/]+" (split by '/').
	assert(pattern == "[^/]+", "luajit_remake_gmatch only supports '[^/]+'")

	local i = 1
	local len = #s

	return function()
		-- Skip leading slashes.
		while i <= len and s:sub(i, i) == "/" do
			i = i + 1
		end

		if i > len then
			return nil
		end

		local start = i

		-- Consume until next slash.
		while i <= len and s:sub(i, i) ~= "/" do
			i = i + 1
		end

		return s:sub(start, i - 1)
	end
end

-- luajit-remake has not implemented string.gmatch,
-- so it prints an error and returns false when called.
local my_gmatch = string.gmatch
if not pcall(string.gmatch, "", "") then
	my_gmatch = luajit_remake_gmatch
end

local function _update_from_list(self)
	for _, rel_path in ipairs(self.grug_files) do
		local current_dir = self._mods
		local parts = {}
		for part in my_gmatch(rel_path, "[^/]+") do
			push(parts, part)
		end

		-- Build tree.
		for i = 1, #parts - 1 do
			local dir_name = parts[i]
			current_dir.dirs[dir_name] = current_dir.dirs[dir_name] or GrugDir.new(dir_name)
			current_dir = current_dir.dirs[dir_name]
		end

		local filename = parts[#parts]
		local abs_path = self.mods_dir_path .. "/" .. rel_path

		local text = self.fs.read(abs_path)
		local existing = current_dir.files[filename]

		if not existing or existing.version ~= self.fs.get_file_version(abs_path, text) then
			current_dir.files[filename] = self:_recompile_with_hot_reload(rel_path, existing)
		end
	end
end

-- This (re)compiles grug files using mark-and-sweep, and prints any error.
function grug:update()
	local ok, err = pcall(grug._update, self)
	if not ok then
		print(err)
	end
end

function grug:_update_dir(current_path, grug_dir, seen_files, seen_dirs)
	-- Mark this directory as visited
	seen_dirs[current_path] = true

	-- Mark phase: scan disk
	local entries = self.fs.list_dir(current_path)
	if entries then
		for _, entry_name in ipairs(entries) do
			local entry_path = current_path .. "/" .. entry_name

			if self.fs.is_dir(entry_path) then
				local sub = grug_dir.dirs[entry_name]
				if sub == nil then
					sub = GrugDir.new(entry_name)
					grug_dir.dirs[entry_name] = sub
				end
				self:_update_dir(entry_path, sub, seen_files, seen_dirs)
			elseif entry_name:sub(-5) == ".grug" then
				local rel_path = entry_path:sub(#self.mods_dir_path + 2)
				seen_files[rel_path] = true

				local text = self.fs.read(entry_path)
				local existing = grug_dir.files[entry_name]

				if not existing or existing.version ~= self.fs.get_file_version(entry_path, text) then
					grug_dir.files[entry_name] = self:_recompile_with_hot_reload(rel_path, existing)
				end
			end
		end
	end

	-- Sweep files
	for name, file in pairs(grug_dir.files) do
		if not seen_files[file.relative_path] then
			grug_dir.files[name] = nil
		end
	end

	-- Sweep subdirectories
	for name, _ in pairs(grug_dir.dirs) do
		local sub_path = current_path .. "/" .. name
		if not seen_dirs[sub_path] then
			grug_dir.dirs[name] = nil
		end
	end
end

-- This (re)compiles grug files using mark-and-sweep.
function grug:_update()
	if self._mods == nil then
		self._mods = GrugDir.new("mods")
	end

	-- Use the provided file list if available
	if self.grug_files then
		return _update_from_list(self)
	end

	-- Otherwise, fall back to directory scanning
	if type(self.fs.list_dir) ~= "function" or type(self.fs.is_dir) ~= "function" then
		error("Error: grug:update() requires list_dir and is_dir OR a grug_files list.")
	end

	local seen_files = {}
	local seen_dirs = {}

	local root = self._mods

	-- Process each top-level mod directory
	local mod_dirs = self.fs.list_dir(self.mods_dir_path)
	if mod_dirs then
		for _, mod_dir_name in ipairs(mod_dirs) do
			local mod_dir_path = self.mods_dir_path .. "/" .. mod_dir_name
			if self.fs.is_dir(mod_dir_path) then
				local sub = root.dirs[mod_dir_name]
				if sub == nil then
					sub = GrugDir.new(mod_dir_name)
					root.dirs[mod_dir_name] = sub
				end
				self:_update_dir(mod_dir_path, sub, seen_files, seen_dirs)
			end
		end
	end

	-- Sweep removed top-level dirs
	for name, _ in pairs(root.dirs) do
		local mod_path = self.mods_dir_path .. "/" .. name
		if not seen_dirs[mod_path] then
			root.dirs[name] = nil
		end
	end
end

local function check_custom_id_is_pascal(type_name, file_path)
	-- Validate that a custom ID type name is in PascalCase

	if type_name == nil or type_name == "" then
		error("type_name is empty")
	end

	if type_name:sub(1, 1):match("%l") then
		error(
			"Error: '"
				.. type_name
				.. "' seems like a custom ID type, but it doesn't start in Uppercase\n$  "
				.. file_path
		)
	end

	local bad_char = type_name:match("[^%a%d]")
	if bad_char then
		error(
			"Error: '"
				.. type_name
				.. "' seems like a custom ID type, but it contains '"
				.. bad_char
				.. "', which isn't uppercase, lowercase, or a digit\n$  "
				.. file_path
		)
	end
end

local function get_file_entity_type(grug_filename, file_path)
	-- Extract and validate the entity type from a grug filename.
	-- Example: "furnace-BlockEntity.grug" -> "BlockEntity"

	local dash_index = grug_filename:find("%-") -- escape hyphen in pattern

	if not dash_index or dash_index == #grug_filename then
		error("Error: '" .. grug_filename .. "' is missing an entity type in its name\n$  " .. file_path)
	end

	local period_index = grug_filename:find("%.", dash_index + 1)

	if not period_index then
		error("Error: '" .. grug_filename .. "' is missing a period in its name\n$  " .. file_path)
	end

	local entity_type = grug_filename:sub(dash_index + 1, period_index - 1)

	if entity_type == "" then
		error("Error: '" .. grug_filename .. "' is missing an entity type in its name\n$  " .. file_path)
	end

	check_custom_id_is_pascal(entity_type, file_path)

	return entity_type
end

function grug:_compile_grug_file(grug_file_relative_path)
	local grug_file_absolute_path = self.mods_dir_path .. "/" .. grug_file_relative_path

	local text = self.fs.read(grug_file_absolute_path)
	if text == "" then
		error("Error: File is empty\n$  " .. grug_file_relative_path)
	end

	local version = self.fs.get_file_version(grug_file_absolute_path, text)

	local tokens = tokenize(text, grug_file_relative_path)

	local ast = Parser.new(tokens, text, grug_file_relative_path):parse()

	local mod = grug_file_relative_path:match("([^/]+)")

	local filename = grug_file_relative_path:match("([^/]+)$")
	local entity_type = get_file_entity_type(filename, grug_file_relative_path)

	TypePropagator.new(ast, mod, entity_type, self.mod_api, text, grug_file_relative_path, self.mods_dir_path):fill()

	local global_variables, export_fns, local_fns = {}, {}, {}
	for _, stmt in ipairs(ast) do
		if stmt.stmt_type == "VariableStatement" then
			push(global_variables, stmt)
		elseif stmt.stmt_type == "OnFn" then
			export_fns[stmt.fn_name] = stmt
			stmt.fn_name = nil
		elseif stmt.stmt_type == "HelperFn" then
			local_fns[stmt.fn_name] = stmt
			stmt.fn_name = nil
		end
	end

	local host_fn_return_types = {}
	for name, decl in pairs(self.mod_api.host_functions) do
		host_fn_return_types[name] = decl.return_type
	end
	for class_name, class_def in pairs(self.mod_api.classes or {}) do
		for method_name, method_def in pairs(class_def.methods or {}) do
			host_fn_return_types[class_name .. "__" .. method_name] = method_def.return_type
		end
	end

	return GrugFile.new(
		grug_file_relative_path,
		mod,
		global_variables,
		export_fns,
		local_fns,
		self.host_fns,
		host_fn_return_types,
		self,
		version
	)
end

function grug:grug_to_json(input_grug_text, file_path) -- luacheck: ignore
	local tokens = tokenize(input_grug_text, file_path)
	local ast = Parser.new(tokens, input_grug_text, file_path):parse()
	return ast_to_json_text(ast)
end

function grug:json_to_grug(input_json_text) -- luacheck: ignore
	local ast = json.decode(input_json_text)
	return ast_to_grug(ast)
end

function grug:register_fn(name, fn)
	self.host_fns[name] = fn
end

-- Registers a method `fn` for `method_name` on class `class_name` (as declared
-- under mod_api.classes[class_name].methods). Internally this is stored in the
-- same table as register_fn(), under a mangled "ClassName__methodName" key, so
-- it's picked up automatically wherever host functions are injected.
function grug:register_method(class_name, method_name, fn)
	self.host_fns[class_name .. "__" .. method_name] = fn
end

local function assert_mod_api(mod_api)
	local entities = mod_api.entities
	if type(entities) ~= "table" then
		error(
			string.format("Error: 'entities' must be a JSON object, but got %s: %s", type(entities), tostring(entities))
		)
	end

	for entity_name, entity in pairs(entities) do
		if type(entity) ~= "table" then
			error(
				string.format(
					"Error: entity '%s' must be a JSON object, but got %s: %s",
					entity_name,
					type(entity),
					tostring(entity)
				)
			)
		end

		local export_functions = entity.export_functions
		if export_functions ~= nil and type(export_functions) ~= "table" then
			error(
				string.format(
					"Error: 'export_functions' for entity '%s' must be a JSON array, but got %s: %s",
					entity_name,
					type(export_functions),
					tostring(export_functions)
				)
			)
		end
	end

	local classes = mod_api.classes
	if classes ~= nil then
		if type(classes) ~= "table" then
			error(
				string.format(
					"Error: 'classes' must be a JSON object, but got %s: %s",
					type(classes),
					tostring(classes)
				)
			)
		end

		for class_name, class_def in pairs(classes) do
			if type(class_def) ~= "table" then
				error(
					string.format(
						"Error: class '%s' must be a JSON object, but got %s: %s",
						class_name,
						type(class_def),
						tostring(class_def)
					)
				)
			end

			local methods = class_def.methods
			if methods ~= nil and type(methods) ~= "table" then
				error(
					string.format(
						"Error: 'methods' for class '%s' must be a JSON object, but got %s: %s",
						class_name,
						type(methods),
						tostring(methods)
					)
				)
			end
		end
	end

	local host_functions = mod_api.host_functions
	if type(host_functions) ~= "table" then
		error(
			string.format(
				"Error: 'host_functions' must be a JSON object, but got %s: %s",
				type(host_functions),
				tostring(host_functions)
			)
		)
	end
end

function grug:get_transpiled_code()
	if not self._latest_transpiled_code then
		error("Error: get_transpiled_code() is only supported by transpiler backends.")
	end
	return self._latest_transpiled_code
end

local function default_runtime_error_handler(reason, grug_runtime_error_type, export_fn_name, export_fn_path) -- luacheck: ignore
	print("grug runtime error in " .. export_fn_name .. "(): " .. reason .. ", in " .. export_fn_path)
end

local bxor
-- Try LuaJIT
local has_bit, bit = pcall(require, "bit")
if has_bit then
	bxor = bit.bxor
else
	-- Try Lua 5.2
	local has_bit32, bit32 = pcall(require, "bit32")
	if has_bit32 then
		bxor = bit32.bxor
	else
		-- Try to compile Lua 5.3+ its bitwise XOR tilde operator
		local success, fn = pcall(loader, "return function(a,b) return a \126 b end")
		if success and fn then
			bxor = fn()
		else
			-- Last resort: Pure Lua XOR for Lua 5.1
			bxor = function(a, b)
				local res, c = 0, 1
				while a > 0 or b > 0 do
					local ra, rb = a % 2, b % 2
					if ra ~= rb then
						res = res + c
					end
					a, b, c = math.floor(a / 2), math.floor(b / 2), c * 2
				end
				return res
			end
		end
	end
end

local function hash_fnv_1a(_absolute_path, str)
	local hash = 2166136261

	for i = 1, #str do
		hash = bxor(hash, str:byte(i))
		hash = (hash * 16777619) % 2 ^ 32
	end

	return hash
end

function grug.init(settings)
	settings = settings or {}

	local runtime_error_handler = settings.runtime_error_handler or default_runtime_error_handler
	local mod_api_path = settings.mod_api_path or "mod_api.json"
	local mods_dir_path = settings.mods_dir_path or "mods"
	local export_fn_time_limit_ms = settings.export_fn_time_limit_ms or 100
	local packages = settings.packages or {}

	-- safe_mode=true (the default) means backends must intercept all runtime
	-- errors (STACK_OVERFLOW, TIME_LIMIT_EXCEEDED, GAME_FN_ERROR) and route
	-- them to runtime_error_handler instead of letting them propagate as raw
	-- Lua errors. Set to false only when you want the raw errors to surface
	-- (e.g. for certain test harness scenarios, or for performance).
	local safe_mode = settings.safe_mode ~= false

	-- This setting only has an effect on transpiler backends.
	-- Setting it to true tells transpilers to output a `transpiler_dump.lua`
	-- file to the current directory, before they load() it.
	local transpiler_dump = settings.transpiler_dump

	local fs = {}
	local sfs = settings.fs or {}

	-- Lua can't tell the mtime, so we hash by default.
	fs.get_file_version = sfs.get_file_version or hash_fnv_1a

	-- We use io.open() by default.
	fs.read = sfs.read or _read

	-- These are only optionally used by state:update().
	fs.list_dir = sfs.list_dir
	fs.is_dir = sfs.is_dir

	local mod_api_text = fs.read(mod_api_path)
	local mod_api = json.decode(mod_api_text)

	if type(mod_api) ~= "table" then
		error("Error: mod API JSON root must be an object")
	end

	assert_mod_api(mod_api)

	return setmetatable({
		runtime_error_handler = runtime_error_handler,
		mods_dir_path = mods_dir_path,
		export_fn_time_limit_ms = export_fn_time_limit_ms,
		packages = packages,
		fs = fs,
		mod_api = mod_api,
		host_fns = {},
		next_id = 0,
		fn_depth = 0,
		safe_mode = safe_mode,
		transpiler_dump = transpiler_dump,
		_mods = nil,
		_executed_file = nil,
		_executed_entity = nil,
		grug_files = settings.grug_files,
		backend = settings.backend or TranspilerBackend.new(),
	}, grug)
end
