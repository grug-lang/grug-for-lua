-- --------------------------------------------------------------------------
-- Data Structures
-- --------------------------------------------------------------------------

local function Variable(name, t, tname)
	return { name = name, type = t, type_name = tname }
end

local function Argument(name, t, tname, resource_extension, entity_type)
	return {
		name = name,
		type = t,
		type_name = tname,
		resource_extension = resource_extension,
		entity_type = entity_type,
	}
end

local function GameFn(fn_name, arguments, return_type, return_type_name)
	return {
		fn_name = fn_name,
		arguments = arguments or {},
		return_type = return_type,
		return_type_name = return_type_name,
	}
end

-- --------------------------------------------------------------------------
-- Helpers
-- --------------------------------------------------------------------------

local function parse_args(lst)
	local args = {}
	for _, obj in ipairs(lst or {}) do
		push(args, Argument(obj.name, get_type(obj.type), obj.type, obj.resource_extension, obj.entity_type))
	end
	return args
end

local function parse_host_fn(fn_name, fn)
	return GameFn(fn_name, parse_args(fn.arguments), fn.return_type and get_type(fn.return_type) or nil, fn.return_type)
end

-- --------------------------------------------------------------------------
-- TypePropagator Class
-- --------------------------------------------------------------------------

local TypePropagator = {}
TypePropagator.__index = TypePropagator

function TypePropagator.new(ast, mod, entity_type, mod_api, src, file_path)
	local self = setmetatable({
		ast = ast,
		mod = mod,
		file_entity_type = entity_type,
		mod_api = mod_api,
		src = src,
		file_path = file_path,
		export_fns = {},
		local_fns = {},
		fn_return_type = nil,
		fn_return_type_name = nil,
		filled_fn_name = nil,
		local_variables = {},
		global_variables = {},
		host_functions = {},
		entity_export_functions = {},
	}, TypePropagator)

	for _, s in ipairs(ast) do
		if s.stmt_type == "OnFn" then
			self.export_fns[s.fn_name] = s
		elseif s.stmt_type == "HelperFn" then
			self.local_fns[s.fn_name] = s
		end
	end

	if mod_api.host_functions then
		for fn_name, fn in pairs(mod_api.host_functions) do
			self.host_functions[fn_name] = parse_host_fn(fn_name, fn)
		end
	end

	local entity_cfg = mod_api.entities and mod_api.entities[entity_type]
	if entity_cfg and entity_cfg.export_functions then
		self.entity_export_functions = entity_cfg.export_functions
	end

	return self
end

-- Builds an error message pointing at `span` (a table with `line` and `pos` fields).
function TypePropagator:new_error(msg, span)
	local current_function = self.filled_fn_name or "member scope"

	local line = span and span.line
	local column = span and span.pos and get_column(self.src, span.pos)
	local source_line = span and span.pos and get_source_line(self.src, span.pos)

	return string.format(
		"  in %s (%s:%d:%d)\nError: %s\n%d $ %s",
		current_function,
		self.file_path,
		line,
		column,
		msg,
		line,
		source_line
	)
end

-- --------------------------------------------------------------------------
-- Variable Management
-- --------------------------------------------------------------------------

function TypePropagator:get_variable(name)
	return self.local_variables[name] or self.global_variables[name]
end

function TypePropagator:add_global_variable(name, var_type, type_name)
	self.global_variables[name] = Variable(name, var_type, type_name)
end

function TypePropagator:add_local_variable(name, var_type, type_name, span)
	if self.local_variables[name] then
		if span then
			error(self:new_error("The local variable '" .. name .. "' shadows an earlier local variable", span))
		else
			error("The local variable '" .. name .. "' shadows an earlier local variable")
		end
	end
	if self.global_variables[name] then
		if span then
			error(self:new_error("The local variable '" .. name .. "' shadows an earlier global variable", span))
		else
			error("The local variable '" .. name .. "' shadows an earlier global variable")
		end
	end
	self.local_variables[name] = Variable(name, var_type, type_name)
end

function TypePropagator:add_argument_variables(arguments)
	self.local_variables = {}
	for _, arg in ipairs(arguments) do
		self:add_local_variable(arg.name, arg.type, arg.type_name, arg.span)
	end
end

-- --------------------------------------------------------------------------
-- Validation Logic
-- --------------------------------------------------------------------------

local function are_incompatible_types(first_type, first_type_name, second_type, second_type_name)
	if first_type ~= second_type then
		return true
	end
	if (first_type_name == "id" and second_type == "ID") or (first_type_name == second_type_name) then
		return false
	end
	return true
