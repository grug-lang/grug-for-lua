--
-- _InterpreterEntity: the interpreter's per-entity execution state.
-- This is the interpreter backend's internal representation of an entity.
-- It holds global/local variables and all the AST-walking logic.
-- An alternative backend stores its own data in GrugEntity.data instead.
--
local _InterpreterEntity = {}
_InterpreterEntity.__index = _InterpreterEntity

local MAX_DEPTH = 100

local BREAK = { type = "BREAK" }
local CONTINUE = { type = "CONTINUE" }
local RETURN = { type = "RETURN" }

local BINARY_OPS = {
	PLUS_TOKEN = function(l, r)
		return l + r
	end,
	MINUS_TOKEN = function(l, r)
		return l - r
	end,
	MULTIPLICATION_TOKEN = function(l, r)
		return l * r
	end,
	DIVISION_TOKEN = function(l, r)
		return l / r
	end,
	EQUALS_TOKEN = function(l, r)
		return l == r
	end,
	NOT_EQUALS_TOKEN = function(l, r)
		return l ~= r
	end,
	GREATER_OR_EQUAL_TOKEN = function(l, r)
		return l >= r
	end,
	GREATER_TOKEN = function(l, r)
		return l > r
	end,
	LESS_OR_EQUAL_TOKEN = function(l, r)
		return l <= r
	end,
	LESS_TOKEN = function(l, r)
		return l < r
	end,
}

local EXPECTED_TYPES = {
	number = "number",
	bool = "boolean",
	string = "string",
	resource = "string",
	entity = "string",
}

local function _get_expected_type(type_name)
	return EXPECTED_TYPES[type_name] or "table"
end

-- Create a new interpreter-entity for `grug_entity`.
-- May raise a Lua error if a runtime error occurs during global-variable
-- initialisation (e.g. STACK_OVERFLOW / TIME_LIMIT_EXCEEDED).
function _InterpreterEntity.new(grug_entity)
	local self = setmetatable({
		me_id = grug_entity.me_id,
		file = grug_entity.file,
		state = grug_entity.state,
		local_variables = {},
		on_fn_depth = 0,
		global_variables = {},
		fn_name = "",
		start_time = 0,
	}, _InterpreterEntity)

	self:_init_globals(grug_entity.file.global_variables)
	return self
end

function _InterpreterEntity:_init_globals_impl(global_variables)
	for _, g in ipairs(global_variables) do
		self.global_variables[g.name] = self:_run_expr(g.expr)
	end
end

local clock = os.clock

function _InterpreterEntity:_init_globals(global_variables)
	local old_executed_file = self.state._executed_file
	self.state._executed_file = self.file
	local old_executed_entity = self.state._executed_entity
	self.state._executed_entity = self

	self.fn_name = "init_globals"
	self.global_variables["me"] = { __grug_type = "id", value = self.me_id }

	local old_fn_depth = self.state.fn_depth
	self.state.fn_depth = self.state.fn_depth + 1
	self.start_time = clock()

	if not self.state.safe_mode then
		self:_init_globals_impl(global_variables)

		self.state.fn_depth = old_fn_depth

		self.state._executed_entity = old_executed_entity
		self.state._executed_file = old_executed_file

		return
	end

	local ok, err = pcall(self._init_globals_impl, self, global_variables)

	self.state.fn_depth = old_fn_depth

	self.state._executed_entity = old_executed_entity
	self.state._executed_file = old_executed_file

	if not ok then
		error(err)
	end
end

