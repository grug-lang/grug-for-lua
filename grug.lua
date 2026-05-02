-- BEGIN 01_json.lua
--
-- json.lua
--
-- Copyright (c) 2020 rxi
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy of
-- this software and associated documentation files (the "Software"), to deal in
-- the Software without restriction, including without limitation the rights to
-- use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
-- of the Software, and to permit persons to whom the Software is furnished to do
-- so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.
--

local json = { _version = "0.1.2" }

-------------------------------------------------------------------------------
-- Encode
-------------------------------------------------------------------------------

local encode

local escape_char_map = {
	["\\"] = "\\",
	['"'] = '"',
	["\b"] = "b",
	["\f"] = "f",
	["\n"] = "n",
	["\r"] = "r",
	["\t"] = "t",
}

local escape_char_map_inv = { ["/"] = "/" }
for k, v in pairs(escape_char_map) do
	escape_char_map_inv[v] = k
end

local function escape_char(c)
	return "\\" .. (escape_char_map[c] or string.format("u%04x", c:byte()))
end

local function encode_nil(val) -- luacheck: ignore
	return "null"
end

local function encode_table(val, stack)
	local res = {}
	stack = stack or {}

	-- Circular reference?
	if stack[val] then
		error("circular reference")
	end

	stack[val] = true

	if rawget(val, 1) ~= nil or next(val) == nil then
		-- Treat as array -- check keys are valid and it is not sparse
		local n = 0
		for k in pairs(val) do
			if type(k) ~= "number" then
				error("invalid table: mixed or invalid key types")
			end
			n = n + 1
		end
		if n ~= #val then
			error("invalid table: sparse array")
		end
		-- Encode
		for _, v in ipairs(val) do
			table.insert(res, encode(v, stack))
		end
		stack[val] = nil
		return "[" .. table.concat(res, ",") .. "]"
	else
		-- Treat as an object
		for k, v in pairs(val) do
			if type(k) ~= "string" then
				error("invalid table: mixed or invalid key types")
			end
			table.insert(res, encode(k, stack) .. ":" .. encode(v, stack))
		end
		stack[val] = nil
		return "{" .. table.concat(res, ",") .. "}"
	end
end

local function encode_string(val)
	return '"' .. val:gsub('[%z\1-\31\\"]', escape_char) .. '"'
end

local function encode_number(val)
	-- Check for NaN, -inf and inf
	if val ~= val or val <= -math.huge or val >= math.huge then
		error("unexpected number value '" .. tostring(val) .. "'")
	end
	return string.format("%.14g", val)
end

local type_func_map = {
	["nil"] = encode_nil,
	["table"] = encode_table,
	["string"] = encode_string,
	["number"] = encode_number,
	["boolean"] = tostring,
}

encode = function(val, stack)
	local t = type(val)
	local f = type_func_map[t]
	if f then
		return f(val, stack)
	end
	error("unexpected type '" .. t .. "'")
end

function json.encode(val)
	return (encode(val))
end

-------------------------------------------------------------------------------
-- Decode
-------------------------------------------------------------------------------

local parse

local function create_set(...)
	local res = {}
	for i = 1, select("#", ...) do
		res[select(i, ...)] = true
	end
	return res
end

local space_chars = create_set(" ", "\t", "\r", "\n")
local delim_chars = create_set(" ", "\t", "\r", "\n", "]", "}", ",")
local escape_chars = create_set("\\", "/", '"', "b", "f", "n", "r", "t", "u")
local literals = create_set("true", "false", "null")

local literal_map = {
	["true"] = true,
	["false"] = false,
	["null"] = nil,
}

local function next_char(str, idx, set, negate)
	for i = idx, #str do
		if set[str:sub(i, i)] ~= negate then
			return i
		end
	end
	return #str + 1
end

local function decode_error(str, idx, msg)
	local line_count = 1
	local col_count = 1
	for i = 1, idx - 1 do
		col_count = col_count + 1
		if str:sub(i, i) == "\n" then
			line_count = line_count + 1
			col_count = 1
		end
	end
	error(string.format("%s at line %d col %d", msg, line_count, col_count))
end

local function codepoint_to_utf8(n)
	-- http://scripts.sil.org/cms/scripts/page.php?site_id=nrsi&id=iws-appendixa
	local f = math.floor
	if n <= 0x7f then
		return string.char(n)
	elseif n <= 0x7ff then
		return string.char(f(n / 64) + 192, n % 64 + 128)
	elseif n <= 0xffff then
		return string.char(f(n / 4096) + 224, f(n % 4096 / 64) + 128, n % 64 + 128)
	elseif n <= 0x10ffff then
		return string.char(f(n / 262144) + 240, f(n % 262144 / 4096) + 128, f(n % 4096 / 64) + 128, n % 64 + 128)
	end
	error(string.format("invalid unicode codepoint '%x'", n))
end

local function parse_unicode_escape(s)
	local n1 = tonumber(s:sub(1, 4), 16)
	local n2 = tonumber(s:sub(7, 10), 16)
	-- Surrogate pair?
	if n2 then
		return codepoint_to_utf8((n1 - 0xd800) * 0x400 + (n2 - 0xdc00) + 0x10000)
	else
		return codepoint_to_utf8(n1)
	end
end

local function parse_string(str, i)
	local res = ""
	local j = i + 1
	local k = j

	while j <= #str do
		local x = str:byte(j)

		if x < 32 then
			decode_error(str, j, "control character in string")
		elseif x == 92 then -- `\`: Escape
			res = res .. str:sub(k, j - 1)
			j = j + 1
			local c = str:sub(j, j)
			if c == "u" then
				local hex = str:match("^[dD][89aAbB]%x%x\\u%x%x%x%x", j + 1)
					or str:match("^%x%x%x%x", j + 1)
					or decode_error(str, j - 1, "invalid unicode escape in string")
				res = res .. parse_unicode_escape(hex)
				j = j + #hex
			else
				if not escape_chars[c] then
					decode_error(str, j - 1, "invalid escape char '" .. c .. "' in string")
				end
				res = res .. escape_char_map_inv[c]
			end
			k = j + 1
		elseif x == 34 then -- `"`: End of string
			res = res .. str:sub(k, j - 1)
			return res, j + 1
		end

		j = j + 1
	end

	decode_error(str, i, "expected closing quote for string")
end

local function parse_number(str, i)
	local x = next_char(str, i, delim_chars)
	local s = str:sub(i, x - 1)
	local n = tonumber(s)
	if not n then
		decode_error(str, i, "invalid number '" .. s .. "'")
	end
	return n, x
end

local function parse_literal(str, i)
	local x = next_char(str, i, delim_chars)
	local word = str:sub(i, x - 1)
	if not literals[word] then
		decode_error(str, i, "invalid literal '" .. word .. "'")
	end
	return literal_map[word], x
end

local function parse_array(str, i)
	local res = {}
	local n = 1
	i = i + 1
	while 1 do
		local x
		i = next_char(str, i, space_chars, true)
		-- Empty / end of array?
		if str:sub(i, i) == "]" then
			i = i + 1
			break
		end
		-- Read token
		x, i = parse(str, i)
		res[n] = x
		n = n + 1
		-- Next token
		i = next_char(str, i, space_chars, true)
		local chr = str:sub(i, i)
		i = i + 1
		if chr == "]" then
			break
		end
		if chr ~= "," then
			decode_error(str, i, "expected ']' or ','")
		end
	end
	return res, i