end

local function check_chars(self, s, label, str, span)
	for i = 1, #s do
		local c = string.sub(s, i, i)
		if not (string.match(c, "%l") or string.match(c, "%d") or c == "_" or c == "-") then
			error(
				self:new_error(
					"Entity '" .. str .. "' its " .. label .. " name contains the invalid character '" .. c .. "'",
					span
				)
			)
		end
	end
end

function TypePropagator:validate_entity_string(str, span)
	if not str or str == "" then
		error(self:new_error("Entities can't be empty strings", span))
	end

	local mod, entity_name = self.mod, str
	local colon_pos = string.find(str, ":")

	if colon_pos then
		if colon_pos == 1 then
			error(self:new_error("Entity '" .. str .. "' is missing a mod name", span))
		end

		mod = string.sub(str, 1, colon_pos - 1)
		entity_name = string.sub(str, colon_pos + 1)

		if entity_name == "" then
			error(self:new_error("Entity '" .. str .. "' missing entity name", span))
		end
		if mod == self.mod then
			error(self:new_error("Entity string ('" .. str .. "') cannot refer to its own mod", span))
		end
	end

	check_chars(self, mod, "mod", str, span)
	check_chars(self, entity_name, "entity", str, span)
end

function TypePropagator:validate_resource_string(str, resource_extension, span)
	if not str or str == "" then
		error(self:new_error("Resources can't be empty strings", span))
	end
	if string.sub(str, 1, 1) == "/" then
		error(self:new_error('Remove the leading slash from the resource "' .. str .. '"', span))
	end
	if string.sub(str, -1) == "/" then
		error(self:new_error('Remove the trailing slash from the resource "' .. str .. '"', span))
	end
	if string.find(str, "\\", 1, true) then
		error(self:new_error("Replace the '\\' with '/' in the resource \"" .. str .. '"', span))
	end
	if string.find(str, "//", 1, true) then
		error(self:new_error("Replace the '//' with '/' in the resource \"" .. str .. '"', span))
	end

	-- Check for single '.'
	local dot_index = string.find(str, "%.")
	if dot_index then
		if dot_index == 1 then
			if #str == 1 or string.sub(str, 2, 2) == "/" then
				error(self:new_error("Remove the '.' from the resource \"" .. str .. '"', span))
			end
		elseif string.sub(str, dot_index - 1, dot_index - 1) == "/" then
			if dot_index + 1 > #str or string.sub(str, dot_index + 1, dot_index + 1) == "/" then
				error(self:new_error("Remove the '.' from the resource \"" .. str .. '"', span))
			end
		end
	end

	-- Check for double '..'
	local dotdot_index = string.find(str, "%.%.")
	if dotdot_index then
		if dotdot_index == 1 then
			if #str == 2 or string.sub(str, 3, 3) == "/" then
				error(self:new_error("Remove the '..' from the resource \"" .. str .. '"', span))
			end
		elseif string.sub(str, dotdot_index - 1, dotdot_index - 1) == "/" then
			if dotdot_index + 2 > #str or string.sub(str, dotdot_index + 2, dotdot_index + 2) == "/" then
				error(self:new_error("Remove the '..' from the resource \"" .. str .. '"', span))
			end
		end
	end

	if string.sub(str, -1) == "." then
		error(self:new_error('resource name "' .. str .. '" cannot end with .', span))
	end

	if resource_extension and resource_extension ~= "" then
		if string.sub(str, -#resource_extension) ~= resource_extension then
			error(
				self:new_error(
					"The resource '" .. str .. "' was supposed to have the extension '" .. resource_extension .. "'",
					span
				)
			)
		end
	end

	error(self:new_error("resource '" .. str .. "' does not exist", span))
end

-- --------------------------------------------------------------------------
-- Expression & Statement Filling
-- --------------------------------------------------------------------------

function TypePropagator:check_arguments(params, call_expr)
	local fn_name, args = call_expr.fn_name, call_expr.arguments

	if #args < #params then
		error(
			self:new_error(
				"Function call '"
					.. fn_name
					.. "' expected the argument '"
					.. params[#args + 1].name
					.. "' with type "
					.. params[#args + 1].type_name,
				call_expr.span
			)
		)
	end
	if #args > #params then
		error(
			self:new_error(
				"Function call '"
					.. fn_name
					.. "' got an unexpected extra argument with type "
					.. tostring(args[#params + 1].result.type_name),
				args[#params + 1].span or call_expr.span
			)
		)
	end

	for i, arg in ipairs(args) do
		local param = params[i]
		local is_string = arg.string ~= nil and arg.result.type == "STRING"

		if is_string then
			if param.type == "ENTITY" then
				error(
					self:new_error(
						"The host function '"
							.. fn_name
							.. "' expects an entity string, so put an 'e' in front of string \""
							.. arg.string
							.. '"',
						arg.span
					)
				)
			elseif param.type == "RESOURCE" then
				error(
					self:new_error(
						"The host function '"
							.. fn_name
							.. "' expects a resource string, so put an 'r' in front of string \""
							.. arg.string
							.. '"',
						arg.span
					)
				)
			end
		end

		if arg.string ~= nil then
			if arg.result.type == "ENTITY" then
				self:validate_entity_string(arg.string, arg.span)
			elseif arg.result.type == "RESOURCE" then
				self:validate_resource_string(arg.string, param.resource_extension, arg.span)
			end
		end

		if not arg.result or not arg.result.type then
			error(
				self:new_error(
					"Function call '"
						.. fn_name
						.. "' expected the type "
						.. param.type_name
						.. " for argument '"
						.. param.name
						.. "', but got a function call that doesn't return anything",
					arg.span
				)
			)
		end

		if are_incompatible_types(param.type, param.type_name, arg.result.type, arg.result.type_name) then
			error(
				self:new_error(
					"Function call '"
						.. fn_name
						.. "' expected the type "
						.. param.type_name
						.. " for argument '"
						.. param.name
						.. "', but got "
						.. arg.result.type_name,
					arg.span
				)
			)
		end
	end
end

function TypePropagator:fill_call_expr(expr)
	for _, arg in ipairs(expr.arguments) do
		self:fill_expr(arg)
	end

	local fn_name = expr.fn_name
	local target_fn = self.local_fns[fn_name] or self.host_functions[fn_name]

	if target_fn then
		expr.result = { type = target_fn.return_type, type_name = target_fn.return_type_name }
		self:check_arguments(target_fn.arguments, expr)

		if self.host_functions[fn_name] then
			if self.current_fn then
				self.current_fn.used_host_fns[fn_name] = true
			elseif self.current_global then
				self.current_global.used_host_fns[fn_name] = true
			end
		elseif self.local_fns[fn_name] then
			if self.current_fn then
				self.current_fn.needs_clock = true
			end
		end

		return
	end

	if self.export_fns[fn_name] then
		error(self:new_error("Mods aren't allowed to call their own export functions", expr.span))
	elseif string.sub(fn_name, 1, 3) == "on_" then
		error("Mods aren't allowed to call their own on_ functions, but '" .. fn_name .. "' was called")
	elseif string.sub(fn_name, 1, 1) == "_" then
		error(self:new_error("The local function '" .. fn_name .. "' was not defined by this grug file", expr.span))
	end

	error(self:new_error("The game function '" .. fn_name .. "' was not declared by mod_api.json", expr.span))
end

local OPERATOR_STR = {
	GREATER_OR_EQUAL_TOKEN = ">=",
	GREATER_TOKEN = ">",
	LESS_OR_EQUAL_TOKEN = "<=",
	LESS_TOKEN = "<",
	EQUALS_TOKEN = "==",
	NOT_EQUALS_TOKEN = "!=",
	AND_TOKEN = "and",
	OR_TOKEN = "or",
	PLUS_TOKEN = "+",
	MINUS_TOKEN = "-",
	MULTIPLICATION_TOKEN = "*",
	DIVISION_TOKEN = "/",
	NOT_TOKEN = "not",
}

function TypePropagator:fill_binary_expr(expr)
	local left, right, op = expr.left_expr, expr.right_expr, expr.operator
	self:fill_expr(left)
	self:fill_expr(right)

	if left.result.type == "STRING" and op ~= "EQUALS_TOKEN" and op ~= "NOT_EQUALS_TOKEN" then
		if op == "PLUS_TOKEN" then
			if left.result.type_name == right.result.type_name then
				error(self:new_error("cannot add strings with '+'", expr.op_span))
			else
				error(
					self:new_error(
						"The left and right operand of a binary expression ('"
							.. (OPERATOR_STR[op] or op)
							.. "') must have the same type, but got "
							.. tostring(left.result.type_name)
							.. " and "
							.. tostring(right.result.type_name),
						expr.op_span
					)
				)
			end
		else
			error(
				self:new_error(
					"You can't use the '" .. (OPERATOR_STR[op] or op) .. "' operator on strings",
					expr.op_span
				)
			)
		end
	end

	local is_id = (left.result.type_name == "id" or right.result.type_name == "id")
	if not is_id and left.result.type_name ~= right.result.type_name then
		error(
			self:new_error(
				"The left and right operand of a binary expression ('"
					.. (OPERATOR_STR[op] or op)
					.. "') must have the same type, but got "
					.. tostring(left.result.type_name)
					.. " and "
					.. tostring(right.result.type_name),
				expr.op_span
			)
		)
	end

	expr.result = {}

	if op == "EQUALS_TOKEN" or op == "NOT_EQUALS_TOKEN" then
		expr.result.type, expr.result.type_name = "BOOL", "bool"
	elseif
		op == "GREATER_OR_EQUAL_TOKEN"
		or op == "GREATER_TOKEN"
		or op == "LESS_OR_EQUAL_TOKEN"
		or op == "LESS_TOKEN"
	then
		if left.result.type ~= "NUMBER" then
			error(self:new_error("'" .. (OPERATOR_STR[op] or op) .. "' operator expects number", expr.op_span))
		end

		expr.result.type, expr.result.type_name = "BOOL", "bool"
	elseif op == "AND_TOKEN" or op == "OR_TOKEN" then
		if left.result.type ~= "BOOL" then
			error(self:new_error("'" .. (OPERATOR_STR[op] or op) .. "' operator expects bool", expr.op_span))
		end

		expr.result.type, expr.result.type_name = "BOOL", "bool"
	else
		if left.result.type ~= "NUMBER" then
			error(self:new_error("'" .. (OPERATOR_STR[op] or op) .. "' operator expects number", expr.op_span))
		end

		expr.result.type, expr.result.type_name = left.result.type, left.result.type_name
	end
end

function TypePropagator:fill_expr(expr)
	if type(expr.result) == "string" then
		expr.result = { type_name = expr.result, type = string.upper(expr.result) }
		return
	end

	expr.result = expr.result or {}

	if expr.name and not expr.fn_name then
		local var = self:get_variable(expr.name)
		if not var then
			error(self:new_error("The variable '" .. expr.name .. "' does not exist", expr.span))
		end
		expr.result.type, expr.result.type_name = var.type, var.type_name
	elseif expr.operator and not expr.left_expr then
		local op, inner = expr.operator, expr.expr
		if inner.operator == op and not inner.left_expr then
			error(
				self:new_error(
					"Found '"
						.. (OPERATOR_STR[op] or op)
						.. "' directly next to another '"
						.. (OPERATOR_STR[op] or op)
						.. "', which can be simplified by just removing both of them",
					expr.op_span
				)
			)
		end
		self:fill_expr(inner)
		expr.result.type, expr.result.type_name = inner.result.type, inner.result.type_name
		if op == "NOT_TOKEN" then
			if expr.result.type ~= "BOOL" then
				error(
					self:new_error(
						"Found 'not' before "
							.. tostring(expr.result.type_name)
							.. ", but it can only be put before a bool",
						expr.op_span
					)
				)
			end
		elseif expr.result.type ~= "NUMBER" then
			error(
				self:new_error(
					"Found '-' before " .. tostring(expr.result.type_name) .. ", but it can only be put before a number",
					expr.op_span
				)
			)
		end
	elseif expr.operator and expr.left_expr then
		self:fill_binary_expr(expr)
	elseif expr.fn_name then
		self:fill_call_expr(expr)
	elseif expr.expr and not expr.operator then
		self:fill_expr(expr.expr)
		expr.result.type, expr.result.type_name = expr.expr.result.type, expr.expr.result.type_name
	end
end

function TypePropagator:fill_statements(statements)
	for _, stmt in ipairs(statements) do
		local stype = stmt.stmt_type
		if stype == "VariableStatement" then
			self:fill_expr(stmt.expr)
			local var = self:get_variable(stmt.name)
			if stmt.type then
				if
					are_incompatible_types(stmt.type, stmt.type_name, stmt.expr.result.type, stmt.expr.result.type_name)
				then
					error(
						self:new_error(
							"Can't assign "
								.. tostring(stmt.expr.result.type_name)
								.. " to '"
								.. stmt.name
								.. "', which has type "
								.. tostring(stmt.type_name),
							stmt.expr_span
						)
					)
				end
				self:add_local_variable(stmt.name, stmt.type, stmt.type_name, stmt.decl_span)
			else
				if not var then
					error(
						self:new_error(
							"Can't assign to the variable '" .. stmt.name .. "', since it does not exist",
							stmt.decl_span
						)
					)
				end
				if self.global_variables[stmt.name] and var.type == "ID" then
					error(self:new_error("Global id variables can't be reassigned", stmt.expr_span))
				end
				if
					are_incompatible_types(
						var.type,
						var.name == "me" and self.file_entity_type or var.type_name,
						stmt.expr.result.type,
						stmt.expr.result.type_name
					)
				then
					error(
						self:new_error(
							"Can't assign "
								.. tostring(stmt.expr.result.type_name)
								.. " to '"
								.. var.name
								.. "', which has type "
								.. tostring(var.type_name),
							stmt.expr_span
						)
					)
				end
			end
		elseif stype == "CallStatement" then
			self:fill_call_expr(stmt.expr)
		elseif stype == "IfStatement" then
			self:fill_expr(stmt.condition)
			if stmt.condition.result.type ~= "BOOL" then
				error(
					self:new_error(
						"If condition must be bool but got '" .. stmt.condition.result.type_name .. "'",
						stmt.condition.span or stmt.condition.op_span
					)
				)
			end
			self:fill_statements(stmt.if_body)
			if stmt.else_body and #stmt.else_body > 0 then
				self:fill_statements(stmt.else_body)
			end
		elseif stype == "WhileStatement" then
			if self.current_fn then
				self.current_fn.needs_clock = true
			end
			self:fill_expr(stmt.condition)
			if stmt.condition.result.type ~= "BOOL" then
				error(
					self:new_error(
						"While condition must be bool but got '" .. stmt.condition.result.type_name .. "'",
						stmt.condition.span or stmt.condition.op_span
					)
				)
			end
			self:fill_statements(stmt.body_statements)
		elseif stype == "ReturnStatement" then
			if stmt.value then
				self:fill_expr(stmt.value)
				if not self.fn_return_type then
					error(
						self:new_error(
							"Function '" .. tostring(self.filled_fn_name) .. "' wasn't supposed to return any value",
							stmt.value.span
						)
					)
				end
				if
					are_incompatible_types(
						self.fn_return_type,
						self.fn_return_type_name,
						stmt.value.result.type,
						stmt.value.result.type_name
					)
				then
					error(
						self:new_error(
							"Function '"
								.. tostring(self.filled_fn_name)
								.. "' is supposed to return "
								.. tostring(self.fn_return_type_name)
								.. ", not "
								.. tostring(stmt.value.result.type_name),
							stmt.value.span
						)
					)
				end
			elseif self.fn_return_type then
				error(
					self:new_error(
						"Function '"
							.. tostring(self.filled_fn_name)
							.. "' is supposed to return a value of type "
							.. tostring(self.fn_return_type_name),
						stmt.span
					)
				)
			end
		end
	end

	for _, stmt in ipairs(statements) do
		if stmt.stmt_type == "VariableStatement" and stmt.type then
			self.local_variables[stmt.name] = nil
		end
	end
end

-- --------------------------------------------------------------------------
-- Global & Function Lifecycle
-- --------------------------------------------------------------------------

function TypePropagator:check_global_expr(expr, name)
	if expr.operator then
		if not expr.left_expr then
			self:check_global_expr(expr.expr, name)
		else
			self:check_global_expr(expr.left_expr, name)
			self:check_global_expr(expr.right_expr, name)
		end
	elseif expr.fn_name then
		if self.local_fns[expr.fn_name] then
			error(
				self:new_error("The global variable '" .. name .. "' isn't allowed to call local functions", expr.span)
			)
		end
		for _, arg in ipairs(expr.arguments) do
			self:check_global_expr(arg, name)
		end
	elseif expr.expr then
		self:check_global_expr(expr.expr, name)
	end
end

function TypePropagator:fill_global_variables()
	self:add_global_variable("me", "ID", self.file_entity_type)

	for _, stmt in ipairs(self.ast) do
		if stmt.stmt_type == "VariableStatement" then
			self.current_global = stmt
			stmt.used_host_fns = {}

			self:check_global_expr(stmt.expr, stmt.name)
			self:fill_expr(stmt.expr)

			if stmt.expr.name == "me" and not stmt.expr.fn_name then
				error(self:new_error("Global variables can't be assigned 'me'", stmt.expr_span))
			end

			if are_incompatible_types(stmt.type, stmt.type_name, stmt.expr.result.type, stmt.expr.result.type_name) then
				error(
					self:new_error(
						"Can't assign "
							.. tostring(stmt.expr.result.type_name)
							.. " to '"
							.. stmt.name
							.. "', which has type "
							.. tostring(stmt.type_name),
						stmt.expr_span
					)
				)
			end

			if self.global_variables[stmt.name] then
				error(
					self:new_error(
						"The global variable '" .. stmt.name .. "' shadows an earlier global variable",
						stmt.decl_span
					)
				)
			end

			self:add_global_variable(stmt.name, stmt.type, stmt.type_name)
			self.current_global = nil
		end
	end
end

local function get_idx(parser_names, name)
	for i, v in ipairs(parser_names) do
		if v == name then
			return i
		end
	end
	return -1
end

function TypePropagator:fill_export_fns()
	local expected_map = {}
	for _, fn in ipairs(self.entity_export_functions) do
		expected_map[fn.name] = fn
	end

	for name in pairs(self.export_fns) do
		self.filled_fn_name = name
		if not expected_map[name] then
			error(
				self:new_error(
					"The function '"
						.. name
						.. "' was not declared by entity '"
						.. self.file_entity_type
						.. "' in mod_api.json",
					self.export_fns[name].span
				)
			)
		end
	end

	local parser_names = {}
	for _, s in ipairs(self.ast) do
		if s.stmt_type == "OnFn" then
			push(parser_names, s.fn_name)
		end
	end

	local last_idx = 0
	for _, expected_fn in ipairs(self.entity_export_functions) do
		local name = expected_fn.name
		if self.export_fns[name] then
			local curr_idx = get_idx(parser_names, name)
			if last_idx > curr_idx then
				self.filled_fn_name = name
				error(
					self:new_error(
						"The function '"
							.. name
							.. "' needs to be moved before or after a different export function, according to the entity '"
							.. self.file_entity_type
							.. "' in mod_api.json",
						self.export_fns[name].span
					)
				)
			end
			last_idx = curr_idx

			local fn = self.export_fns[name]
			self.fn_return_type, self.fn_return_type_name, self.filled_fn_name = nil, nil, name
			self.current_fn = fn
			fn.needs_clock = false
			fn.used_host_fns = {}
			local params = expected_fn.arguments or {}

			if #fn.arguments ~= #params then
				if #fn.arguments < #params then
					error(
						self:new_error(
							"Function '"
								.. name
								.. "' expected the parameter '"
								.. params[#fn.arguments + 1].name
								.. "' with type "
								.. params[#fn.arguments + 1].type,
							fn.span
						)
					)
				else
					error(
						self:new_error(
							"Function '"
								.. name
								.. "' got an unexpected extra parameter '"
								.. fn.arguments[#params + 1].name
								.. "' with type "
								.. fn.arguments[#params + 1].type_name,
							fn.arguments[#params + 1].span
						)
					)
				end
			end

			for i, arg in ipairs(fn.arguments) do
				local p = params[i]
				if arg.name ~= p.name then
					error(
						self:new_error(
							"Function '"
								.. name
								.. "' its '"
								.. arg.name
								.. "' parameter was supposed to be named '"
								.. p.name
								.. "'",
							arg.span
						)
					)
				end
				if arg.type_name ~= p.type then
					error(
						self:new_error(
							"Function '"
								.. name
								.. "' its '"
								.. p.name
								.. "' parameter was supposed to have the type "
								.. p.type
								.. ", but got "
								.. arg.type_name,
							arg.type_span
						)
					)
				end
			end

			self:add_argument_variables(fn.arguments)
			self:fill_statements(fn.body_statements)
			self.current_fn = nil
		end
	end
end

function TypePropagator:fill_local_fns()
	for name, fn in pairs(self.local_fns) do
		self.fn_return_type, self.fn_return_type_name, self.filled_fn_name = fn.return_type, fn.return_type_name, name
		self.current_fn = fn
		fn.needs_clock = false
		fn.used_host_fns = {}
		self:add_argument_variables(fn.arguments)
		self:fill_statements(fn.body_statements)

		if fn.return_type then
			local last = fn.body_statements[#fn.body_statements]
			if not last or last.stmt_type ~= "ReturnStatement" then
				error(
					self:new_error(
						"Function '"
							.. tostring(name)
							.. "' is supposed to return "
							.. tostring(fn.return_type_name)
							.. " as its last line",
						fn.span
					)
				)
			end
		end
		self.current_fn = nil
	end
end

function TypePropagator:fill()
	self:fill_global_variables()
	self:fill_export_fns()
	self:fill_local_fns()
end
