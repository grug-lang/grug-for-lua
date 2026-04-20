local function map_list(list, fn)
	local result = {}
	for _, v in ipairs(list or {}) do
		table.insert(result, fn(v))
	end
	return (#result > 0) and result or nil
end

-- ======================
-- Expression Serialization
-- ======================
local function serialize_expr(expr)
	local result = {}

	if expr.bool_val ~= nil then
		result.type = expr.bool_val and "TRUE_EXPR" or "FALSE_EXPR"
	elseif expr.value ~= nil then
		result.type = "NUMBER_EXPR"
		result.value = expr.string
	elseif expr.string ~= nil then
		local res_type = (type(expr.result) == "table") and expr.result.type_name or expr.result

		local type_map = {
			string = "STRING_EXPR",
			resource = "RESOURCE_EXPR",
			entity = "ENTITY_EXPR",
		}

		result.type = type_map[res_type] or "STRING_EXPR"
		result.str = expr.string
	elseif expr.name ~= nil and not expr.fn_name then
		result.type = "IDENTIFIER_EXPR"
		result.str = expr.name
	elseif expr.operator ~= nil then
		if expr.left_expr then
			result.type = (expr.operator == "AND_TOKEN" or expr.operator == "OR_TOKEN") and "LOGICAL_EXPR"
				or "BINARY_EXPR"

			result.left_expr = serialize_expr(expr.left_expr)
			result.operator = expr.operator
			result.right_expr = serialize_expr(expr.right_expr)
		else
			result.type = "UNARY_EXPR"
			result.operator = expr.operator
			result.expr = serialize_expr(expr.expr)
		end
	elseif expr.fn_name ~= nil then
		result.type = "CALL_EXPR"
		result.name = expr.fn_name
		result.arguments = map_list(expr.arguments, serialize_expr)
	elseif expr.expr ~= nil then
		result.type = "PARENTHESIZED_EXPR"
		result.expr = serialize_expr(expr.expr)
	end

	return result
end

-- ======================
-- Statement Serialization
-- ======================
local function serialize_statement(stmt)
	local result = {}
	local t = stmt.stmt_type

	if t == "VariableStatement" then
		result.type = "VARIABLE_STATEMENT"
		result.name = stmt.name
		if stmt.type then
			result.variable_type = stmt.type_name
		end
		result.assignment = serialize_expr(stmt.expr)
	elseif t == "CallStatement" then
		result.type = "CALL_STATEMENT"
		result.name = stmt.expr.fn_name
		result.arguments = map_list(stmt.expr.arguments, serialize_expr)
	elseif t == "IfStatement" then
		result.type = "IF_STATEMENT"
		result.condition = serialize_expr(stmt.condition)
		result.if_statements = map_list(stmt.if_body, serialize_statement)
		result.else_statements = map_list(stmt.else_body, serialize_statement)
	elseif t == "ReturnStatement" then
		result.type = "RETURN_STATEMENT"
		if stmt.value then
			result.expr = serialize_expr(stmt.value)
		end
	elseif t == "WhileStatement" then
		result.type = "WHILE_STATEMENT"
		result.condition = serialize_expr(stmt.condition)
		result.statements = map_list(stmt.body_statements, serialize_statement) or {}
	elseif t == "CommentStatement" then
		result.type = "COMMENT_STATEMENT"
		result.comment = stmt.string
	elseif t == "BreakStatement" then
		result.type = "BREAK_STATEMENT"
	elseif t == "ContinueStatement" then
		result.type = "CONTINUE_STATEMENT"
	elseif t == "EmptyLineStatement" then
		result.type = "EMPTY_LINE_STATEMENT"
	end

	return result
end

-- ======================
-- Global Serialization
-- ======================
local function serialize_arguments(arguments)
	return map_list(arguments, function(arg)
		return { name = arg.name, type = arg.type_name }
	end)
end

local function serialize_global_statement(stmt)
	local result = {}
	local t = stmt.stmt_type

	if t == "OnFn" or t == "HelperFn" then
		result.type = (t == "OnFn") and "GLOBAL_ON_FN" or "GLOBAL_HELPER_FN"
		result.name = stmt.fn_name
		result.arguments = serialize_arguments(stmt.arguments)

		if t == "HelperFn" and stmt.return_type then
			result.return_type = stmt.return_type_name
		end

		result.statements = map_list(stmt.body_statements, serialize_statement) or {}
	elseif t == "VariableStatement" then
		result.type = "GLOBAL_VARIABLE"
		result.name = stmt.name
		result.variable_type = stmt.type_name
		result.assignment = serialize_expr(stmt.expr)
	elseif t == "CommentStatement" then
		result.type = "GLOBAL_COMMENT"
		result.comment = stmt.string
	elseif t == "EmptyLineStatement" then
		result.type = "GLOBAL_EMPTY_LINE"
	end

	return result
end

-- ======================
-- JSON Conversion
-- ======================
local function ast_to_json_text(ast)
	return json.encode(map_list(ast, serialize_global_statement) or {})
end

-- ======================
-- GRUG Output
-- ======================
local function ast_to_grug(ast)
	local output, indentation = {}, 0

	local function write(text)
		table.insert(output, text)
	end

	local function indent()
		write(string.rep("    ", indentation))
	end

	-- ===== Expressions =====
	local function apply_expr(expr)
		local t = expr.type

		if t == "TRUE_EXPR" then
			write("true")
		elseif t == "FALSE_EXPR" then
			write("false")
		elseif t == "STRING_EXPR" then
			write('"' .. expr.str .. '"')
		elseif t == "ENTITY_EXPR" then
			write('e"' .. expr.str .. '"')
		elseif t == "RESOURCE_EXPR" then
			write('r"' .. expr.str .. '"')
		elseif t == "IDENTIFIER_EXPR" then
			write(expr.str)
		elseif t == "NUMBER_EXPR" then
			write(tostring(expr.value))
		elseif t == "UNARY_EXPR" then
			write(expr.operator == "MINUS_TOKEN" and "-" or "not ")
			apply_expr(expr.expr)
		elseif t == "BINARY_EXPR" then
			local op_map = {
				PLUS_TOKEN = "+",
				MINUS_TOKEN = "-",
				MULTIPLICATION_TOKEN = "*",
				DIVISION_TOKEN = "/",
				EQUALS_TOKEN = "==",
				NOT_EQUALS_TOKEN = "!=",
				GREATER_OR_EQUAL_TOKEN = ">=",
				GREATER_TOKEN = ">",
				LESS_OR_EQUAL_TOKEN = "<=",
				LESS_TOKEN = "<",
			}
			apply_expr(expr.left_expr)
			write(" " .. op_map[expr.operator] .. " ")
			apply_expr(expr.right_expr)
		elseif t == "LOGICAL_EXPR" then
			apply_expr(expr.left_expr)
			write(expr.operator == "AND_TOKEN" and " and " or " or ")
			apply_expr(expr.right_expr)
		elseif t == "CALL_EXPR" then
			write(expr.name .. "(")
			for i, arg in ipairs(expr.arguments or {}) do
				if i > 1 then
					write(", ")
				end
				apply_expr(arg)
			end
			write(")")
		elseif t == "PARENTHESIZED_EXPR" then
			write("(")
			apply_expr(expr.expr)
			write(")")
		end
	end

	-- ===== Statements =====
	local function apply_statements(statements)
		indentation = indentation + 1
		for _, s in ipairs(statements or {}) do
			if s.type == "EMPTY_LINE_STATEMENT" then
				write("\n")
			else
				indent()
				apply_statement(s)
			end
		end
		indentation = indentation - 1
	end

	local function apply_if(stmt)
		write("if ")
		apply_expr(stmt.condition)
		write(" {\n")

		apply_statements(stmt.if_statements)

		if stmt.else_statements and #stmt.else_statements > 0 then
			indent()
			write("} else ")

			local first = stmt.else_statements[1]
			if first and first.type == "IF_STATEMENT" then
				apply_if(first)
			else
				write("{\n")
				apply_statements(stmt.else_statements)
				indent()
				write("}\n")
			end
		else
			indent()
			write("}\n")
		end
	end

	function apply_statement(stmt)
		local t = stmt.type

		if t == "VARIABLE_STATEMENT" then
			write(stmt.name)
			if stmt.variable_type then
				write(": " .. stmt.variable_type)
			end
			write(" = ")
			apply_expr(stmt.assignment)
			write("\n")
		elseif t == "CALL_STATEMENT" then
			write(stmt.name .. "(")
			for i, arg in ipairs(stmt.arguments or {}) do
				if i > 1 then
					write(", ")
				end
				apply_expr(arg)
			end
			write(")\n")
		elseif t == "IF_STATEMENT" then
			apply_if(stmt)
		elseif t == "RETURN_STATEMENT" then
			write("return")
			if stmt.expr then
				write(" ")
				apply_expr(stmt.expr)
			end
			write("\n")
		elseif t == "WHILE_STATEMENT" then
			write("while ")
			apply_expr(stmt.condition)
			write(" {\n")
			apply_statements(stmt.statements)
			indent()
			write("}\n")
		elseif t == "BREAK_STATEMENT" then
			write("break\n")
		elseif t == "CONTINUE_STATEMENT" then
			write("continue\n")
		elseif t == "COMMENT_STATEMENT" then
			write("# " .. stmt.comment .. "\n")
		end
	end

	-- ===== Globals =====
	local function apply_args(args)
		for i, a in ipairs(args or {}) do
			if i > 1 then
				write(", ")
			end
			write(a.name .. ": " .. a.type)
		end
	end

	for _, stmt in ipairs(ast) do
		local t = stmt.type

		if t == "GLOBAL_VARIABLE" then
			write(stmt.name .. ": " .. stmt.variable_type .. " = ")
			apply_expr(stmt.assignment)
			write("\n")
		elseif t == "GLOBAL_ON_FN" or t == "GLOBAL_HELPER_FN" then
			write(stmt.name .. "(")
			apply_args(stmt.arguments)
			write(")")

			if t == "GLOBAL_HELPER_FN" and stmt.return_type then
				write(" " .. stmt.return_type)
			end

			write(" {\n")
			apply_statements(stmt.statements)
			write("}\n")
		elseif t == "GLOBAL_EMPTY_LINE" then
			write("\n")
		elseif t == "GLOBAL_COMMENT" then
			write("# " .. stmt.comment .. "\n")
		end
	end

	return table.concat(output)
end