function _InterpreterEntity:_run_on_fn(on_fn_name, ...)
	local on_fn = self.file.on_fns[on_fn_name]
	if not on_fn then
		self._flow = {
			type = "ERROR",
			err = "The function '" .. on_fn_name .. "' is not defined by the file " .. self.file.relative_path,
		}
		return
	end

	local old_fn_name = self.fn_name
	self.fn_name = on_fn_name

	local old_executed_file = self.state._executed_file
	self.state._executed_file = self.file
	local old_executed_entity = self.state._executed_entity
	self.state._executed_entity = self

	local args = { ... }
	local parent_local_variables = self.local_variables
	self.local_variables = {}

	-- Assign and verify argument types
	for i, argument in ipairs(on_fn.arguments) do
		local arg = args[i]

		if self.state.safe_mode then
			local expected = _get_expected_type(argument.type_name)
			if type(arg) ~= expected then
				self.local_variables = parent_local_variables
				self._flow = {
					type = "ERROR",
					err = string.format(
						"Argument '%s' of %s() must be %s, got %s",
						argument.name,
						on_fn_name,
						argument.type_name,
						type(arg)
					),
				}
				return
			end
		end

		self.local_variables[argument.name] = arg
	end

	local old_fn_depth = self.state.fn_depth
	self.state.fn_depth = self.state.fn_depth + 1

	local old_on_fn_depth = self.on_fn_depth
	self.on_fn_depth = self.on_fn_depth + 1
	if self.on_fn_depth == 1 then
		self.start_time = clock()
	end

	self:_run_statements(on_fn.body_statements)

	-- Determine whether to propagate *before* restoring state
	local flow = self._flow
	local should_propagate = false
	if flow then
		local flow_type = type(flow) == "table" and flow.type
		if
			flow_type == "STACK_OVERFLOW"
			or flow_type == "TIME_LIMIT_EXCEEDED"
			or flow_type == "RERAISED_GAME_FN_ERROR"
		then
			should_propagate = self.state.fn_depth > 1
		elseif flow_type == "ERROR" then
			should_propagate = true
		end
		-- RETURN / BREAK / CONTINUE at on_fn level: consumed (not propagated)
	end

	self.state.fn_depth = old_fn_depth
	self.on_fn_depth = old_on_fn_depth
	self.local_variables = parent_local_variables

	self.fn_name = old_fn_name

	self.state._executed_entity = old_executed_entity
	self.state._executed_file = old_executed_file

	if not should_propagate then
		self._flow = nil
	end
	-- If should_propagate, self._flow stays set for the proxy to handle
end

function _InterpreterEntity:_run_statements(statements)
	for _, statement in ipairs(statements) do
		self:_run_statement(statement)
		if self._flow then
			return
		end
	end
end

function _InterpreterEntity:_run_statement(statement)
	local t = statement.stmt_type
	if t == "VariableStatement" then
		self:_run_variable_statement(statement)
	elseif t == "CallStatement" then
		self:_run_call_expr(statement.expr)
	elseif t == "IfStatement" then
		self:_run_if_statement(statement)
	elseif t == "ReturnStatement" then
		self:_run_return_statement(statement)
	elseif t == "WhileStatement" then
		self:_run_while_statement(statement)
	elseif t == "BreakStatement" then
		self._flow = BREAK
	elseif t == "ContinueStatement" then
		self._flow = CONTINUE
	end
end

function _InterpreterEntity:_run_variable_statement(statement)
	local value = self:_run_expr(statement.expr)
	if self.global_variables[statement.name] ~= nil then
		self.global_variables[statement.name] = value
	else
		self.local_variables[statement.name] = value
	end
end

function _InterpreterEntity:_run_expr(expr)
	local result
	if expr.bool_val ~= nil then
		result = expr.bool_val
	elseif expr.value ~= nil then
		result = expr.value
	elseif expr.string ~= nil then
		assert(type(expr.result) == "table")
		local typ = expr.result.type
		if typ == "STRING" then
			result = expr.string
		elseif typ == "RESOURCE" then
			result = self.file.mod .. "/" .. expr.string
		elseif typ == "ENTITY" then
			if string.find(expr.string, ":") then
				result = expr.string
			else
				result = self.file.mod .. ":" .. expr.string
			end
		end
	elseif expr.name ~= nil then
		if self.global_variables[expr.name] ~= nil then
			result = self.global_variables[expr.name]
		else
			result = self.local_variables[expr.name]
		end
	elseif expr.operator ~= nil then
		if expr.left_expr ~= nil then
			if expr.operator == "AND_TOKEN" or expr.operator == "OR_TOKEN" then
				result = self:_run_logical_expr(expr)
			else
				result = self:_run_binary_expr(expr)
			end
		else
			result = self:_run_unary_expr(expr)
		end
	elseif expr.fn_name ~= nil then
		result = self:_run_call_expr(expr)
	elseif expr.expr ~= nil then
		result = self:_run_expr(expr.expr)
	end

	if self._flow then
		return
	end
	return result
end

function _InterpreterEntity:_run_unary_expr(unary_expr)
	local val = self:_run_expr(unary_expr.expr)
	if self._flow then
		return
	end

	if unary_expr.operator == "MINUS_TOKEN" then
		return -val
	else
		assert(unary_expr.operator == "NOT_TOKEN")
		return not val
	end
end

function _InterpreterEntity:_run_binary_expr(binary_expr)
	local left = self:_run_expr(binary_expr.left_expr)
	if self._flow then
		return
	end

	local right = self:_run_expr(binary_expr.right_expr)
	if self._flow then
		return
	end

	return BINARY_OPS[binary_expr.operator](left, right)
end

