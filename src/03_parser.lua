local MAX_PARSING_DEPTH = 100
local MIN_F64 = 2.2250738585072014e-308
local MAX_F64 = 1.7976931348623157e308

-- AST Node Factories
local Nodes = {
	True = function()
		return { bool_val = true, result = "bool" }
	end,
	False = function()
		return { bool_val = false, result = "bool" }
	end,
	String = function(s, token)
		return { string = s, result = "string", span = { line = token.line, pos = token.pos } }
	end,
	Resource = function(s, token)
		return { string = s, result = "resource", span = { line = token.line, pos = token.pos } }
	end,
	Entity = function(s, token)
		return { string = s, result = "entity", span = { line = token.line, pos = token.pos } }
	end,
	Identifier = function(name, token)
		return { name = name, span = token and { line = token.line, pos = token.pos } }
	end,
	Number = function(v, s)
		return { value = v, string = s, result = "number" }
	end,
	Unary = function(op, expr)
		return { operator = op, expr = expr }
	end,
	Binary = function(l, op, r)
		return { left_expr = l, operator = op, right_expr = r }
	end,
	Logical = function(l, op, r)
		return { left_expr = l, operator = op, right_expr = r }
	end,
	Call = function(name, span)
		return { fn_name = name, arguments = {}, span = span }
	end,
	Parenthesized = function(expr)
		return { expr = expr }
	end,
	Variable = function(name, t, tname, expr, expr_span, decl_span)
		return {
			stmt_type = "VariableStatement",
			name = name,
			type = t,
			type_name = tname,
			expr = expr,
			expr_span = expr_span,
			decl_span = decl_span,
		}
	end,
	CallStmt = function(expr)
		return { stmt_type = "CallStatement", expr = expr }
	end,
	If = function(cond, ifb, elseb)
		return { stmt_type = "IfStatement", condition = cond, if_body = ifb, else_body = elseb }
	end,
	Return = function(val)
		return { stmt_type = "ReturnStatement", value = val }
	end,
	While = function(cond, body)
		return { stmt_type = "WhileStatement", condition = cond, body_statements = body }
	end,
	Break = function()
		return { stmt_type = "BreakStatement" }
	end,
	Continue = function()
		return { stmt_type = "ContinueStatement" }
	end,
	EmptyLine = function()
		return { stmt_type = "EmptyLineStatement" }
	end,
	Comment = function(s)
		return { stmt_type = "CommentStatement", string = s }
	end,
	Argument = function(name, t, tname, name_span, type_span)
		return { name = name, type = t, type_name = tname, span = name_span, type_span = type_span }
	end,
	OnFn = function(name, token)
		token = token or { line = 0, pos = 0 }
		return {
			stmt_type = "OnFn",
			fn_name = name,
			arguments = {},
			body_statements = {},
			span = { line = token.line, pos = token.pos },
		}
	end,
	HelperFn = function(name, token)
		return {
			stmt_type = "HelperFn",
			fn_name = name,
			arguments = {},
			body_statements = {},
			span = { line = token.line, pos = token.pos },
		}
	end,
}

local TYPE_MAP = {
	bool = "BOOL",
	number = "NUMBER",
	string = "STRING",
	resource = "RESOURCE",
	entity = "ENTITY",
}

local Parser = {}
Parser.__index = Parser

function Parser.new(tokens, src, file_path)
	return setmetatable({
		tokens = tokens,
		src = src,
		file_path = file_path,
		current_function = nil,
		idx = 1,
		ast = {},
		local_fns = {},
		export_fns = {},
		parsing_depth = 0,
		loop_depth = 0,
		indentation = 0,
		called_local_fn_names = {},
	}, Parser)
end

--- Utility Methods ---

function Parser:get_token_line_number(idx)
	local line = 1
	for i = 1, idx - 1 do
		if self.tokens[i] and self.tokens[i].type == "NEWLINE_TOKEN" then
			line = line + 1
		end
	end
	return line
end

-- Builds an error message pointing at `token` (defaults to the current token).
function Parser:new_error(msg, token)
	token = token or self:peek()

	local line = token.line or self:get_token_line_number(self.idx)
	local column = token.pos and get_column(self.src, token.pos)
	local source_line = token.pos and get_source_line(self.src, token.pos)

	local current_function = self.current_function or "member scope"

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

