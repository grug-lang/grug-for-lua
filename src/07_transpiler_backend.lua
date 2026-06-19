--
-- TranspilerBackend: compiles grug ASTs to Lua source strings and executes them
-- via load()/loadstring(), producing the same module shape as reference.lua.
--

local BINARY_OP_TO_LUA_XPILER = {
	PLUS_TOKEN = "+",
	MINUS_TOKEN = "-",
	MULTIPLICATION_TOKEN = "*",
	DIVISION_TOKEN = "/",
	EQUALS_TOKEN = "==",
	NOT_EQUALS_TOKEN = "~=",
	GREATER_OR_EQUAL_TOKEN = ">=",
	GREATER_TOKEN = ">",
	LESS_OR_EQUAL_TOKEN = "<=",
	LESS_TOKEN = "<",
}

local Transpiler = {}
Transpiler.__index = Transpiler

function Transpiler.new(file, safe_mode)
	-- Build the set of names that live in `e` (global-scope variables + implicit `me`).
	local globals = { me = true }
	for _, g in ipairs(file.global_variables) do
		globals[g.name] = true
	end
	return setmetatable({
		file = file,
		globals = globals,
		parts = {}, -- string fragments collected by :w()
		safe_mode = safe_mode,
	}, Transpiler)
end

-- Append a string fragment to the output buffer.
function Transpiler:w(s)
	self.parts[#self.parts + 1] = s
end

-- Escape special characters so the string is safe inside Lua double-quoted literals.
local function escape_str(s)
	return (s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t"))
end

-- ---------------------------------------------------------------------------
-- Expression emitter
-- ---------------------------------------------------------------------------

function Transpiler:emit_expr(expr)
	-- Boolean literal
	if expr.bool_val ~= nil then
		return tostring(expr.bool_val)
	end

	-- Number literal: use the original source string to preserve int vs float.
	if expr.value ~= nil then
		return expr.string
	end

	-- String / resource / entity literal
	if expr.string ~= nil then
		local res = expr.result
		local typ = (type(res) == "table") and res.type or string.upper(res)
		if typ == "STRING" then
			return '"' .. escape_str(expr.string) .. '"'
		elseif typ == "RESOURCE" then
			return '"' .. escape_str(self.file.mod .. "/" .. expr.string) .. '"'
		elseif typ == "ENTITY" then
			local s = expr.string
			if not s:find(":", 1, true) then
				s = self.file.mod .. ":" .. s
			end
			return '"' .. escape_str(s) .. '"'
		end
	end

	-- Function call (check before plain identifier to avoid false matches)
	if expr.fn_name ~= nil then
		return self:emit_call_expr(expr)
	end

	-- Plain identifier
	if expr.name ~= nil then
		if self.globals[expr.name] then
			return "e." .. expr.name
		else
			return expr.name
		end
	end

	-- Unary / binary / logical operator expression
	if expr.operator ~= nil then
		if expr.left_expr ~= nil then
			-- Binary or logical
			local op = expr.operator
			local left = self:emit_expr(expr.left_expr)
			local right = self:emit_expr(expr.right_expr)
			if op == "AND_TOKEN" then
				return "(" .. left .. " and " .. right .. ")"
			elseif op == "OR_TOKEN" then
				return "(" .. left .. " or " .. right .. ")"
			else
				return "(" .. left .. " " .. BINARY_OP_TO_LUA_XPILER[op] .. " " .. right .. ")"
			end
		else
			-- Unary
			local inner = self:emit_expr(expr.expr)
			if expr.operator == "MINUS_TOKEN" then
				return "(-" .. inner .. ")"
			else -- NOT_TOKEN
				return "(not " .. inner .. ")"
			end
		end
	end

	-- Parenthesised sub-expression
	assert(expr.expr ~= nil)
	return "(" .. self:emit_expr(expr.expr) .. ")"
end

-- Emit a call expression string, routing game-fn calls through `e.state`.
function Transpiler:emit_call_expr(expr)
	local fn_name = expr.fn_name
	local arg_strs = {}
	for _, arg in ipairs(expr.arguments) do
		arg_strs[#arg_strs + 1] = self:emit_expr(arg)
	end

	if fn_name:sub(1, 1) == "_" then
		-- Helper functions live in the fns table.
		return "fns." .. fn_name .. "(" .. table.concat(arg_strs, ", ") .. ")"
	else
		-- Game functions receive e.state as their first argument (the `_state` slot).
		local new_args = { "e.state" }
		for i = 1, #arg_strs do
			new_args[i + 1] = arg_strs[i]
		end
		arg_strs = new_args
		return fn_name .. "(" .. table.concat(arg_strs, ", ") .. ")"
	end
end

-- ---------------------------------------------------------------------------
-- Statement emitter
-- ---------------------------------------------------------------------------

function Transpiler:emit_stmts(stmts, indentation)
	for _, stmt in ipairs(stmts) do
		self:emit_stmt(stmt, indentation)
	end
end

function Transpiler:emit_stmt(stmt, indentation)
	local t = stmt.stmt_type

	if t == "VariableStatement" then
		local rhs = self:emit_expr(stmt.expr)
		if self.globals[stmt.name] then
			-- Assignment to a file-global variable (stored in `e`).
			self:w(indentation .. "e." .. stmt.name .. " = " .. rhs .. "\n")
		elseif stmt.type ~= nil then
			-- First declaration of a local variable (has an explicit type annotation).
			self:w(indentation .. "local " .. stmt.name .. " = " .. rhs .. "\n")
		else
			-- Re-assignment to an already-declared local.
			self:w(indentation .. stmt.name .. " = " .. rhs .. "\n")
		end
	elseif t == "CallStatement" then
		self:w(indentation .. self:emit_call_expr(stmt.expr) .. "\n")
	elseif t == "IfStatement" then
		self:w(indentation .. "if " .. self:emit_expr(stmt.condition) .. " then\n")
		self:emit_stmts(stmt.if_body, indentation .. "\t")
		if stmt.else_body and #stmt.else_body > 0 then
			self:w(indentation .. "else\n")
			self:emit_stmts(stmt.else_body, indentation .. "\t")
		end
		self:w(indentation .. "end\n")
	elseif t == "ReturnStatement" then
		if stmt.value then
			self:w(indentation .. "do return " .. self:emit_expr(stmt.value) .. " end\n")
		else
			self:w(indentation .. "do return end\n")
		end
	elseif t == "WhileStatement" then
		-- `continue` and `break` are both implemented via an inner
		-- `repeat ... until true` wrapper around the loop body.
		--
		-- A `continue` emits `do break end`, which exits only the inner
		-- repeat, so execution falls through to the `if _brk` check (which
		-- is false) and then loops back to re-evaluate the while condition.
		--
		-- A `break` emits `_brk = true` followed by `do break end`. After
		-- the repeat exits, `if _brk then break end` fires a real break on
		-- the outer while.
		--
		-- `_brk` is a `local` declared once per iteration, so nested while
		-- loops each have their own independent copy via Lua lexical scoping.
		--
		-- This is the standard Lua 5.1 compatible idiom since goto/labels
		-- are not available until Lua 5.2.
		self:w(indentation .. "while " .. self:emit_expr(stmt.condition) .. " do\n")
		self:w(indentation .. "\tlocal _brk = false\n")
		self:w(indentation .. "\trepeat\n")
		self:emit_stmts(stmt.body_statements, indentation .. "\t\t")
		self:w(indentation .. "\tuntil true\n")
		self:w(indentation .. "\tif _brk then break end\n")
		-- In safe mode, check the time limit after every iteration (including
		-- after a `continue`). Throw a table error so the outer pcall in
		-- call_on_function can recognise and route it to runtime_error_handler.
		if self.safe_mode then
			self:w(indentation .. "\tif _clock() - _start_time > _time_limit_sec then\n")
			self:w(
				indentation
					.. '\t\terror({ type = "TIME_LIMIT_EXCEEDED",'
					.. ' reason = string.format("Took longer than %g milliseconds to run", _time_limit_sec * 1000) }, 0)\n'
			)
			self:w(indentation .. "\tend\n")
		end
		self:w(indentation .. "end\n")
	elseif t == "BreakStatement" then
		-- Set the flag so the post-repeat check can fire a real `break` on
		-- the outer while, then exit the inner `repeat ... until true`.
		self:w(indentation .. "_brk = true\n")
		self:w(indentation .. "do break end\n")
	elseif t == "ContinueStatement" then
		-- Exit the inner `repeat ... until true` without setting `_brk`,
		-- so the outer while loop continues to its next iteration.
		self:w(indentation .. "do break end\n")

		-- EmptyLineStatement and CommentStatement are intentionally omitted.
	end
end

-- ---------------------------------------------------------------------------
-- Top-level code generation
-- ---------------------------------------------------------------------------

function Transpiler:emit_fn(fn_name, fn)
	local params = {}
	for _, arg in ipairs(fn.arguments) do
		params[#params + 1] = arg.name
	end

	self:w("function fns." .. fn_name .. "(" .. table.concat(params, ", ") .. ")\n")

	if self.safe_mode and fn_name:sub(1, 3) == "on_" and fn.needs_clock then
		self:w("\t_start_time = _clock()\n")
	elseif self.safe_mode and fn_name:sub(1, 1) == "_" then
		self:w("\tif _clock() - _start_time > _time_limit_sec then\n")
		self:w(
			'\t\terror({ type = "TIME_LIMIT_EXCEEDED",'
				.. ' reason = string.format("Took longer than %g milliseconds to run", _time_limit_sec * 1000) }, 0)\n'
		)
		self:w("\tend\n")
	end

	self:emit_stmts(fn.body_statements, "\t")
	self:w("end\n\n")
end

function Transpiler:generate()
	local used_host_fns = {}
	for _, g in ipairs(self.file.global_variables) do
		for k, _ in pairs(g.used_host_fns or {}) do
			used_host_fns[k] = true
		end
	end
	for _, fn in pairs(self.file.export_fns) do
		for k, _ in pairs(fn.used_host_fns or {}) do
			used_host_fns[k] = true
		end
	end
	for _, fn in pairs(self.file.local_fns) do
		for k, _ in pairs(fn.used_host_fns or {}) do
			used_host_fns[k] = true
		end
	end

	-- Sort names for deterministic output.
	local host_fn_names = {}
	for name in pairs(used_host_fns) do
		host_fn_names[#host_fn_names + 1] = name
	end
	table.sort(host_fn_names)

	-- 1. In safe mode, emit upvalues used by time-limit checks and on_ entry
	--    points. _clock is cached to avoid repeated global lookups.
	--    _start_time is reset at the top of every on_ call.
	--    _time_limit_sec is injected by fns.init() from deps._time_limit_sec.
	if self.safe_mode then
		self:w("local _clock = os.clock\n")
		self:w("local _start_time = 0\n")
		self:w("local _time_limit_sec = 0\n\n")
	end

	-- 2. Upvalue slots for every game function that is actually called.
	--    (Declaring these as locals before the functions that use them lets
	--    LuaJIT / Lua 5.1 access them as upvalues rather than globals.)
	for _, name in ipairs(host_fn_names) do
		self:w("local " .. name .. "\n")
	end
	self:w("\n")

	-- 3. The fns table that will be returned to the caller.
	self:w("local fns = {}\n\n")

	-- 4. Per-entity global-variable state table.
	--    All fields are initialised to nil here; their real values are set
	--    inside fns.init once the game-function upvalues have been injected.
	self:w("local e = {\n")
	self:w("\tstate = nil,\n")
	self:w("\tme = nil,\n")
	for _, g in ipairs(self.file.global_variables) do
		self:w("\t" .. g.name .. " = nil,\n")
	end
	self:w("}\n\n")

	-- 5. Helper functions (sorted for determinism; defined before on_ fns so
	--    on_ fns can call them via the fns table without forward-reference issues).
	local helper_names = {}
	for name in pairs(self.file.local_fns) do
		helper_names[#helper_names + 1] = name
	end
	table.sort(helper_names)
	for _, name in ipairs(helper_names) do
		self:emit_fn(name, self.file.local_fns[name])
	end

	-- 6. On functions (sorted for determinism).
	local export_fn_names = {}
	for name in pairs(self.file.export_fns) do
		export_fn_names[#export_fn_names + 1] = name
	end
	table.sort(export_fn_names)
	for _, name in ipairs(export_fn_names) do
		self:emit_fn(name, self.file.export_fns[name])
	end

	-- 7. init function: injects game-function upvalues and sets the entity ID.
	--    Global variable initialisers are also run here so that any game-
	--    function calls they contain (e.g. get_opponent()) execute after the
	--    upvalues have been assigned. The variables are evaluated in
	--    declaration order so that later globals can reference earlier ones
	--    (e.g. `bar = foo` works because e.foo is already set).
	--    In safe mode, deps._time_limit_sec is also read to populate the
	--    _time_limit_sec upvalue that while-loop time checks use.
	self:w("function fns.init(deps, state, me_id)\n")
	for _, name in ipairs(host_fn_names) do
		self:w("\t" .. name .. " = deps." .. name .. "\n")
	end
	if self.safe_mode then
		self:w("\t_time_limit_sec = deps._time_limit_sec\n")
	end
	self:w("\te.state = state\n")
	self:w('\te.me = { __grug_type = "id", value = me_id }\n')
	for _, g in ipairs(self.file.global_variables) do
		self:w("\te." .. g.name .. " = " .. self:emit_expr(g.expr) .. "\n")
	end
	self:w("end\n\n")

	-- 8. Return the module table.
	self:w("return fns\n")

	return table.concat(self.parts)
end

local function transpile_grug_file(file)
	return Transpiler.new(file, file.state.safe_mode):generate()
end

-- ---------------------------------------------------------------------------
-- TranspilerBackend: implements the backend duck-typed protocol
-- ---------------------------------------------------------------------------

local TranspilerBackend = {}
TranspilerBackend.__index = TranspilerBackend

function TranspilerBackend.new()
	return setmetatable({}, TranspilerBackend)
end

-- Called after _recompile_with_hot_reload compiles a new file.
-- Generates the Lua source for the file and, on hot reload, migrates existing entities.
function TranspilerBackend:insert_file(new_file, existing_file) -- luacheck: ignore
	new_file._transpiled_code = transpile_grug_file(new_file)

	-- This is used to diff against reference.lua files in benchmarks.
	new_file.state._latest_transpiled_code = new_file._transpiled_code

	if existing_file then
		for entity, _ in pairs(existing_file.entities or {}) do
			entity.file = new_file
			self:init_entity(entity)
			new_file.entities[entity] = true
		end
	end
end

local loader = loadstring or load

-- Populate entity.data with a fresh chunk execution (its own `e` upvalue closure).
function TranspilerBackend:init_entity(entity) -- luacheck: ignore
	-- Evict any rawset-cached on_ functions so new hot reloaded versions are used
	for k in pairs(entity) do
		if type(k) == "string" and k:sub(1, 3) == "on_" then
			rawset(entity, k, nil)
		end
	end

	local code = entity.file._transpiled_code

	-- Dump transpiled source to disk before loading, if requested.
	if entity.state.transpiler_dump then
		local dump_file = io.open("transpiler_dump.lua", "w")
		if dump_file then
			dump_file:write(code)
			dump_file:close()
		end
	end

	local chunk_fn, err = loader(code)

	if not chunk_fn then
		error("Failed to compile transpiled Lua:\n```lua\n" .. code .. "```\nLua error:\n" .. tostring(err))
	end

	local chunk = chunk_fn()

	-- Collect the game functions registered with the state.
	local deps = {}
	for name, fn in pairs(entity.file.host_fns) do
		deps[name] = fn
	end

	-- In safe mode the generated init function reads deps._time_limit_sec to
	-- populate the _time_limit_sec upvalue used by while-loop time checks.
	if entity.state.safe_mode then
		deps._time_limit_sec = entity.state.export_fn_time_limit_ms / 1000
	end

	local old_executed_file = entity.state._executed_file
	entity.state._executed_file = entity.file
	local old_executed_entity = entity.state._executed_entity
	entity.state._executed_entity = entity
	entity.fn_name = "init_globals"

	if entity.state.safe_mode then
		-- Wrap init in a pcall so that Lua stack overflows or GAME_FN_ERROR
		-- throws during global-variable initialisation are caught.
		local ok, init_err = pcall(chunk.init, deps, entity.state, entity.me_id)

		entity.state._executed_entity = old_executed_entity
		entity.state._executed_file = old_executed_file

		if not ok then
			if type(init_err) == "table" and init_err.type == "GAME_FN_ERROR" then
				entity.state.runtime_error_handler(init_err.reason, "GAME_FN_ERROR", "init", entity.file.relative_path)
			elseif type(init_err) == "string" and init_err:find("stack overflow", 1, true) then
				entity.state.runtime_error_handler(
					"Stack overflow, so check for accidental infinite recursion",
					"STACK_OVERFLOW",
					"init",
					entity.file.relative_path
				)
			else
				error(init_err, 0)
			end
		end
	else
		chunk.init(deps, entity.state, entity.me_id)

		entity.state._executed_entity = old_executed_entity
		entity.state._executed_file = old_executed_file
	end

	entity.data = chunk
end

local unsafe_export_fn_mt = {
	__call = function(t, _self, ...)
		return t.fn(...)
	end,
}

local safe_export_fn_mt = {
	__call = function(t, self, ...)
		return self.state.backend:call_on_function(self, t.key, ...)
	end,
}

function TranspilerBackend:get_export_fn(entity, key) -- luacheck: ignore
	if not entity.state.safe_mode then
		return setmetatable({ fn = entity.data[key] }, unsafe_export_fn_mt)
	else
		return setmetatable({ key = key }, safe_export_fn_mt)
	end
end

-- Execute the named on_ function on the entity.
function TranspilerBackend:call_on_function(entity, export_fn_name, ...) -- luacheck: ignore
	local fn = entity.data[export_fn_name]
	if not fn then
		error("The function '" .. export_fn_name .. "' is not defined by the file " .. entity.file.relative_path, 0)
	end

	-- When safe_mode is false the caller guarantees no bugs exist in any mod,
	-- so we skip the pcall entirely. Any Lua error (GAME_FN_ERROR, stack
	-- overflow, time limit, …) propagates raw to the caller.
	if not entity.state.safe_mode then
		fn(...)
		return
	end

	local old_fn_name = entity.fn_name
	entity.fn_name = export_fn_name
	local old_executed_file = entity.state._executed_file
	entity.state._executed_file = entity.file
	local old_executed_entity = entity.state._executed_entity
	entity.state._executed_entity = entity

	-- safe_mode=true: wrap in a pcall and route all runtime errors to
	-- runtime_error_handler so the game never crashes on bad mod code.
	local ok, err = pcall(fn, ...)

	entity.fn_name = old_fn_name
	entity.state._executed_entity = old_executed_entity
	entity.state._executed_file = old_executed_file

	if not ok then
		if type(err) == "table" and err.type == "GAME_FN_ERROR" then
			entity.state.runtime_error_handler(err.reason, "GAME_FN_ERROR", export_fn_name, entity.file.relative_path)
			return
		end
		-- Time-limit exceeded: generated while loops throw this table.
		if type(err) == "table" and err.type == "TIME_LIMIT_EXCEEDED" then
			entity.state.runtime_error_handler(
				err.reason,
				"TIME_LIMIT_EXCEEDED",
				export_fn_name,
				entity.file.relative_path
			)
			return
		end
		-- Stack overflow: Lua itself throws a string containing "stack overflow".
		-- The pcall here is the outer pcall that the recursion unwinds to;
		-- no explicit depth tracking is needed in the transpiled code.
		if type(err) == "string" and err:find("stack overflow", 1, true) then
			entity.state.runtime_error_handler(
				"Stack overflow, so check for accidental infinite recursion",
				"STACK_OVERFLOW",
				export_fn_name,
				entity.file.relative_path
			)
			return
		end
		error(err, 0)
	end
end