function _InterpreterEntity:_run_logical_expr(logical_expr)
	local left = self:_run_expr(logical_expr.left_expr)
	if self._flow then
		return
	end

	if logical_expr.operator == "AND_TOKEN" then
		if not left then
			return false
		end
	else
		assert(logical_expr.operator == "OR_TOKEN")
		if left then
			return true
		end
	end

	local right = self:_run_expr(logical_expr.right_expr)
	if self._flow then
		return
	end
	return right
end

function _InterpreterEntity:_run_call_expr(call_expr)
	local args = {}
	for _, arg in ipairs(call_expr.arguments) do
		local val = self:_run_expr(arg)
		if self._flow then
			return
		end
		table.insert(args, val)
	end

	if string.sub(call_expr.fn_name, 1, 7) == "helper_" then
		return self:_run_helper_fn(call_expr.fn_name, args)
	else
		return self:_run_game_fn(call_expr.fn_name, args)
	end
end

function _InterpreterEntity:_run_if_statement(statement)
	if self:_run_expr(statement.condition) then
		self:_run_statements(statement.if_body)
	else
		self:_run_statements(statement.else_body)
	end
end

function _InterpreterEntity:_run_return_statement(statement)
	if statement.value then
		local val = self:_run_expr(statement.value)
		if self._flow then
			return
		end
		self._flow = { type = "RETURN", value = val }
	else
		self._flow = RETURN
	end
end

function _InterpreterEntity:_run_while_statement_impl(statement)
	while self:_run_expr(statement.condition) do
		self:_run_statements(statement.body_statements)

		if self._flow then
			if self._flow == CONTINUE then
				self._flow = nil -- Consume CONTINUE, keep looping
			else
				return -- BREAK / RETURN / error: propagate up
			end
		end

		if self.state.safe_mode then
			self:_check_time_limit_exceeded()
			if self._flow then
				return
			end
		end
	end
end

function _InterpreterEntity:_run_while_statement(statement)
	self:_run_while_statement_impl(statement)

	if self._flow == BREAK then
		self._flow = nil -- Consume BREAK
	end
	-- RETURN / errors propagate further
end

function _InterpreterEntity:_check_time_limit_exceeded()
	local limit_sec = self.file.state.on_fn_time_limit_ms / 1000
	if clock() - self.start_time > limit_sec then
		self.state.runtime_error_handler(
			string.format("Took longer than %g milliseconds to run", limit_sec * 1000),
			"TIME_LIMIT_EXCEEDED",
			self.fn_name,
			self.file.relative_path
		)
		self._flow = { type = "TIME_LIMIT_EXCEEDED" }
	end
end

function _InterpreterEntity:_run_helper_fn(name, args)
	local helper_fn = self.file.helper_fns[name]
	local parent_local_variables = self.local_variables
	self.local_variables = {}

	for i, argument in ipairs(helper_fn.arguments) do
		self.local_variables[argument.name] = args[i]
	end

	local old_fn_depth
	if self.state.safe_mode then
		old_fn_depth = self.state.fn_depth
		self.state.fn_depth = self.state.fn_depth + 1

		if self.state.fn_depth > MAX_DEPTH then
			self.state.runtime_error_handler(
				"Stack overflow, so check for accidental infinite recursion",
				"STACK_OVERFLOW",
				self.fn_name,
				self.file.relative_path
			)
			self.state.fn_depth = old_fn_depth
			self.local_variables = parent_local_variables
			self._flow = { type = "STACK_OVERFLOW" }
			return
		end

		self:_check_time_limit_exceeded()
		if self._flow then
			self.state.fn_depth = old_fn_depth
			self.local_variables = parent_local_variables
			return
		end
	end

	self:_run_statements(helper_fn.body_statements)

	if self.state.safe_mode then
		self.state.fn_depth = old_fn_depth
	end

	self.local_variables = parent_local_variables

	local flow = self._flow
	if flow then
		local flow_type = type(flow) == "table" and flow.type
		if flow_type == "RETURN" then
			self._flow = nil
			return flow.value -- Normal helper return.
		end
		-- Anything else (STACK_OVERFLOW, TIME_LIMIT, etc.): leave self._flow set.
	end
end

-- Cache for generated wrapper functions.
local _wrapper_cache = {}
local loader = loadstring or load