function Parser:peek(offset)
	local i = self.idx + (offset or 0)
	if i > #self.tokens then
		local last_token = (#self.tokens > 0) and self.tokens[#self.tokens] or { line = 1, pos = 1 }
		return { type = "EOF_TOKEN", line = last_token.line, pos = last_token.pos }
	end
	return self.tokens[i]
end

function Parser:consume()
	local t = self:peek()
	self.idx = self.idx + 1
	return t
end

function Parser:assert_type(expected)
	local t = self:peek()
	if t.type == "EOF_TOKEN" then
		error(self:new_error("Expected " .. token_type_str(expected) .. " but got end of file", t))
	end
	if t.type ~= expected then
		error(self:new_error("Expected " .. token_type_str(expected) .. " but got " .. token_type_str(t.type), t))
	end
end

function Parser:consume_type(expected)
	self:assert_type(expected)
	return self:consume()
end

function Parser:consume_space()
	local tok = self:peek()
	if tok.type ~= "SPACE_TOKEN" then
		error(
			self:new_error("Expected " .. token_type_str("SPACE_TOKEN") .. " but got " .. token_type_str(tok.type), tok)
		)
	end
	self.idx = self.idx + 1
end

function Parser:consume_indentation()
	self:assert_type("INDENTATION_TOKEN")
	local spaces = #self:peek().value
	local expected = self.indentation * SPACES_PER_INDENT
	if spaces ~= expected then
		error(self:new_error("Expected " .. expected .. " spaces, but got " .. spaces .. " spaces", self:peek()))
	end
	self.idx = self.idx + 1
end

function Parser:is_end_of_block()
	local tok = self:peek()
	if tok.type == "CLOSE_BRACE_TOKEN" then
		return true
	end
	if tok.type == "NEWLINE_TOKEN" then
		return false
	end
	if tok.type == "INDENTATION_TOKEN" then
		return #tok.value == (self.indentation - 1) * SPACES_PER_INDENT
	end
	error(self:new_error("Expected indentation, line break, or '}' but got '" .. tostring(tok.value) .. "'", tok))
end

function Parser:enter_scope(token)
	self.parsing_depth = self.parsing_depth + 1
	if self.parsing_depth >= MAX_PARSING_DEPTH then
		error(
			self:new_error(
				"There is a function that contains more than " .. MAX_PARSING_DEPTH .. " levels of nested expressions",
				token or self:peek()
			)
		)
	end
end

function Parser:exit_scope()
	self.parsing_depth = self.parsing_depth - 1
end

local function get_type(type_str)
	return TYPE_MAP[type_str] or "ID"
end

local function validate_fn_body(parser, fn, name_token)
	local is_empty = true
	for _, s in ipairs(fn.body_statements) do
		if s.stmt_type ~= "EmptyLineStatement" and s.stmt_type ~= "CommentStatement" then
			is_empty = false
			break
		end
	end
	if is_empty then
		error(parser:new_error(fn.fn_name .. "() can't be empty", name_token))
	end
end

--- Parsing Methods ---

function Parser:parse()
	local seen_export_fn, newline_allowed, newline_required = false, false, false

	while self.idx <= #self.tokens do
		local token = self:peek()

		if token.type == "WORD_TOKEN" then
			if seen_export_fn then
				error(self:new_error("Cannot declare member variables after on_ functions", token))
			end

			push(self.ast, self:parse_global_variable())
			self:consume_type("NEWLINE_TOKEN")
			newline_allowed, newline_required = true, true
		elseif token.type == "EXPORT_TOKEN" then
			self:consume_type("EXPORT_TOKEN")
			self:consume_space()

			local name_token = self:peek()
			if next(self.local_fns) then
				self.current_function = name_token.value
				error(self:new_error(name_token.value .. "() must be defined before all local functions", name_token))
			end
			if newline_required then
				error(self:new_error("Expected an empty line", name_token))
			end
			self.current_function = name_token.value

			local fn = self:parse_export_fn()
			if self.export_fns[fn.fn_name] then
				self.current_function = fn.fn_name
				error(
					self:new_error(
						"The function '" .. fn.fn_name .. "' was defined several times in the same file",
						name_token
					)
				)
			end
			self.export_fns[fn.fn_name] = fn
			self:consume_type("NEWLINE_TOKEN")
			seen_export_fn, newline_allowed, newline_required = true, true, true
		elseif token.type == "LOCAL_TOKEN" then
			self:consume_type("LOCAL_TOKEN")
			self:consume_space()

			local name_token = self:peek()
			if newline_required then
				error(self:new_error("Expected an empty line", name_token))
			end

			local fn = self:parse_local_fn()
			if self.local_fns[fn.fn_name] then
				error(
					self:new_error(
						"The function '" .. fn.fn_name .. "' was defined several times in the same file",
						name_token
					)
				)
			end
			self.local_fns[fn.fn_name] = fn
			self:consume_type("NEWLINE_TOKEN")
			newline_allowed, newline_required = true, true
		elseif token.type == "NEWLINE_TOKEN" then
			if not newline_allowed then
				error(self:new_error("Unexpected empty line", token))
			end
			push(self.ast, Nodes.EmptyLine())
			self.idx = self.idx + 1
			newline_allowed, newline_required = false, false
		elseif token.type == "COMMENT_TOKEN" then
			push(self.ast, Nodes.Comment(token.value))
			self.idx = self.idx + 1
			self:consume_type("NEWLINE_TOKEN")
			newline_allowed = true
		else
			error(
				self:new_error(
					"Unexpected token '"
						.. tostring(token.value)
						.. "' on line "
						.. self:get_token_line_number(self.idx),
					token
				)
			)
		end
	end

	if not newline_allowed and self:get_token_line_number(self.idx - 1) > 1 then
		-- Verify if last token was newline to trigger the specific trailing empty line error
		if self.tokens[#self.tokens].type == "NEWLINE_TOKEN" then
			error(self:new_error("Unexpected empty line", self.tokens[#self.tokens]))
		end
	end

	return self.ast
end

function Parser:parse_arguments()
	local args = {}
	repeat
		local name_token = self:consume()
		local name = name_token.value
		if self:peek().type ~= "COLON_TOKEN" then
			error(self:new_error("Unexpected token '" .. name .. "' on line " .. name_token.line, name_token))
		end
		self:consume()
		self:consume_space()
		self:assert_type("WORD_TOKEN")
		local t_token = self:consume()
		local type_name = t_token.value
		local arg_type = get_type(type_name)

		if arg_type == "RESOURCE" or arg_type == "ENTITY" then
			error(self:new_error("The argument '" .. name .. "' can't have '" .. type_name .. "' as its type", t_token))
		end
		push(
			args,
			Nodes.Argument(
				name,
				arg_type,
				type_name,
				{ line = name_token.line, pos = name_token.pos },
				{ line = t_token.line, pos = t_token.pos }
			)
		)

		if self.idx <= #self.tokens and self:peek().type == "COMMA_TOKEN" then
			self.idx = self.idx + 1
			self:consume_space()
			self:assert_type("WORD_TOKEN")
		else
			break
		end
	until false
	return args
end

function Parser:parse_local_fn()
	local name_token = self:consume()
	local name = name_token.value
	self.current_function = name

	if string.sub(name, 1, 1) ~= "_" then
		error(self:new_error("Local function name must begin with '_'", name_token))
	end

	if not self.called_local_fn_names[name] then
		error(self:new_error(name .. "() is defined before the first time it gets called", name_token))
	end

	local fn = Nodes.HelperFn(name, name_token)
	self:consume_type("OPEN_PARENTHESIS_TOKEN")
	if self:peek().type == "WORD_TOKEN" then
		fn.arguments = self:parse_arguments()
	end
	self:consume_type("CLOSE_PARENTHESIS_TOKEN")

	if self:peek().type == "SPACE_TOKEN" then
		local next_t = self:peek(1)
		if next_t.type == "WORD_TOKEN" then
			self.idx = self.idx + 2
			fn.return_type = get_type(next_t.value)
			fn.return_type_name = next_t.value
			if fn.return_type == "RESOURCE" or fn.return_type == "ENTITY" then
				error(
					self:new_error(
						"The function '" .. name .. "' can't have '" .. fn.return_type_name .. "' as its return type",
						next_t
					)
				)
			end
		end
	end

	self.indentation = 0
	fn.body_statements = self:parse_statements()
	validate_fn_body(self, fn, name_token)
	push(self.ast, fn)
	return fn
end

function Parser:parse_export_fn()
	local name_token = self:consume()
	local name = name_token.value
	self.current_function = name

	local fn = Nodes.OnFn(name, name_token)
	self:consume_type("OPEN_PARENTHESIS_TOKEN")
	if self:peek().type == "WORD_TOKEN" then
		fn.arguments = self:parse_arguments()
	end
	self:consume_type("CLOSE_PARENTHESIS_TOKEN")
	fn.body_statements = self:parse_statements()
	validate_fn_body(self, fn, name_token)
	push(self.ast, fn)
	self.current_function = nil
	return fn
end

function Parser:parse_statements()
	self:enter_scope()

	local stmts = {}
	self:consume_space()
	self:consume_type("OPEN_BRACE_TOKEN")
	self:consume_type("NEWLINE_TOKEN")
	self.indentation = self.indentation + 1

	local newline_allowed = false
	while not self:is_end_of_block() do
		local tok = self:peek()
		if tok.type == "NEWLINE_TOKEN" then
			if not newline_allowed then
				error(self:new_error("Unexpected empty line", tok))
			end
			self.idx = self.idx + 1
			newline_allowed = false
			push(stmts, Nodes.EmptyLine())
		else
			newline_allowed = true
			self:consume_indentation()
			if self:peek().type == "NEWLINE_TOKEN" then
				error(self:new_error("Empty line cannot have indentation", tok))
			end
			push(stmts, self:parse_statement())
			self:consume_type("NEWLINE_TOKEN")
		end
	end

	if not newline_allowed and #stmts > 0 and stmts[#stmts].stmt_type == "EmptyLineStatement" then
		error(self:new_error("Unexpected empty line", self:peek(-1)))
	end

	self.indentation = self.indentation - 1
	if self.indentation > 0 then
		self:consume_indentation()
	end
	self:consume_type("CLOSE_BRACE_TOKEN")

	self:exit_scope()
	return stmts
end

function Parser:parse_statement()
	self:enter_scope()

	local res
	local tok = self:peek()
	if tok.type == "WORD_TOKEN" then
		local next_t = self:peek(1)
		if next_t.type == "OPEN_PARENTHESIS_TOKEN" then
			res = Nodes.CallStmt(self:parse_call())
		elseif next_t.type == "COLON_TOKEN" or next_t.type == "SPACE_TOKEN" then
			res = self:parse_local_variable()
		else
			error(
				self:new_error(
					"Expected '(', or ':', or ' =' after the word '"
						.. tok.value
						.. "' on line "
						.. self:get_token_line_number(self.idx),
					next_t
				)
			)
		end
	elseif tok.type == "IF_TOKEN" then
		self.idx = self.idx + 1
		res = self:parse_if_statement()
	elseif tok.type == "RETURN_TOKEN" then
		self.idx = self.idx + 1
		if self:peek().type == "NEWLINE_TOKEN" then
			res = Nodes.Return()
		else
			self:consume_space()
			res = Nodes.Return(self:parse_expression())
		end
		res.span = { line = tok.line, pos = tok.pos }
	elseif tok.type == "WHILE_TOKEN" then
		self.idx = self.idx + 1
		res = self:parse_while_statement()
	elseif tok.type == "BREAK_TOKEN" or tok.type == "CONTINUE_TOKEN" then
		if self.loop_depth == 0 then
			local word = tok.type == "BREAK_TOKEN" and "break" or "continue"
			error(self:new_error("There is a " .. word .. " statement that isn't inside of a while loop", tok))
		end
		self.idx = self.idx + 1
		res = tok.type == "BREAK_TOKEN" and Nodes.Break() or Nodes.Continue()
	elseif tok.type == "NEWLINE_TOKEN" then
		self.idx = self.idx + 1
		res = Nodes.EmptyLine()
	elseif tok.type == "COMMENT_TOKEN" then
		self.idx = self.idx + 1
		res = Nodes.Comment(tok.value)
	else
		error(
			self:new_error(
				"Expected a statement token, but got "
					.. token_type_str(tok.type)
					.. " on line "
					.. self:get_token_line_number(self.idx),
				tok
			)
		)
	end

	self:exit_scope()
	return res
end

function Parser:parse_local_variable()
	local name_token = self:consume()
	local name = name_token.value
	local v_type, v_tname

	if self:peek().type == "COLON_TOKEN" then
		self.idx = self.idx + 1

		if name == "me" then
			error(self:new_error("variable cannot be named 'me'", name_token))
		end

		self:consume_space()
		self:assert_type("WORD_TOKEN")
		v_tname = self:consume().value
		v_type = get_type(v_tname)

		if v_type == "RESOURCE" or v_type == "ENTITY" then
			error(
				self:new_error(
					"The variable '" .. name .. "' can't have '" .. v_tname .. "' as its type",
					self:peek(-1)
				)
			)
		end
	end

	if self:peek().type ~= "SPACE_TOKEN" then
		error(self:new_error("Variable '" .. name .. "' was not assigned a value", self:peek()))
	end

	self:consume_space()
	self:consume_type("ASSIGNMENT_TOKEN")

	if name == "me" then
		error(self:new_error("Assigning a new value to the entity's 'me' variable is not allowed", name_token))
	end

	self:consume_space()

	local expr_token = self:peek()

	return Nodes.Variable(
		name,
		v_type,
		v_tname,
		self:parse_expression(),
		{ line = expr_token.line, pos = expr_token.pos },
		{ line = name_token.line, pos = name_token.pos }
	)
end

function Parser:parse_global_variable()
	local name_token = self:consume()
	local name = name_token.value

	if name == "me" then
		error(self:new_error("variable cannot be named 'me'", name_token))
	end

	if self:peek().type ~= "COLON_TOKEN" then
		error(self:new_error("Unexpected token '" .. name .. "' on line " .. name_token.line, name_token))
	end
	self:consume()
	self:consume_space()
	self:assert_type("WORD_TOKEN")

	local t_token = self:consume()
	local t_name = t_token.value
	local g_type = get_type(t_name)

	if g_type == "RESOURCE" or g_type == "ENTITY" then
		error(self:new_error("The global variable '" .. name .. "' can't have '" .. t_name .. "' as its type", t_token))
	end

	if self:peek().type ~= "SPACE_TOKEN" then
		error(self:new_error("The global variable '" .. name .. "' was not assigned a value", self:peek()))
	end

	self:consume_space()
	self:consume_type("ASSIGNMENT_TOKEN")
	self:consume_space()

	local expr_token = self:peek()

	return Nodes.Variable(
		name,
		g_type,
		t_name,
		self:parse_expression(),
		{ line = expr_token.line, pos = expr_token.pos },
		{ line = name_token.line, pos = name_token.pos }
	)
end

function Parser:parse_if_statement()
	self:enter_scope()

	self:consume_space()
	local cond = self:parse_expression()
	local if_body = self:parse_statements()
	local else_body = {}

	local tok = self.idx <= #self.tokens and self:peek()
	if tok and tok.type == "SPACE_TOKEN" then
		self.idx = self.idx + 1
		self:consume_type("ELSE_TOKEN")
		if self:peek().type == "SPACE_TOKEN" and self:peek(1).type == "IF_TOKEN" then
			self.idx = self.idx + 2
			else_body = { self:parse_if_statement() }
		else
			else_body = self:parse_statements()
		end
	end

	local res = Nodes.If(cond, if_body, else_body)
	self:exit_scope()
	return res
end

function Parser:parse_while_statement()
	self:enter_scope()

	self:consume_space()
	local cond = self:parse_expression()
	self.loop_depth = self.loop_depth + 1
	local body = self:parse_statements()
	self.loop_depth = self.loop_depth - 1

	local res = Nodes.While(cond, body)
	self:exit_scope()
	return res
end

local function str_to_number(s, parser, token)
	local f = tonumber(s)
	if not f or f ~= f or math.abs(f) > MAX_F64 then
		error(parser:new_error("The number " .. s .. " is too big", token))
	end
	if f ~= 0 and math.abs(f) < MIN_F64 then
		error(parser:new_error("The number " .. s .. " is too close to zero", token))
	end
	if f == 0 and s:find("[123456789]") then
		error(parser:new_error("The number " .. s .. " is too close to zero", token))
	end
	return f
end

function Parser:parse_primary()
	local t = self:peek()
	self:enter_scope(t)

	local res
	self:consume()
	if t.type == "OPEN_PARENTHESIS_TOKEN" then
		local expr = Nodes.Parenthesized(self:parse_expression())
		self:consume_type("CLOSE_PARENTHESIS_TOKEN")
		res = expr
	elseif t.type == "TRUE_TOKEN" then
		res = Nodes.True()
		res.span = { line = t.line, pos = t.pos }
	elseif t.type == "FALSE_TOKEN" then
		res = Nodes.False()
		res.span = { line = t.line, pos = t.pos }
	elseif t.type == "STRING_TOKEN" then
		res = Nodes.String(t.value, t)
	elseif t.type == "ENTITY_TOKEN" then
		res = Nodes.Entity(t.value, t)
	elseif t.type == "RESOURCE_TOKEN" then
		res = Nodes.Resource(t.value, t)
	elseif t.type == "WORD_TOKEN" then
		res = Nodes.Identifier(t.value, t)
	elseif t.type == "NUMBER_TOKEN" then
		res = Nodes.Number(str_to_number(t.value, self, t), t.value)
		res.span = { line = t.line, pos = t.pos }
	else
		error(self:new_error("Expected a primary expression token but got " .. token_type_str(t.type), t))
	end

	self:exit_scope()
	return res
end

function Parser:parse_call()
	self:enter_scope()

	local res
	local expr = self:parse_primary()
	if self:peek().type ~= "OPEN_PARENTHESIS_TOKEN" then
		res = expr
	elseif expr.name == nil then
		error(self:new_error("Expected ')' but got '('", self:peek()))
	else
		local fn_name = expr.name
		if fn_name:sub(1, 1) == "_" then
			self.called_local_fn_names[fn_name] = true
		end

		local call = Nodes.Call(fn_name, expr.span)
		self.idx = self.idx + 1
		if self:peek().type == "CLOSE_PARENTHESIS_TOKEN" then
			self.idx = self.idx + 1
			res = call
		else
			repeat
				push(call.arguments, self:parse_expression())
				if self:peek().type == "COMMA_TOKEN" then
					self.idx = self.idx + 1
					self:consume_space()
				else
					self:consume_type("CLOSE_PARENTHESIS_TOKEN")
					break
				end
			until false
			res = call
		end
	end

	self:exit_scope()
	return res
end

function Parser:parse_unary()
	self:enter_scope()

	local res
	local t = self:peek()
	if t.type == "MINUS_TOKEN" or t.type == "NOT_TOKEN" then
		self.idx = self.idx + 1
		if t.type == "NOT_TOKEN" then
			self:consume_space()
		end
		res = Nodes.Unary(t.type, self:parse_unary())
		res.op_span = {
			line = t.line,
			pos = t.pos,
		}
	else
		res = self:parse_call()
	end

	self:exit_scope()
	return res
end

local function binary_op(next_fn, ops, ctor)
	return function(self)
		local expr = next_fn(self)
		while self.idx <= #self.tokens do
			local t = self:peek()
			if t.type == "SPACE_TOKEN" then
				local op_t = self:peek(1)
				if ops[op_t.type] then
					self.idx = self.idx + 1

					local consumed = self:consume()
					local op = consumed.type

					self:consume_space()

					expr = ctor(expr, op, next_fn(self))
					expr.op_span = {
						line = consumed.line,
						pos = consumed.pos,
					}
				else
					break
				end
			else
				break
			end
		end
		return expr
	end
end

Parser.parse_factor =
	binary_op(Parser.parse_unary, { MULTIPLICATION_TOKEN = true, DIVISION_TOKEN = true }, Nodes.Binary)
Parser.parse_term = binary_op(Parser.parse_factor, { PLUS_TOKEN = true, MINUS_TOKEN = true }, Nodes.Binary)
Parser.parse_comparison = binary_op(
	Parser.parse_term,
	{ GREATER_TOKEN = true, GREATER_OR_EQUAL_TOKEN = true, LESS_TOKEN = true, LESS_OR_EQUAL_TOKEN = true },
	Nodes.Binary
)
Parser.parse_equality =
	binary_op(Parser.parse_comparison, { EQUALS_TOKEN = true, NOT_EQUALS_TOKEN = true }, Nodes.Binary)
Parser.parse_and = binary_op(Parser.parse_equality, { AND_TOKEN = true }, Nodes.Logical)
Parser.parse_or = binary_op(Parser.parse_and, { OR_TOKEN = true }, Nodes.Logical)

function Parser:parse_expression()
	self:enter_scope()
	local res = self:parse_or()
	self:exit_scope()
	return res
end
