local Entity = {}

local MAX_DEPTH = 100

local BREAK = { type = "BREAK" }
local CONTINUE = { type = "CONTINUE" }
local RETURN = { type = "RETURN" }

local unpack = unpack or table.unpack

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

function Entity.new(file)
	local self = setmetatable({
		me_id = file.state.next_id,
		file = file,
		state = file.state,
		local_variables = {},
		on_fn_depth = 0,
		global_variables = {},
		fn_name = "",
		start_time = 0,
	}, Entity)

	file.entities[self] = true

	file.state.next_id = file.state.next_id + 1
	self:_init_globals(file.global_variables)
	return self
end

function Entity:_init_globals_impl(global_variables)
	for _, g in ipairs(global_variables) do
		self.global_variables[g.name] = self:_run_expr(g.expr)
	end
end

function Entity:_init_globals(global_variables)
	self.fn_name = "init_globals"
	self.global_variables["me"] = { __grug_type = "id", value = self.me_id }

	local old_fn_depth = self.state.fn_depth
	self.state.fn_depth = self.state.fn_depth + 1
	self.start_time = os.clock()

	local ok, err = pcall(self._init_globals_impl, self, global_variables)

	self.state.fn_depth = old_fn_depth

	if not ok then
		error(err)
	end
end

-- Callable proxy used by Entity:__index to avoid closures (LuaJIT NYI: UCLO).
-- Stores the method key as a table field; __call dispatches to _run_on_fn.
local _on_fn_proxy_mt = {
	__call = function(t, self2, ...)
		self2:_run_on_fn(t._key, ...)
		local flow = self2._flow
		if flow then
			self2._flow = nil
			error(flow.err or flow)
		end
	end,
}
local _on_fn_proxy_cache = {}

-- This allows calling on_ functions defined in the grug file (e.g., dog:on_spawn()).
function Entity:__index(key) -- luacheck: ignore
	local val = rawget(Entity, key)
	if val ~= nil then
		return val
	end

	if type(key) == "string" and string.sub(key, 1, 3) == "on_" then
		local proxy = _on_fn_proxy_cache[key]
		if proxy == nil then
			proxy = setmetatable({ _key = key }, _on_fn_proxy_mt)
			_on_fn_proxy_cache[key] = proxy
		end
		return proxy
	end
end

local function _get_expected_type(type_name)
	return EXPECTED_TYPES[type_name] or "table"
end

function Entity:_run_on_fn(on_fn_name, ...)
	local on_fn = self.file.on_fns[on_fn_name]
	if not on_fn then
		self._flow = {
			type = "ERROR",
			err = "The function '" .. on_fn_name .. "' is not defined by the file " .. self.file.relative_path,
		}
		return
	end

	local args = { ... }
	local parent_local_variables = self.local_variables
	self.local_variables = {}
	self.fn_name = on_fn_name

	-- Assign and verify argument types
	for i, argument in ipairs(on_fn.arguments) do
		local arg = args[i]
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
		self.local_variables[argument.name] = arg
	end

	local old_fn_depth = self.state.fn_depth
	self.state.fn_depth = self.state.fn_depth + 1

	local old_on_fn_depth = self.on_fn_depth
	self.on_fn_depth = self.on_fn_depth + 1
	if self.on_fn_depth == 1 then
		self.start_time = os.clock()
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

	if not should_propagate then
		self._flow = nil
	end
	-- If should_propagate, self._flow stays set for the proxy to handle
end

function Entity:_run_statements(statements)
	for _, statement in ipairs(statements) do
		self:_run_statement(statement)
		if self._flow then
			return
		end
	end
end

function Entity:_run_statement(statement)
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

function Entity:_run_variable_statement(statement)
	local value = self:_run_expr(statement.expr)
	if self.global_variables[statement.name] ~= nil then
		self.global_variables[statement.name] = value
	else
		self.local_variables[statement.name] = value
	end
end

function Entity:_run_expr(expr)
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

function Entity:_run_unary_expr(unary_expr)
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

function Entity:_run_binary_expr(binary_expr)
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

function Entity:_run_logical_expr(logical_expr)
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

function Entity:_run_call_expr(call_expr)
	local args = {}
	for _, arg in ipairs(call_expr.arguments) do
		local val = self:_run_expr(arg)
		if self._flow then
			return
		end
		table.insert(args, val)
	end

	if string.sub(call_expr.fn_name, 1, 7) == "helper_" then
		return self:_run_helper_fn(call_expr.fn_name, unpack(args))
	else
		return self:_run_game_fn(call_expr.fn_name, unpack(args))
	end
end

function Entity:_run_if_statement(statement)
	if self:_run_expr(statement.condition) then
		self:_run_statements(statement.if_body)
	else
		self:_run_statements(statement.else_body)
	end
end

function Entity:_run_return_statement(statement)
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

function Entity:_run_while_statement_impl(statement)
	while self:_run_expr(statement.condition) do
		self:_run_statements(statement.body_statements)

		if self._flow then
			if self._flow == CONTINUE then
				self._flow = nil -- Consume CONTINUE, keep looping
			else
				return -- BREAK / RETURN / error: propagate up
			end
		end

		self:_check_time_limit_exceeded()
		if self._flow then
			return
		end
	end
end

function Entity:_run_while_statement(statement)
	self:_run_while_statement_impl(statement)

	if self._flow == BREAK then
		self._flow = nil -- Consume BREAK
	end
	-- RETURN / errors propagate further
end

function Entity:_check_time_limit_exceeded()
	local limit_sec = self.file.state.on_fn_time_limit_ms / 1000
	if os.clock() - self.start_time > limit_sec then
		self.state.runtime_error_handler(
			string.format("Took longer than %g milliseconds to run", limit_sec * 1000),
			"TIME_LIMIT_EXCEEDED",
			self.fn_name,
			self.file.relative_path
		)
		self._flow = { type = "TIME_LIMIT_EXCEEDED" }
	end
end

function Entity:_run_helper_fn(name, ...)
	local helper_fn = self.file.helper_fns[name]
	local args = { ... }
	local parent_local_variables = self.local_variables
	self.local_variables = {}

	for i, argument in ipairs(helper_fn.arguments) do
		self.local_variables[argument.name] = args[i]
	end

	local old_fn_depth = self.state.fn_depth
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

	self:_run_statements(helper_fn.body_statements)

	self.state.fn_depth = old_fn_depth
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

function Entity:_run_game_fn(name, ...)
	local game_fn = self.file.game_fns[name]
	assert(game_fn)

	local parent_fn_name = self.fn_name
	local ok, result = pcall(game_fn, self.state, ...)

	if not ok then
		if result.type == "GAME_FN_ERROR" then
			self.state.runtime_error_handler(result.reason, "GAME_FN_ERROR", parent_fn_name, self.file.relative_path)
			self._flow = { type = "RERAISED_GAME_FN_ERROR" }
		else
			-- We don't want to call runtime_error_handler()
			-- a second time on game function errors.
			self._flow = { type = "ERROR", err = result }
		end
		return
	end

	self.fn_name = parent_fn_name

	local t = self.file.game_fn_return_types[name]
	if t == nil then
		return
	end

	local expected = _get_expected_type(t)
	if type(result) ~= expected then
		self._flow = {
			type = "ERROR",
			err = string.format("Return value of game function %s() must be %s, got %s", name, expected, type(result)),
		}
		return
	end

	return result
end