-- Every wrapper performs fixed-index access,
-- because LuaJIT 2.1 unfortunately stitches unpack():
-- https://github.com/tarantool/tarantool/wiki/LuaJIT-Not-Yet-Implemented
local function _get_wrapper(arg_count)
	if _wrapper_cache[arg_count] then
		return _wrapper_cache[arg_count]
	end

	local arg_list = {}
	for i = 1, arg_count do
		arg_list[i] = "args[" .. i .. "]"
	end

	-- If there are args, prefix the concatenated string with a comma.
	local args_str = #arg_list > 0 and (", " .. table.concat(arg_list, ", ")) or ""

	-- Generate a string like: "return function(fn, state, args) return fn(state, args[1], args[2]) end"
	local code = string.format("return function(fn, state, args) return fn(state%s) end", args_str)

	local wrapper = loader(code)()
	_wrapper_cache[arg_count] = wrapper
	return wrapper
end

function _InterpreterEntity:_run_game_fn(name, args)
	local game_fn = self.file.game_fns[name]
	assert(game_fn)

	-- Get or create a wrapper specific to this argument count.
	local wrapper = _get_wrapper(#args)

	-- Call directly (no pcall) so that LuaJIT can trace through game function
	-- calls without hitting "NYI: return to lower frame" at a C pcall boundary.
	-- Errors from game functions propagate up to InterpreterBackend:call_on_function,
	-- which wraps _run_on_fn in a pcall and handles GAME_FN_ERROR there.
	local result = wrapper(game_fn, self.state, args)

	local t = self.file.game_fn_return_types[name]
	if t == nil then
		return
	end

	if self.state.safe_mode then
		local expected = _get_expected_type(t)
		if type(result) ~= expected then
			self._flow = {
				type = "ERROR",
				err = string.format(
					"Return value of game function %s() must be %s, got %s",
					name,
					expected,
					type(result)
				),
			}
			return
		end
	end

	return result
end

--
-- Backend interface (duck-typed protocol):
--
--   backend:insert_file(new_file, existing_file_or_nil)
--     Called after _recompile_with_hot_reload compiles a file.
--     `existing_file` is the previous GrugFile when hot-reloading, nil otherwise.
--     The backend should migrate / reinitialise entity data as needed.
--
--   backend:init_entity(entity)
--     Called from GrugEntity.new after me_id, file, and state are set.
--     Must set entity.data to backend-specific per-entity state.
--     May raise a Lua error on runtime failure (e.g. STACK_OVERFLOW).
--
--   backend:call_on_function(entity, on_fn_name, ...)
--     Execute the named on_ function on entity with the given arguments.
--     Responsible for pcall, flow-error propagation, and GAME_FN_ERROR handling.
--     Should re-raise errors (including RERAISED_GAME_FN_ERROR) so callers can
--     catch them with their own pcall.
--
local InterpreterBackend = {}
InterpreterBackend.__index = InterpreterBackend

function InterpreterBackend.new()
	return setmetatable({}, InterpreterBackend)
end

-- Migrate entity data when a file is hot-reloaded.
-- For a fresh compile (existing_file == nil) this is a no-op.
function InterpreterBackend:insert_file(new_file, existing_file) -- luacheck: ignore
	if existing_file then
		for entity, _ in pairs(existing_file.entities or {}) do
			entity.file = new_file
			entity.data.file = new_file -- keep _InterpreterEntity in sync
			entity.data:_init_globals(new_file.global_variables)
			new_file.entities[entity] = true
		end
	end
end

-- Populate entity.data with a fresh _InterpreterEntity.
-- Raises a Lua error on runtime failure during global-variable initialisation.
function InterpreterBackend:init_entity(entity) -- luacheck: ignore
	entity.data = _InterpreterEntity.new(entity)
end

-- Execute `on_fn_name` on `entity` with the given arguments.
function InterpreterBackend:call_on_function(entity, on_fn_name, ...) -- luacheck: ignore
	local interp = entity.data

	if not interp.state.safe_mode then
		interp:_run_on_fn(on_fn_name, ...)
		return
	end

	local ok, err = pcall(interp._run_on_fn, interp, on_fn_name, ...)

	if not ok then
		interp._flow = nil

		-- In safe mode, game functions signal errors by throwing a table with
		-- type = "GAME_FN_ERROR"; route those to runtime_error_handler.
		-- When safe_mode is false the raw error is re-raised like any other.
		if type(err) == "table" and err.type == "GAME_FN_ERROR" then
			interp.state.runtime_error_handler(err.reason, "GAME_FN_ERROR", interp.fn_name, interp.file.relative_path)
			return
		end

		-- Any other Lua error (including RERAISED_GAME_FN_ERROR, STACK_OVERFLOW,
		-- TIME_LIMIT_EXCEEDED): re-raise so the caller's pcall can handle it.
		error(err, 0)
	end

	local flow = interp._flow
	if flow then
		interp._flow = nil
		error(flow.err or flow, 2)
	end
end

return InterpreterBackend