end

local function parse_object(str, i)
	local res = {}
	i = i + 1
	while 1 do
		local key, val
		i = next_char(str, i, space_chars, true)
		-- Empty / end of object?
		if str:sub(i, i) == "}" then
			i = i + 1
			break
		end
		-- Read key
		if str:sub(i, i) ~= '"' then
			decode_error(str, i, "expected string for key")
		end
		key, i = parse(str, i)
		-- Read ':' delimiter
		i = next_char(str, i, space_chars, true)
		if str:sub(i, i) ~= ":" then
			decode_error(str, i, "expected ':' after key")
		end
		i = next_char(str, i + 1, space_chars, true)
		-- Read value
		val, i = parse(str, i)
		-- Set
		res[key] = val
		-- Next token
		i = next_char(str, i, space_chars, true)
		local chr = str:sub(i, i)
		i = i + 1
		if chr == "}" then
			break
		end
		if chr ~= "," then
			decode_error(str, i, "expected '}' or ','")
		end
	end
	return res, i
end

local char_func_map = {
	['"'] = parse_string,
	["0"] = parse_number,
	["1"] = parse_number,
	["2"] = parse_number,
	["3"] = parse_number,
	["4"] = parse_number,
	["5"] = parse_number,
	["6"] = parse_number,
	["7"] = parse_number,
	["8"] = parse_number,
	["9"] = parse_number,
	["-"] = parse_number,
	["t"] = parse_literal,
	["f"] = parse_literal,
	["n"] = parse_literal,
	["["] = parse_array,
	["{"] = parse_object,
}

parse = function(str, idx)
	local chr = str:sub(idx, idx)
	local f = char_func_map[chr]
	if f then
		return f(str, idx)
	end
	decode_error(str, idx, "unexpected character '" .. chr .. "'")
end

function json.decode(str)
	if type(str) ~= "string" then
		error("expected argument of type string, got " .. type(str))
	end
	local res, idx = parse(str, next_char(str, 1, space_chars, true))
	idx = next_char(str, idx, space_chars, true)
	if idx <= #str then
		decode_error(str, idx, "trailing garbage")
	end
	return res
end

-- BEGIN 02_tokenizer.lua
local SPACES_PER_INDENT = 4

local KEYWORDS = {
	["and"] = "AND_TOKEN",
	["or"] = "OR_TOKEN",
	["not"] = "NOT_TOKEN",
	["true"] = "TRUE_TOKEN",
	["false"] = "FALSE_TOKEN",
	["if"] = "IF_TOKEN",
	["else"] = "ELSE_TOKEN",
	["while"] = "WHILE_TOKEN",
	["break"] = "BREAK_TOKEN",
	["return"] = "RETURN_TOKEN",
	["continue"] = "CONTINUE_TOKEN",
}

local SYMBOLS = {
	["("] = "OPEN_PARENTHESIS_TOKEN",
	[")"] = "CLOSE_PARENTHESIS_TOKEN",
	["{"] = "OPEN_BRACE_TOKEN",
	["}"] = "CLOSE_BRACE_TOKEN",
	["+"] = "PLUS_TOKEN",
	["-"] = "MINUS_TOKEN",
	["*"] = "MULTIPLICATION_TOKEN",
	["/"] = "DIVISION_TOKEN",
	[","] = "COMMA_TOKEN",
	[":"] = "COLON_TOKEN",
	["\n"] = "NEWLINE_TOKEN",
	["="] = "ASSIGNMENT_TOKEN",
	[">"] = "GREATER_TOKEN",
	["<"] = "LESS_TOKEN",
}

local DOUBLE_SYMBOLS = {
	["=="] = "EQUALS_TOKEN",
	["!="] = "NOT_EQUALS_TOKEN",
	[">="] = "GREATER_OR_EQUAL_TOKEN",
	["<="] = "LESS_OR_EQUAL_TOKEN",
}

local function tokenize(src)
	local tokens = {}
	local i = 1
	local line_number = 1

	local function error_at(msg, override_line)
		error(msg .. " on line " .. (override_line or line_number))
	end

	local function tokenize_string(start_idx)
		local open_quote_line = line_number
		local idx = start_idx + 1
		local start_content = idx

		while idx <= #src do
			local c = src:sub(idx, idx)
			if c == '"' then
				break
			elseif c == "\0" then
				error_at("Unexpected null byte", line_number)
			elseif c == "\\" and src:sub(idx + 1, idx + 1) == "\n" then
				error_at("Unexpected line break in string", line_number)
			elseif c == "\n" then
				line_number = line_number + 1
			end
			idx = idx + 1
		end

		if idx > #src then
			error_at('Unclosed "', open_quote_line)
		end

		return src:sub(start_content, idx - 1), idx
	end

	while i <= #src do
		local c = src:sub(i, i)
		local double_c = src:sub(i, i + 1)

		-- 1. Double-character symbols (==, !=, >=, <=)
		if DOUBLE_SYMBOLS[double_c] then
			table.insert(tokens, { type = DOUBLE_SYMBOLS[double_c], value = double_c })
			i = i + 2

		-- 2. Single-character symbols (+, -, (, ), etc.)
		elseif SYMBOLS[c] then
			table.insert(tokens, { type = SYMBOLS[c], value = c })
			if c == "\n" then
				line_number = line_number + 1
			end
			i = i + 1

		-- 3. Spaces and Indentation
		elseif c == " " then
			local next_c = src:sub(i + 1, i + 1)

			-- Single space
			if next_c ~= " " then
				table.insert(tokens, { type = "SPACE_TOKEN", value = " " })
				i = i + 1

			-- Indentation block
			else
				local old_i = i
				while i <= #src and src:sub(i, i) == " " do
					i = i + 1
				end

				local spaces = i - old_i
				if spaces % SPACES_PER_INDENT ~= 0 then
					error_at(
						string.format(
							"Encountered %d spaces, while indentation expects multiples of %d spaces,",
							spaces,
							SPACES_PER_INDENT
						)
					)
				end

				table.insert(tokens, {
					type = "INDENTATION_TOKEN",
					value = string.rep(" ", spaces),
				})
			end

		-- 4. Standard Strings
		elseif c == '"' then
			local str_val, new_i = tokenize_string(i)
			table.insert(tokens, { type = "STRING_TOKEN", value = str_val })
			i = new_i + 1

		-- 5. Entity Strings (e"...")
		elseif c == "e" and src:sub(i + 1, i + 1) == '"' then
			local str_val, new_i = tokenize_string(i + 1)
			table.insert(tokens, { type = "ENTITY_TOKEN", value = str_val })
			i = new_i + 1

		-- 6. Resource Strings (r"...")
		elseif c == "r" and src:sub(i + 1, i + 1) == '"' then
			local str_val, new_i = tokenize_string(i + 1)
			table.insert(tokens, { type = "RESOURCE_TOKEN", value = str_val })
			i = new_i + 1

		-- 7. Words (Identifiers and Keywords)
		elseif c:match("[%a_]") then
			local start = i
			while i <= #src and src:sub(i, i):match("[%w_]") do
				i = i + 1
			end

			local word = src:sub(start, i - 1)
			if KEYWORDS[word] then
				table.insert(tokens, { type = KEYWORDS[word], value = word })
			else
				table.insert(tokens, { type = "WORD_TOKEN", value = word })
			end

		-- 8. Numbers (Integers and Floats)
		elseif c:match("%d") then
			local start = i
			local seen_period = false
			i = i + 1

			while i <= #src do
				local nc = src:sub(i, i)
				if nc:match("%d") then
					i = i + 1
				elseif nc == "." then
					if seen_period then
						error_at("Encountered two '.' periods in a number")
					end
					seen_period = true
					i = i + 1
				else
					break
				end
			end

			local num_str = src:sub(start, i - 1)
			if src:sub(i - 1, i - 1) == "." then
				error("Missing digit after decimal point in '" .. num_str .. "'")
			end

			table.insert(tokens, { type = "NUMBER_TOKEN", value = num_str })

		-- 9. Comments (# ...)
		elseif c == "#" then
			i = i + 1
			if i > #src or src:sub(i, i) ~= " " then
				error_at("Expected a single space after the '#'")
			end

			i = i + 1
			local start = i

			while i <= #src and src:sub(i, i) ~= "\n" do
				if src:sub(i, i) == "\0" then
					error_at("Unexpected null byte")
				end
				i = i + 1
			end

			local comment_len = i - start
			if comment_len == 0 then
				error_at("Expected the comment to contain some text")
			end

			if src:sub(i - 1, i - 1):match("%s") then
				error_at("A comment has trailing whitespace")
			end

			table.insert(tokens, { type = "COMMENT_TOKEN", value = src:sub(start, i - 1) })

		-- 10. Fallback Error
		else
			error_at("Unrecognized character '" .. c .. "'")
		end
	end

	return tokens
end

-- BEGIN 03_parser.lua
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
	String = function(s)
		return { string = s, result = "string" }
	end,
	Resource = function(s)
		return { string = s, result = "resource" }
	end,
	Entity = function(s)
		return { string = s, result = "entity" }
	end,
	Identifier = function(name)
		return { name = name }
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
	Call = function(name)
		return { fn_name = name, arguments = {} }
	end,
	Parenthesized = function(expr)
		return { expr = expr }
	end,
	Variable = function(name, t, tname, expr)
		return { stmt_type = "VariableStatement", name = name, type = t, type_name = tname, expr = expr }
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
	Argument = function(name, t, tname)
		return { name = name, type = t, type_name = tname }
	end,
	OnFn = function(name)
		return { stmt_type = "OnFn", fn_name = name, arguments = {}, body_statements = {} }
	end,
	HelperFn = function(name)
		return { stmt_type = "HelperFn", fn_name = name, arguments = {}, body_statements = {} }
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

function Parser.new(tokens)
	return setmetatable({
		tokens = tokens,
		idx = 1,
		ast = {},
		helper_fns = {},
		on_fns = {},
		parsing_depth = 0,
		loop_depth = 0,
		indentation = 0,
		called_helper_fn_names = {},
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

function Parser:peek(offset)
	local i = self.idx + (offset or 0)
	if i > #self.tokens then
		error("token_index " .. (i - 1) .. " was out of bounds in peek_token()")
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
	if t.type ~= expected then
		error(
			"Expected token type "
				.. expected
				.. ", but got "
				.. t.type
				.. " on line "
				.. self:get_token_line_number(self.idx)
		)
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
			"Expected token type SPACE_TOKEN, but got "
				.. tok.type
				.. " on line "
				.. self:get_token_line_number(self.idx)
		)
	end
	self.idx = self.idx + 1
end

function Parser:consume_indentation()
	self:assert_type("INDENTATION_TOKEN")
	local spaces = #self:peek().value
	local expected = self.indentation * SPACES_PER_INDENT
	if spaces ~= expected then
		error(
			"Expected "
				.. expected
				.. " spaces, but got "
				.. spaces
				.. " spaces on line "
				.. self:get_token_line_number(self.idx)
		)
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
	error(
		"Expected indentation, newline, or '}', but got '"
			.. tostring(tok.value)
			.. "' on line "
			.. self:get_token_line_number(self.idx)
	)
end

function Parser:enter_scope()
	self.parsing_depth = self.parsing_depth + 1
	if self.parsing_depth >= MAX_PARSING_DEPTH then
		error("There is a function that contains more than " .. MAX_PARSING_DEPTH .. " levels of nested expressions")
	end
end

function Parser:exit_scope()
	self.parsing_depth = self.parsing_depth - 1
end

local function get_type(type_str)
	return TYPE_MAP[type_str] or "ID"
end

local function validate_fn_body(fn)
	local is_empty = true
	for _, s in ipairs(fn.body_statements) do
		if s.stmt_type ~= "EmptyLineStatement" and s.stmt_type ~= "CommentStatement" then
			is_empty = false
			break
		end
	end
	if is_empty then
		error(fn.fn_name .. "() can't be empty")
	end
end

--- Parsing Methods ---

function Parser:parse()
	local seen_on_fn, newline_allowed, newline_required = false, false, false

	while self.idx <= #self.tokens do
		local token = self:peek()
		local next_token = self.idx < #self.tokens and self:peek(1) or nil

		if token.type == "WORD_TOKEN" and next_token and next_token.type == "COLON_TOKEN" then
			if seen_on_fn then
				error("Move the global variable '" .. token.value .. "' so it is above the on_ functions")
			end
			table.insert(self.ast, self:parse_global_variable())
			self:consume_type("NEWLINE_TOKEN")
			newline_allowed, newline_required = true, true
		elseif
			token.type == "WORD_TOKEN"
			and token.value:sub(1, 3) == "on_"
			and next_token
			and next_token.type == "OPEN_PARENTHESIS_TOKEN"
		then
			if next(self.helper_fns) then
				error(token.value .. "() must be defined before all helper_ functions")
			end
			if newline_required then
				error("Expected an empty line, on line " .. self:get_token_line_number(self.idx))
			end

			local fn = self:parse_on_fn()
			if self.on_fns[fn.fn_name] then
				error("The function '" .. fn.fn_name .. "' was defined several times in the same file")
			end
			self.on_fns[fn.fn_name] = fn
			self:consume_type("NEWLINE_TOKEN")
			seen_on_fn, newline_allowed, newline_required = true, true, true
		elseif
			token.type == "WORD_TOKEN"
			and token.value:sub(1, 7) == "helper_"
			and next_token
			and next_token.type == "OPEN_PARENTHESIS_TOKEN"
		then
			if newline_required then
				error("Expected an empty line, on line " .. self:get_token_line_number(self.idx))
			end

			local fn = self:parse_helper_fn()
			if self.helper_fns[fn.fn_name] then
				error("The function '" .. fn.fn_name .. "' was defined several times in the same file")
			end
			self.helper_fns[fn.fn_name] = fn
			self:consume_type("NEWLINE_TOKEN")
			newline_allowed, newline_required = true, true
		elseif token.type == "NEWLINE_TOKEN" then
			if not newline_allowed then
				error("Unexpected empty line, on line " .. self:get_token_line_number(self.idx))
			end
			table.insert(self.ast, Nodes.EmptyLine())
			self.idx = self.idx + 1
			newline_allowed, newline_required = false, false
		elseif token.type == "COMMENT_TOKEN" then
			table.insert(self.ast, Nodes.Comment(token.value))
			self.idx = self.idx + 1
			self:consume_type("NEWLINE_TOKEN")
			newline_allowed = true
		else
			error("Unexpected token '" .. tostring(token.value) .. "' on line " .. self:get_token_line_number(self.idx))
		end
	end

	if not newline_allowed and self:get_token_line_number(self.idx - 1) > 1 then
		-- Verify if last token was newline to trigger the specific trailing empty line error
		if self.tokens[#self.tokens].type == "NEWLINE_TOKEN" then
			error("Unexpected empty line, on line " .. self:get_token_line_number(#self.tokens))
		end
	end

	return self.ast
end

function Parser:parse_arguments()
	local args = {}
	repeat
		local name = self:consume().value
		self:consume_type("COLON_TOKEN")
		self:consume_space()
		self:assert_type("WORD_TOKEN")
		local t_token = self:consume()
		local type_name = t_token.value
		local arg_type = get_type(type_name)

		if arg_type == "RESOURCE" or arg_type == "ENTITY" then
			error("The argument '" .. name .. "' can't have '" .. type_name .. "' as its type")
		end
		table.insert(args, Nodes.Argument(name, arg_type, type_name))

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

function Parser:parse_helper_fn()
	local name = self:consume().value
	if not self.called_helper_fn_names[name] then
		error(name .. "() is defined before the first time it gets called")
	end

	local fn = Nodes.HelperFn(name)
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
				error("The function '" .. name .. "' can't have '" .. fn.return_type_name .. "' as its return type")
			end
		end
	end

	self.indentation = 0
	fn.body_statements = self:parse_statements()
	validate_fn_body(fn)
	table.insert(self.ast, fn)
	return fn
end

function Parser:parse_on_fn()
	local name = self:consume().value
	local fn = Nodes.OnFn(name)
	self:consume_type("OPEN_PARENTHESIS_TOKEN")
	if self:peek().type == "WORD_TOKEN" then
		fn.arguments = self:parse_arguments()
	end
	self:consume_type("CLOSE_PARENTHESIS_TOKEN")
	fn.body_statements = self:parse_statements()
	validate_fn_body(fn)
	table.insert(self.ast, fn)
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
				error("Unexpected empty line, on line " .. self:get_token_line_number(self.idx))
			end
			self.idx = self.idx + 1
			newline_allowed = false
			table.insert(stmts, Nodes.EmptyLine())
		else
			newline_allowed = true
			self:consume_indentation()
			table.insert(stmts, self:parse_statement())
			self:consume_type("NEWLINE_TOKEN")
		end
	end

	if not newline_allowed and #stmts > 0 and stmts[#stmts].stmt_type == "EmptyLineStatement" then
		error("Unexpected empty line, on line " .. self:get_token_line_number(self.idx - 1))
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
				"Expected '(', or ':', or ' =' after the word '"
					.. tok.value
					.. "' on line "
					.. self:get_token_line_number(self.idx)
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
	elseif tok.type == "WHILE_TOKEN" then
		self.idx = self.idx + 1
		res = self:parse_while_statement()
	elseif tok.type == "BREAK_TOKEN" or tok.type == "CONTINUE_TOKEN" then
		if self.loop_depth == 0 then
			local word = tok.type == "BREAK_TOKEN" and "break" or "continue"
			error("There is a " .. word .. " statement that isn't inside of a while loop")
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
			"Expected a statement token, but got token type "
				.. tok.type
				.. " on line "
				.. self:get_token_line_number(self.idx)
		)
	end

	self:exit_scope()
	return res
end

function Parser:parse_local_variable()
	local start_idx = self.idx
	local name = self:consume().value
	local v_type, v_tname

	if self:peek().type == "COLON_TOKEN" then
		self.idx = self.idx + 1
		if name == "me" then
			error(
				"The local variable 'me' has to have its name changed to something else, since grug already declares that variable"
			)
		end
		self:consume_space()
		self:assert_type("WORD_TOKEN")
		v_tname = self:consume().value
		v_type = get_type(v_tname)
		if v_type == "RESOURCE" or v_type == "ENTITY" then
			error("The variable '" .. name .. "' can't have '" .. v_tname .. "' as its type")
		end
	end

	if self:peek().type ~= "SPACE_TOKEN" then
		error(
			"The variable '" .. name .. "' was not assigned a value on line " .. self:get_token_line_number(start_idx)
		)
	end
	self:consume_space()
	self:consume_type("ASSIGNMENT_TOKEN")
	if name == "me" then
		error("Assigning a new value to the entity's 'me' variable is not allowed")
	end
	self:consume_space()
	return Nodes.Variable(name, v_type, v_tname, self:parse_expression())
end

function Parser:parse_global_variable()
	local start_idx = self.idx
	local name = self:consume().value
	if name == "me" then
		error(
			"The global variable 'me' has to have its name changed to something else, since grug already declares that variable"
		)
	end

	self:consume_type("COLON_TOKEN")
	self:consume_space()
	self:assert_type("WORD_TOKEN")
	local t_token = self:consume()
	local t_name = t_token.value
	local g_type = get_type(t_name)

	if g_type == "RESOURCE" or g_type == "ENTITY" then
		error("The global variable '" .. name .. "' can't have '" .. t_name .. "' as its type")
	end
	if self:peek().type ~= "SPACE_TOKEN" then
		error(
			"The global variable '"
				.. name
				.. "' was not assigned a value on line "
				.. self:get_token_line_number(start_idx)
		)
	end

	self:consume_space()
	self:consume_type("ASSIGNMENT_TOKEN")
	self:consume_space()
	return Nodes.Variable(name, g_type, t_name, self:parse_expression())
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

local function str_to_number(s)
	local f = tonumber(s)
	if not f or f ~= f or math.abs(f) > MAX_F64 then
		error("The number " .. s .. " is too big")
	end
	if f ~= 0 and math.abs(f) < MIN_F64 then
		error("The number " .. s .. " is too close to zero")
	end
	if f == 0 and s:find("[123456789]") then
		error("The number " .. s .. " is too close to zero")
	end
	return f
end

function Parser:parse_primary()
	self:enter_scope()

	local res
	local t = self:consume()
	if t.type == "OPEN_PARENTHESIS_TOKEN" then
		local expr = Nodes.Parenthesized(self:parse_expression())
		self:consume_type("CLOSE_PARENTHESIS_TOKEN")
		res = expr
	elseif t.type == "TRUE_TOKEN" then
		res = Nodes.True()
	elseif t.type == "FALSE_TOKEN" then
		res = Nodes.False()
	elseif t.type == "STRING_TOKEN" then
		res = Nodes.String(t.value)
	elseif t.type == "ENTITY_TOKEN" then
		res = Nodes.Entity(t.value)
	elseif t.type == "RESOURCE_TOKEN" then
		res = Nodes.Resource(t.value)
	elseif t.type == "WORD_TOKEN" then
		res = Nodes.Identifier(t.value)
	elseif t.type == "NUMBER_TOKEN" then
		res = Nodes.Number(str_to_number(t.value), t.value)
	else
		error(
			"Expected a primary expression token, but got token type "
				.. t.type
				.. " on line "
				.. self:get_token_line_number(self.idx - 1)
		)
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
		error("Unexpected '(' after non-identifier at line " .. self:get_token_line_number(self.idx))
	else
		local fn_name = expr.name
		if fn_name:sub(1, 7) == "helper_" then
			self.called_helper_fn_names[fn_name] = true
		end

		local call = Nodes.Call(fn_name)
		self.idx = self.idx + 1
		if self:peek().type == "CLOSE_PARENTHESIS_TOKEN" then
			self.idx = self.idx + 1
			res = call
		else
			repeat
				table.insert(call.arguments, self:parse_expression())
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
					local op = self:consume().type
					self:consume_space()
					expr = ctor(expr, op, next_fn(self))
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

-- BEGIN 04_type_propagator.lua
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
		table.insert(args, Argument(obj.name, get_type(obj.type), obj.type, obj.resource_extension, obj.entity_type))
	end
	return args
end

local function parse_game_fn(fn_name, fn)
	return GameFn(fn_name, parse_args(fn.arguments), fn.return_type and get_type(fn.return_type) or nil, fn.return_type)
end

-- --------------------------------------------------------------------------
-- TypePropagator Class
-- --------------------------------------------------------------------------

local TypePropagator = {}
TypePropagator.__index = TypePropagator

function TypePropagator.new(ast, mod, entity_type, mod_api)
	local self = setmetatable({
		ast = ast,
		mod = mod,
		file_entity_type = entity_type,
		mod_api = mod_api,
		on_fns = {},
		helper_fns = {},
		fn_return_type = nil,
		fn_return_type_name = nil,
		filled_fn_name = nil,
		local_variables = {},
		global_variables = {},
		game_functions = {},
		entity_on_functions = {},
	}, TypePropagator)

	for _, s in ipairs(ast) do
		if s.stmt_type == "OnFn" then
			self.on_fns[s.fn_name] = s
		elseif s.stmt_type == "HelperFn" then
			self.helper_fns[s.fn_name] = s
		end
	end

	if mod_api.game_functions then
		for fn_name, fn in pairs(mod_api.game_functions) do
			self.game_functions[fn_name] = parse_game_fn(fn_name, fn)
		end
	end

	local entity_cfg = mod_api.entities and mod_api.entities[entity_type]
	if entity_cfg and entity_cfg.on_functions then
		self.entity_on_functions = entity_cfg.on_functions
	end

	return self
end

-- --------------------------------------------------------------------------
-- Variable Management
-- --------------------------------------------------------------------------

function TypePropagator:get_variable(name)
	return self.local_variables[name] or self.global_variables[name]
end

function TypePropagator:add_global_variable(name, var_type, type_name)
	if self.global_variables[name] then
		error("The global variable '" .. name .. "' shadows an earlier global variable")
	end
	self.global_variables[name] = Variable(name, var_type, type_name)
end

function TypePropagator:add_local_variable(name, var_type, type_name)
	if self.local_variables[name] then
		error("The local variable '" .. name .. "' shadows an earlier local variable")
	end
	if self.global_variables[name] then
		error("The local variable '" .. name .. "' shadows an earlier global variable")
	end
	self.local_variables[name] = Variable(name, var_type, type_name)
end

function TypePropagator:add_argument_variables(arguments)
	self.local_variables = {}
	for _, arg in ipairs(arguments) do
		self:add_local_variable(arg.name, arg.type, arg.type_name)
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

function TypePropagator:validate_entity_string(str)
	if not str or str == "" then
		error("Entities can't be empty strings")
	end

	local mod, entity_name = self.mod, str
	local colon_pos = string.find(str, ":")

	if colon_pos then
		if colon_pos == 1 then
			error("Entity '" .. str .. "' is missing a mod name")
		end

		mod = string.sub(str, 1, colon_pos - 1)
		entity_name = string.sub(str, colon_pos + 1)

		if entity_name == "" then
			error(
				"Entity '"
					.. str
					.. "' specifies the mod name '"
					.. mod
					.. "', but it is missing an entity name after the ':'"
			)
		end
		if mod == self.mod then
			error(
				"Entity '"
					.. str
					.. "' its mod name '"
					.. mod
					.. "' is invalid, since the file it is in refers to its own mod; just change it to '"
					.. entity_name
					.. "'"
			)
		end
	end

	local function check_chars(s, label)
		for i = 1, #s do
			local c = string.sub(s, i, i)
			if not (string.match(c, "%l") or string.match(c, "%d") or c == "_" or c == "-") then
				error("Entity '" .. str .. "' its " .. label .. " name contains the invalid character '" .. c .. "'")
			end
		end
	end

	check_chars(mod, "mod")
	check_chars(entity_name, "entity")
end

local function validate_resource_string(str, resource_extension)
	if not str or str == "" then
		error("Resources can't be empty strings")
	end
	if string.sub(str, 1, 1) == "/" then
		error('Remove the leading slash from the resource "' .. str .. '"')
	end
	if string.sub(str, -1) == "/" then
		error('Remove the trailing slash from the resource "' .. str .. '"')
	end
	if string.find(str, "\\", 1, true) then
		error("Replace the '\\' with '/' in the resource \"" .. str .. '"')
	end
	if string.find(str, "//", 1, true) then
		error("Replace the '//' with '/' in the resource \"" .. str .. '"')
	end

	-- Check for single '.'
	local dot_index = string.find(str, "%.")
	if dot_index then
		if dot_index == 1 then
			if #str == 1 or string.sub(str, 2, 2) == "/" then
				error("Remove the '.' from the resource \"" .. str .. '"')
			end
		elseif string.sub(str, dot_index - 1, dot_index - 1) == "/" then
			if dot_index + 1 > #str or string.sub(str, dot_index + 1, dot_index + 1) == "/" then
				error("Remove the '.' from the resource \"" .. str .. '"')
			end
		end
	end

	-- Check for double '..'
	local dotdot_index = string.find(str, "%.%.")
	if dotdot_index then
		if dotdot_index == 1 then
			if #str == 2 or string.sub(str, 3, 3) == "/" then
				error("Remove the '..' from the resource \"" .. str .. '"')
			end
		elseif string.sub(str, dotdot_index - 1, dotdot_index - 1) == "/" then
			if dotdot_index + 2 > #str or string.sub(str, dotdot_index + 2, dotdot_index + 2) == "/" then
				error("Remove the '..' from the resource \"" .. str .. '"')
			end
		end
	end

	if string.sub(str, -1) == "." then
		error('resource name "' .. str .. '" cannot end with .')
	end

	if resource_extension and resource_extension ~= "" then
		if string.sub(str, -#resource_extension) ~= resource_extension then
			error("The resource '" .. str .. "' was supposed to have the extension '" .. resource_extension .. "'")
		end
	end
end

-- --------------------------------------------------------------------------
-- Expression & Statement Filling
-- --------------------------------------------------------------------------

function TypePropagator:check_arguments(params, call_expr)
	local fn_name, args = call_expr.fn_name, call_expr.arguments

	if #args < #params then
		error(
			"Function call '"
				.. fn_name
				.. "' expected the argument '"
				.. params[#args + 1].name
				.. "' with type "
				.. params[#args + 1].type_name
		)
	end
	if #args > #params then
		error(
			"Function call '"
				.. fn_name
				.. "' got an unexpected extra argument with type "
				.. tostring(args[#params + 1].result.type_name)
		)
	end

	for i, arg in ipairs(args) do
		local param = params[i]
		local is_string = arg.string ~= nil and arg.result.type == "STRING"

		if is_string then
			if param.type == "ENTITY" then
				error(
					"The host function '"
						.. fn_name
						.. "' expects an entity string, so put an 'e' in front of string \""
						.. arg.string
						.. '"'
				)
			elseif param.type == "RESOURCE" then
				error(
					"The host function '"
						.. fn_name
						.. "' expects a resource string, so put an 'r' in front of string \""
						.. arg.string
						.. '"'
				)
			end
		end

		if arg.string ~= nil then
			if arg.result.type == "ENTITY" then
				self:validate_entity_string(arg.string)
			elseif arg.result.type == "RESOURCE" then
				validate_resource_string(arg.string, param.resource_extension)
			end
		end

		if not arg.result or not arg.result.type then
			error(
				"Function call '"
					.. fn_name
					.. "' expected the type "
					.. param.type_name
					.. " for argument '"
					.. param.name
					.. "', but got a function call that doesn't return anything"
			)
		end

		if are_incompatible_types(param.type, param.type_name, arg.result.type, arg.result.type_name) then
			error(
				"Function call '"
					.. fn_name
					.. "' expected the type "
					.. param.type_name
					.. " for argument '"
					.. param.name
					.. "', but got "
					.. arg.result.type_name
			)
		end
	end
end

function TypePropagator:fill_call_expr(expr)
	for _, arg in ipairs(expr.arguments) do
		self:fill_expr(arg)
	end

	local fn_name = expr.fn_name
	local target_fn = self.helper_fns[fn_name] or self.game_functions[fn_name]

	if target_fn then
		expr.result = { type = target_fn.return_type, type_name = target_fn.return_type_name }
		self:check_arguments(target_fn.arguments, expr)
		return
	end

	if string.sub(fn_name, 1, 3) == "on_" then
		error("Mods aren't allowed to call their own on_ functions, but '" .. fn_name .. "' was called")
	elseif string.sub(fn_name, 1, 7) == "helper_" then
		error("The helper function '" .. fn_name .. "' was not defined by this grug file")
	end

	error("The game function '" .. fn_name .. "' was not declared by mod_api.json")
end

function TypePropagator:fill_binary_expr(expr)
	local left, right, op = expr.left_expr, expr.right_expr, expr.operator
	self:fill_expr(left)
	self:fill_expr(right)

	if left.result.type == "STRING" and op ~= "EQUALS_TOKEN" and op ~= "NOT_EQUALS_TOKEN" then
		error("You can't use the " .. op .. " operator on a string")
	end

	local is_id = (left.result.type_name == "id" or right.result.type_name == "id")
	if not is_id and left.result.type_name ~= right.result.type_name then
		error(
			"The left and right operand of a binary expression ('"
				.. op
				.. "') must have the same type, but got "
				.. tostring(left.result.type_name)
				.. " and "
				.. tostring(right.result.type_name)
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
			error("'" .. op .. "' operator expects number")
		end
		expr.result.type, expr.result.type_name = "BOOL", "bool"
	elseif op == "AND_TOKEN" or op == "OR_TOKEN" then
		if left.result.type ~= "BOOL" then
			error("'" .. op .. "' operator expects bool")
		end
		expr.result.type, expr.result.type_name = "BOOL", "bool"
	else
		if left.result.type ~= "NUMBER" then
			error("'" .. op .. "' operator expects number")
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
			error("The variable '" .. expr.name .. "' does not exist")
		end
		expr.result.type, expr.result.type_name = var.type, var.type_name
	elseif expr.operator and not expr.left_expr then
		local op, inner = expr.operator, expr.expr
		if inner.operator == op and not inner.left_expr then
			error(
				"Found '"
					.. op
					.. "' directly next to another '"
					.. op
					.. "', which can be simplified by just removing both of them"
			)
		end
		self:fill_expr(inner)
		expr.result.type, expr.result.type_name = inner.result.type, inner.result.type_name
		if op == "NOT_TOKEN" then
			if expr.result.type ~= "BOOL" then
				error(
					"Found 'not' before " .. tostring(expr.result.type_name) .. ", but it can only be put before a bool"
				)
			end
		elseif expr.result.type ~= "NUMBER" then
			error("Found '-' before " .. tostring(expr.result.type_name) .. ", but it can only be put before a number")
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
						"Can't assign "
							.. tostring(stmt.expr.result.type_name)
							.. " to '"
							.. stmt.name
							.. "', which has type "
							.. tostring(stmt.type_name)
					)
				end
				self:add_local_variable(stmt.name, stmt.type, stmt.type_name)
			else
				if not var then
					error("Can't assign to the variable '" .. stmt.name .. "', since it does not exist")
				end
				if self.global_variables[stmt.name] and var.type == "ID" then
					error("Global id variables can't be reassigned")
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
						"Can't assign "
							.. tostring(stmt.expr.result.type_name)
							.. " to '"
							.. var.name
							.. "', which has type "
							.. tostring(var.type_name)
					)
				end
			end
		elseif stype == "CallStatement" then
			self:fill_call_expr(stmt.expr)
		elseif stype == "IfStatement" then
			self:fill_expr(stmt.condition)
			self:fill_statements(stmt.if_body)
			if stmt.else_body and #stmt.else_body > 0 then
				self:fill_statements(stmt.else_body)
			end
		elseif stype == "WhileStatement" then
			self:fill_expr(stmt.condition)
			self:fill_statements(stmt.body_statements)
		elseif stype == "ReturnStatement" then
			if stmt.value then
				self:fill_expr(stmt.value)
				if not self.fn_return_type then
					error("Function '" .. tostring(self.filled_fn_name) .. "' wasn't supposed to return any value")
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
						"Function '"
							.. tostring(self.filled_fn_name)
							.. "' is supposed to return "
							.. tostring(self.fn_return_type_name)
							.. ", not "
							.. tostring(stmt.value.result.type_name)
					)
				end
			elseif self.fn_return_type then
				error(
					"Function '"
						.. tostring(self.filled_fn_name)
						.. "' is supposed to return a value of type "
						.. tostring(self.fn_return_type_name)
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
		if string.sub(expr.fn_name, 1, 7) == "helper_" then
			error("The global variable '" .. name .. "' isn't allowed to call helper functions")
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
			self:check_global_expr(stmt.expr, stmt.name)
			self:fill_expr(stmt.expr)
			if stmt.expr.name == "me" and not stmt.expr.fn_name then
				error("Global variables can't be assigned 'me'")
			end
			if are_incompatible_types(stmt.type, stmt.type_name, stmt.expr.result.type, stmt.expr.result.type_name) then
				error(
					"Can't assign "
						.. tostring(stmt.expr.result.type_name)
						.. " to '"
						.. stmt.name
						.. "', which has type "
						.. tostring(stmt.type_name)
				)
			end
			self:add_global_variable(stmt.name, stmt.type, stmt.type_name)
		end
	end
end

function TypePropagator:fill_on_fns()
	local expected_map = {}
	for _, fn in ipairs(self.entity_on_functions) do
		expected_map[fn.name] = fn
	end

	for name in pairs(self.on_fns) do
		if not expected_map[name] then
			error(
				"The function '"
					.. name
					.. "' was not declared by entity '"
					.. self.file_entity_type
					.. "' in mod_api.json"
			)
		end
	end

	local parser_names = {}
	for _, s in ipairs(self.ast) do
		if s.stmt_type == "OnFn" then
			table.insert(parser_names, s.fn_name)
		end
	end

	local function get_idx(name)
		for i, v in ipairs(parser_names) do
			if v == name then
				return i
			end
		end
		return -1
	end

	local last_idx = 0
	for _, expected_fn in ipairs(self.entity_on_functions) do
		local name = expected_fn.name
		if self.on_fns[name] then
			local curr_idx = get_idx(name)
			if last_idx > curr_idx then
				error(
					"The function '"
						.. name
						.. "' needs to be moved before/after a different on_ function, according to the entity '"
						.. self.file_entity_type
						.. "' in mod_api.json"
				)
			end
			last_idx = curr_idx

			local fn = self.on_fns[name]
			self.fn_return_type, self.fn_return_type_name, self.filled_fn_name = nil, nil, name
			local params = expected_fn.arguments or {}

			if #fn.arguments ~= #params then
				if #fn.arguments < #params then
					error(
						"Function '"
							.. name
							.. "' expected the parameter '"
							.. params[#fn.arguments + 1].name
							.. "' with type "
							.. params[#fn.arguments + 1].type
					)
				else
					error(
						"Function '"
							.. name
							.. "' got an unexpected extra parameter '"
							.. fn.arguments[#params + 1].name
							.. "' with type "
							.. fn.arguments[#params + 1].type_name
					)
				end
			end

			for i, arg in ipairs(fn.arguments) do
				local p = params[i]
				if arg.name ~= p.name then
					error(
						"Function '"
							.. name
							.. "' its '"
							.. arg.name
							.. "' parameter was supposed to be named '"
							.. p.name
							.. "'"
					)
				end
				if arg.type_name ~= p.type then
					error(
						"Function '"
							.. name
							.. "' its '"
							.. p.name
							.. "' parameter was supposed to have the type "
							.. p.type
							.. ", but got "
							.. arg.type_name
					)
				end
			end

			self:add_argument_variables(fn.arguments)
			self:fill_statements(fn.body_statements)
		end
	end
end

function TypePropagator:fill_helper_fns()
	for name, fn in pairs(self.helper_fns) do
		self.fn_return_type, self.fn_return_type_name, self.filled_fn_name = fn.return_type, fn.return_type_name, name
		self:add_argument_variables(fn.arguments)
		self:fill_statements(fn.body_statements)

		if fn.return_type then
			local last = fn.body_statements[#fn.body_statements]
			if not last or last.stmt_type ~= "ReturnStatement" then
				error(
					"Function '"
						.. tostring(name)
						.. "' is supposed to return "
						.. tostring(fn.return_type_name)
						.. " as its last line"
				)
			end
		end
	end
end

function TypePropagator:fill()
	self:fill_global_variables()
	self:fill_on_fns()
	self:fill_helper_fns()
end

-- BEGIN 05_serializer.lua
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

		local string_type_map = {
			string = "STRING_EXPR",
			resource = "RESOURCE_EXPR",
			entity = "ENTITY_EXPR",
		}

		result.type = string_type_map[res_type] or "STRING_EXPR"
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
	local apply_statement -- Forward declaration

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

-- BEGIN 06_entity.lua
local Entity = {}

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

local clock = os.clock

function Entity:_init_globals(global_variables)
	self.fn_name = "init_globals"
	self.global_variables["me"] = { __grug_type = "id", value = self.me_id }

	local old_fn_depth = self.state.fn_depth
	self.state.fn_depth = self.state.fn_depth + 1
	self.start_time = clock()

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
		-- Wrap _run_on_fn in a pcall so that errors thrown by game functions
		-- (registered Lua callbacks) are caught here rather than inside
		-- _run_game_fn.  Keeping the pcall at this outer level means the hot
		-- inner loop (_run_game_fn -> wrapper -> game fn) is pcall-free, which
		-- lets LuaJIT trace through game function returns without hitting
		-- "NYI: return to lower frame".
		local ok, err = pcall(self2._run_on_fn, self2, t._key, ...)
		if not ok then
			self2._flow = nil
			-- Game functions may signal errors by throwing a table with
			-- type = "GAME_FN_ERROR".  Handle those exactly as _run_game_fn
			-- used to, then return without re-throwing.
			if type(err) == "table" and err.type == "GAME_FN_ERROR" then
				self2.state.runtime_error_handler(err.reason, "GAME_FN_ERROR", self2.fn_name, self2.file.relative_path)
				return
			end
			-- Any other Lua error: re-throw to the caller.
			error(err, 0)
		end
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
		return self:_run_helper_fn(call_expr.fn_name, args)
	else
		return self:_run_game_fn(call_expr.fn_name, args)
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

function Entity:_run_helper_fn(name, args)
	local helper_fn = self.file.helper_fns[name]
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

function Entity:_run_game_fn(name, args)
	local game_fn = self.file.game_fns[name]
	assert(game_fn)

	local parent_fn_name = self.fn_name

	-- Get or create a wrapper specific to this argument count.
	local wrapper = _get_wrapper(#args)

	-- Call directly (no pcall) so that LuaJIT can trace through game function
	-- calls without hitting "NYI: return to lower frame" at a C pcall boundary.
	-- Errors from game functions propagate up to _on_fn_proxy_mt.__call, which
	-- wraps the entire _run_on_fn in a pcall and handles GAME_FN_ERROR there.
	local result = wrapper(game_fn, self.state, args)

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

-- BEGIN 07_grug_file.lua
local GrugFile = {}
GrugFile.__index = function(self, key)
	-- Allow method lookups
	if GrugFile[key] then
		return GrugFile[key]
	end

	error(("GrugFile '%s' is not a directory and cannot be indexed"):format(self.relative_path), 2)
end

function GrugFile.new(
	relative_path,
	mod,
	global_variables,
	on_fns,
	helper_fns,
	game_fns,
	game_fn_return_types,
	state,
	version
)
	return setmetatable({
		relative_path = relative_path,
		mod = mod,
		global_variables = global_variables,
		on_fns = on_fns,
		helper_fns = helper_fns,
		game_fns = game_fns,
		game_fn_return_types = game_fn_return_types,
		state = state,
		version = version,
		entities = setmetatable({}, { __mode = "k" }), -- Files shouldn't keep entities alive.
	}, GrugFile)
end

function GrugFile:create_entity()
	return Entity.new(self)
end

-- BEGIN 08_grug_dir.lua
local GrugDir = {}

GrugDir.__index = function(self, key)
	-- Raw lookup for methods
	local method = rawget(GrugDir, key)
	if method ~= nil then
		return method
	end

	-- Directory lookup
	local dir = self.dirs[key]
	if dir ~= nil then
		return dir
	end

	-- File lookup
	local file = self.files[key]
	if file ~= nil then
		return file
	end

	error(("%s not found"):format(tostring(key)), 2)
end

function GrugDir.new(name)
	return setmetatable({
		name = name,
		files = {},
		dirs = {},
	}, GrugDir)
end

function GrugDir:create_entity()
	error(("'%s' is a directory, not a file"):format(self.name), 2)
end

-- BEGIN 09_init.lua
local grug = {}
grug.__index = function(self, key)
	-- property-style access: state.mods
	if key == "mods" then
		if self._mods == nil then
			self:update()
		end

		assert(self._mods, "mods not initialized")
		return self._mods
	end

	-- normal method lookup
	return grug[key]
end

-- tests.lua patches grug._GrugEntity._run_game_fn().
grug._GrugEntity = Entity

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

	-- Transfer existing entities from the old file to the new version
	if existing then
		for entity, _ in pairs(existing.entities or {}) do
			entity.file = new_file
			entity:_init_globals(new_file.global_variables)
			new_file.entities[entity] = true
		end
	end

	return new_file
end

local function _update_from_list(self)
	for _, rel_path in ipairs(self.grug_files) do
		local current_dir = self._mods
		local parts = {}
		for part in rel_path:gmatch("[^/]+") do
			table.insert(parts, part)
		end

		-- Build tree
		for i = 1, #parts - 1 do
			local dir_name = parts[i]
			current_dir.dirs[dir_name] = current_dir.dirs[dir_name] or GrugDir.new(dir_name)
			current_dir = current_dir.dirs[dir_name]
		end

		local filename = parts[#parts]
		local existing = current_dir.files[filename]
		local abs_path = self.mods_dir_path .. "/" .. rel_path

		-- Logic check: only recompile if content has changed (version mismatch)
		local text = self.fs.read(abs_path)
		local current_version = self.fs.get_file_version(abs_path, text)

		if not existing or existing.version ~= current_version then
			current_dir.files[filename] = self:_recompile_with_hot_reload(rel_path, existing)
		end
	end
end

-- This (re)compiles grug files using mark-and-sweep.
function grug:update()
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

	local function update_dir(current_path, grug_dir)
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
					update_dir(entry_path, sub)

				-- Inside grug:update() mark-and-sweep scan
				elseif entry_name:sub(-5) == ".grug" then
					local rel_path = entry_path:sub(#self.mods_dir_path + 2)
					seen_files[rel_path] = true

					local existing = grug_dir.files[entry_name]
					local text = self.fs.read(entry_path)
					local current_version = self.fs.get_file_version(entry_path, text)

					if not existing or existing.version ~= current_version then
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
				update_dir(mod_dir_path, sub)
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

local function check_custom_id_is_pascal(type_name)
	-- Validate that a custom ID type name is in PascalCase

	if type_name == nil or type_name == "" then
		error("type_name is empty")
	end

	if type_name:sub(1, 1):match("%l") then
		error("'" .. type_name .. "' seems like a custom ID type, but it doesn't start in Uppercase")
	end

	local bad_char = type_name:match("[^%a%d]")
	if bad_char then
		error(
			"'"
				.. type_name
				.. "' seems like a custom ID type, but it contains '"
				.. bad_char
				.. "', which isn't uppercase/lowercase/a digit"
		)
	end
end

local function get_file_entity_type(grug_filename)
	-- Extract and validate the entity type from a grug filename.
	-- Example: "furnace-BlockEntity.grug" -> "BlockEntity"

	local dash_index = grug_filename:find("%-") -- escape hyphen in pattern

	if not dash_index or dash_index == #grug_filename then
		error("'" .. grug_filename .. "' is missing an entity type in its name")
	end

	local period_index = grug_filename:find("%.", dash_index + 1)

	if not period_index then
		error("'" .. grug_filename .. "' is missing a period in its filename")
	end

	local entity_type = grug_filename:sub(dash_index + 1, period_index - 1)

	if entity_type == "" then
		error("'" .. grug_filename .. "' is missing an entity type in its name")
	end

	check_custom_id_is_pascal(entity_type)

	return entity_type
end

function grug:_compile_grug_file(grug_file_relative_path)
	local grug_file_absolute_path = self.mods_dir_path .. "/" .. grug_file_relative_path

	local text = self.fs.read(grug_file_absolute_path)

	local version = self.fs.get_file_version(grug_file_absolute_path, text)

	local tokens = tokenize(text)

	local ast = Parser.new(tokens):parse()

	local mod = grug_file_relative_path:match("([^/]+)")

	local filename = grug_file_relative_path:match("([^/]+)$")
	local entity_type = get_file_entity_type(filename)

	TypePropagator.new(ast, mod, entity_type, self.mod_api):fill()

	local global_variables, on_fns, helper_fns = {}, {}, {}
	for _, stmt in ipairs(ast) do
		if stmt.stmt_type == "VariableStatement" then
			table.insert(global_variables, stmt)
		elseif stmt.stmt_type == "OnFn" then
			on_fns[stmt.fn_name] = stmt
			stmt.fn_name = nil
		elseif stmt.stmt_type == "HelperFn" then
			helper_fns[stmt.fn_name] = stmt
			stmt.fn_name = nil
		end
	end

	local game_fn_return_types = {}
	for name, decl in pairs(self.mod_api.game_functions) do
		game_fn_return_types[name] = decl.return_type
	end

	return GrugFile.new(
		grug_file_relative_path,
		mod,
		global_variables,
		on_fns,
		helper_fns,
		self.game_fns,
		game_fn_return_types,
		self,
		version
	)
end

function grug:grug_to_json(input_grug_text) -- luacheck: ignore
	local tokens = tokenize(input_grug_text)
	local ast = Parser.new(tokens):parse()
	return ast_to_json_text(ast)
end

function grug:json_to_grug(input_json_text) -- luacheck: ignore
	local ast = json.decode(input_json_text)
	return ast_to_grug(ast)
end

function grug:register(name, fn)
	self.game_fns[name] = fn
end

local function assert_on_functions_sorted(entity_name, on_functions)
	local keys = {}
	for _, fn in ipairs(on_functions) do
		table.insert(keys, fn.name)
	end

	local sorted_keys = { unpack(keys) }
	table.sort(sorted_keys)

	for i, actual in ipairs(keys) do
		local expected = sorted_keys[i]
		if actual ~= expected then
			error(
				string.format(
					"Error: on_functions for entity '%s' must be sorted alphabetically in mod_api.json, "
						.. "so '%s' must come before '%s'",
					entity_name,
					expected,
					actual
				)
			)
		end
	end
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

		local on_functions = entity.on_functions
		if on_functions ~= nil then
			if type(on_functions) ~= "table" then
				error(
					string.format(
						"Error: 'on_functions' for entity '%s' must be a JSON array, but got %s: %s",
						entity_name,
						type(on_functions),
						tostring(on_functions)
					)
				)
			end

			assert_on_functions_sorted(entity_name, on_functions)
		end
	end

	local game_functions = mod_api.game_functions
	if type(game_functions) ~= "table" then
		error(
			string.format("Error: 'game_functions' must be a JSON object, but got %s: %s"),
			type(game_functions),
			tostring(game_functions)
		)
	end
end

local function default_runtime_error_handler(reason, grug_runtime_error_type, on_fn_name, on_fn_path) -- luacheck: ignore
	print("grug runtime error in " .. on_fn_name .. "(): " .. reason .. ", in " .. on_fn_path)
end

local bxor
-- Try LuaJIT / Lua 5.1 BitOp module
local has_bit, bit = pcall(require, "bit")
if has_bit then
	bxor = bit.bxor
else
	-- Try Lua 5.2 bit32 library (fallback for some distributions)
	local has_bit32, bit32 = pcall(require, "bit32")
	if has_bit32 then
		bxor = bit32.bxor
	else
		-- Lua 5.3/5.5: Compile the native XOR opcode.
		-- We use \126 to avoid putting the tilde character in the file.
		bxor = loader("return function(a, b) return a \126 b end")()
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
	local on_fn_time_limit_ms = settings.on_fn_time_limit_ms or 100
	local packages = settings.packages or {}

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
		on_fn_time_limit_ms = on_fn_time_limit_ms,
		packages = packages,
		fs = fs,
		mod_api = mod_api,
		game_fns = {},
		next_id = 0,
		fn_depth = 0,
		_mods = nil,
		grug_files = settings.grug_files,
	}, grug)
end

return grug
