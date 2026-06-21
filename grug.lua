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

local function push(t, value)
	t[#t + 1] = value
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
			push(res, encode(v, stack))
		end
		stack[val] = nil
		return "[" .. table.concat(res, ",") .. "]"
	else
		-- Treat as an object
		for k, v in pairs(val) do
			if type(k) ~= "string" then
				error("invalid table: mixed or invalid key types")
			end
			push(res, encode(k, stack) .. ":" .. encode(v, stack))
		end
		stack[val] = nil
		return "{" .. table.concat(res, ",") .. "}"
	end
end

local function encode_string(val)
	local res = {}
	local n = 0

	for i = 1, #val do
		local c = val:sub(i, i)
		local b = val:byte(i)

		if b <= 31 or c == "\\" or c == '"' then
			n = n + 1
			res[n] = escape_char(c)
		else
			n = n + 1
			res[n] = c
		end
	end

	return '"' .. table.concat(res) .. '"'
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
	["export"] = "EXPORT_TOKEN",
	["local"] = "LOCAL_TOKEN",
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
	["\r\n"] = "NEWLINE_TOKEN",
}

-- Returns the 1-based column of the character at `pos` (1-based index into `src`).
local function get_column(src, pos)
	local column = 1
	if pos > #src then
		error("expected span to be within source code bounds")
	end

	while column < pos and src:sub(pos - column, pos - column) ~= "\n" do
		column = column + 1
	end
	return column
end

-- Returns the (whitespace-trimmed) source line that contains `pos` (1-based index into `src`).
local function get_source_line(src, pos)
	local line_start_index = pos
	local line_end_index = pos

	if pos > #src then
		error("expected span to be within source code bounds")
	end

	if src:sub(line_start_index, line_start_index) == "\n" then
		line_start_index = line_start_index - 1
	end

	while line_start_index >= 1 and src:sub(line_start_index, line_start_index) ~= "\n" do
		line_start_index = line_start_index - 1
	end

	while line_end_index <= #src and src:sub(line_end_index, line_end_index) ~= "\n" do
		line_end_index = line_end_index + 1
	end

	local line = src:sub(line_start_index + 1, line_end_index - 1)
	return (line:gsub("^%s+", ""))
end

local function new_tokenizer_error(msg, src, file_path, line, pos)
	local column = get_column(src, pos)
	local source_line = get_source_line(src, pos)

	return string.format("  in (%s:%d:%d)\nError: %s\n%d $ %s", file_path, line, column, msg, line, source_line)
end

-- Human-readable representation of each token type, used in "Expected X but got Y" errors.
local TOKEN_TYPE_STR = {
	OPEN_PARENTHESIS_TOKEN = "'('",
	CLOSE_PARENTHESIS_TOKEN = "')'",
	OPEN_BRACE_TOKEN = "'{'",
	CLOSE_BRACE_TOKEN = "'}'",
	PLUS_TOKEN = "'+'",
	MINUS_TOKEN = "'-'",
	MULTIPLICATION_TOKEN = "'*'",
	DIVISION_TOKEN = "'/'",
	COMMA_TOKEN = "','",
	COLON_TOKEN = "':'",
	NEWLINE_TOKEN = "line break ('\\n')",
	EQUALS_TOKEN = "'=='",
	NOT_EQUALS_TOKEN = "'!='",
	ASSIGNMENT_TOKEN = "'='",
	GREATER_OR_EQUAL_TOKEN = "'>='",
	GREATER_TOKEN = "'>'",
	LESS_OR_EQUAL_TOKEN = "'<='",
	LESS_TOKEN = "'<'",
	AND_TOKEN = "'and'",
	OR_TOKEN = "'or'",
	NOT_TOKEN = "'not'",
	TRUE_TOKEN = "'true'",
	FALSE_TOKEN = "'false'",
	IF_TOKEN = "'if'",
	ELSE_TOKEN = "'else'",
	WHILE_TOKEN = "'while'",
	BREAK_TOKEN = "'break'",
	RETURN_TOKEN = "'return'",
	CONTINUE_TOKEN = "'continue'",
	EXPORT_TOKEN = "'export'",
	LOCAL_TOKEN = "'local'",
	SPACE_TOKEN = "space (' ')",
	INDENTATION_TOKEN = "indentation",
	STRING_TOKEN = "string",
	ENTITY_TOKEN = "entity string",
	RESOURCE_TOKEN = "resource string",
	WORD_TOKEN = "word",
	NUMBER_TOKEN = "number",
	COMMENT_TOKEN = "comment",
}

local function token_type_str(token_type)
	return TOKEN_TYPE_STR[token_type] or token_type
end

local function tokenize_string(src, file_path, line_number, start_idx)
	local open_quote_line = line_number
	local open_quote_idx = start_idx
	local idx = start_idx + 1
	local start_content = idx
	while idx <= #src do
		local c = src:sub(idx, idx)
		if c == '"' then
			break
		elseif c == "\n" then
			line_number = line_number + 1
		elseif c == "\0" then
			error(new_tokenizer_error("Unexpected null byte on line " .. line_number, src, file_path, line_number, idx))
		elseif c == "\\" and src:sub(idx + 1, idx + 1) == "\n" then
			error(
				new_tokenizer_error(
					"Unexpected line break in string on line " .. line_number,
					src,
					file_path,
					line_number,
					idx
				)
			)
		end
		idx = idx + 1
	end
	if idx > #src then
		error(
			new_tokenizer_error(
				'Unclosed " on line ' .. open_quote_line,
				src,
				file_path,
				open_quote_line,
				open_quote_idx
			)
		)
	end
	return src:sub(start_content, idx - 1), idx, line_number
end

local function add_token(tokens, type, value, pos, line_number)
	push(tokens, { type = type, value = value, pos = pos, line = line_number })
end

local function tokenize(src, file_path)
	local tokens = {}
	local i = 1
	local line_number = 1

	while i <= #src do
		local c = src:sub(i, i)
		local double_c = src:sub(i, i + 1)

		-- 1. Double-character symbols (==, !=, >=, <=, \r\n)
		if DOUBLE_SYMBOLS[double_c] then
			add_token(tokens, DOUBLE_SYMBOLS[double_c], double_c, i, line_number)
			if double_c == "\r\n" then
				line_number = line_number + 1
			end
			i = i + 2

		-- 2. Single-character symbols (+, -, (, ), etc.)
		elseif SYMBOLS[c] then
			add_token(tokens, SYMBOLS[c], c, i, line_number)
			if c == "\n" then
				line_number = line_number + 1
			end
			i = i + 1

		-- 3. Spaces and Indentation
		elseif c == " " then
			local next_c = src:sub(i + 1, i + 1)

			-- Single space
			if next_c ~= " " then
				add_token(tokens, "SPACE_TOKEN", " ", i, line_number)
				i = i + 1

			-- Indentation block
			else
				local old_i = i
				while i <= #src and src:sub(i, i) == " " do
					i = i + 1
				end

				local spaces = i - old_i
				if spaces % SPACES_PER_INDENT ~= 0 then
					error(
						new_tokenizer_error(
							string.format(
								"Expected multiple of %d spaces but found %d spaces",
								SPACES_PER_INDENT,
								spaces
							),
							src,
							file_path,
							line_number,
							old_i
						)
					)
				end

				add_token(tokens, "INDENTATION_TOKEN", string.rep(" ", spaces), old_i, line_number)
			end

		-- 4. Standard Strings
		elseif c == '"' then
			local token_start = i
			local str_val, new_i, new_line = tokenize_string(src, file_path, line_number, i)
			add_token(tokens, "STRING_TOKEN", str_val, token_start, line_number)
			i = new_i + 1
			line_number = new_line

		-- 5. Entity Strings (e"...")
		elseif c == "e" and src:sub(i + 1, i + 1) == '"' then
			local token_start = i
			local str_val, new_i, new_line = tokenize_string(src, file_path, line_number, i + 1)
			add_token(tokens, "ENTITY_TOKEN", str_val, token_start, line_number)
			i = new_i + 1
			line_number = new_line

		-- 6. Resource Strings (r"...")
		elseif c == "r" and src:sub(i + 1, i + 1) == '"' then
			local token_start = i
			local str_val, new_i, new_line = tokenize_string(src, file_path, line_number, i + 1)
			add_token(tokens, "RESOURCE_TOKEN", str_val, token_start, line_number)
			i = new_i + 1
			line_number = new_line

		-- 7. Words (Identifiers and Keywords)
		elseif c:match("[%a_]") then
			local start = i
			while i <= #src and src:sub(i, i):match("[%w_]") do
				i = i + 1
			end

			local word = src:sub(start, i - 1)
			if KEYWORDS[word] then
				add_token(tokens, KEYWORDS[word], word, start, line_number)
			else
				add_token(tokens, "WORD_TOKEN", word, start, line_number)
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
						error(
							new_tokenizer_error(
								"Encountered two '.' periods in a number on line " .. line_number,
								src,
								file_path,
								line_number,
								i
							)
						)
					end
					seen_period = true
					i = i + 1
				else
					break
				end
			end

			local num_str = src:sub(start, i - 1)
			if src:sub(i - 1, i - 1) == "." then
				error(
					new_tokenizer_error(
						"Missing digit after decimal point in '" .. num_str .. "'",
						src,
						file_path,
						line_number,
						i
					)
				)
			end

			add_token(tokens, "NUMBER_TOKEN", num_str, start, line_number)

		-- 9. Comments (# ...)
		elseif c == "#" then
			local token_start = i
			i = i + 1
			if i > #src or src:sub(i, i) ~= " " then
				error(new_tokenizer_error("Expected space (' ') after '#'", src, file_path, line_number, i))
			end

			i = i + 1
			local start = i

			while i <= #src and src:sub(i, i) ~= "\n" do
				if src:sub(i, i) == "\0" then
					error(
						new_tokenizer_error(
							"Unexpected null byte on line " .. line_number,
							src,
							file_path,
							line_number,
							i
						)
					)
				end
				i = i + 1
			end

			local comment_len = i - start
			if comment_len == 0 then
				error(new_tokenizer_error("Expected comment to contain some text", src, file_path, line_number, i - 1))
			end

			if src:sub(i - 1, i - 1):match("%s") then
				error(
					new_tokenizer_error(
						"A comment has trailing whitespace on line " .. line_number,
						src,
						file_path,
						line_number,
						i
					)
				)
			end

			add_token(tokens, "COMMENT_TOKEN", src:sub(start, i - 1), token_start, line_number)

		-- 10. Fallback Error
		else
			error(new_tokenizer_error("Unrecognized character '" .. c .. "'", src, file_path, line_number, i))
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

function TypePropagator.new(ast, mod, entity_type, mod_api, src, file_path, mods_dir_path)
	local self = setmetatable({
		ast = ast,
		mod = mod,
		file_entity_type = entity_type,
		mod_api = mod_api,
		src = src,
		file_path = file_path,
		mods_dir_path = mods_dir_path,
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

local function file_exists(path)
	local f = io.open(path, "r")
	if f ~= nil then
		io.close(f)
		return true
	else
		return false
	end
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

	local full_path = self.mods_dir_path .. "/" .. self.mod .. "/" .. str
	if not file_exists(full_path) then
		error(self:new_error("resource '" .. str .. "' does not exist", span))
	end
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

-- BEGIN 05_serializer.lua
local function map_list(list, fn)
	local result = {}
	for _, v in ipairs(list or {}) do
		push(result, fn(v))
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
-- grug Output
-- ======================
local function write(text, output)
	push(output, text)
end

local function indent(indentation, output)
	write(string.rep("    ", indentation[1]), output)
end

local function apply_expr(expr, output)
	local t = expr.type

	if t == "TRUE_EXPR" then
		write("true", output)
	elseif t == "FALSE_EXPR" then
		write("false", output)
	elseif t == "STRING_EXPR" then
		write('"' .. expr.str .. '"', output)
	elseif t == "ENTITY_EXPR" then
		write('e"' .. expr.str .. '"', output)
	elseif t == "RESOURCE_EXPR" then
		write('r"' .. expr.str .. '"', output)
	elseif t == "IDENTIFIER_EXPR" then
		write(expr.str, output)
	elseif t == "NUMBER_EXPR" then
		write(tostring(expr.value), output)
	elseif t == "UNARY_EXPR" then
		write(expr.operator == "MINUS_TOKEN" and "-" or "not ", output)
		apply_expr(expr.expr, output)
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
		apply_expr(expr.left_expr, output)
		write(" " .. op_map[expr.operator] .. " ", output)
		apply_expr(expr.right_expr, output)
	elseif t == "LOGICAL_EXPR" then
		apply_expr(expr.left_expr, output)
		write(expr.operator == "AND_TOKEN" and " and " or " or ", output)
		apply_expr(expr.right_expr, output)
	elseif t == "CALL_EXPR" then
		write(expr.name .. "(", output)
		for i, arg in ipairs(expr.arguments or {}) do
			if i > 1 then
				write(", ", output)
			end
			apply_expr(arg, output)
		end
		write(")", output)
	elseif t == "PARENTHESIZED_EXPR" then
		write("(", output)
		apply_expr(expr.expr, output)
		write(")", output)
	end
end

local apply_statements -- Forward declaration
local function apply_if(stmt, indentation, output)
	write("if ", output)
	apply_expr(stmt.condition, output)
	write(" {\n", output)

	apply_statements(stmt.if_statements, indentation, output)

	if stmt.else_statements and #stmt.else_statements > 0 then
		indent(indentation, output)
		write("} else ", output)

		local first = stmt.else_statements[1]
		if first and first.type == "IF_STATEMENT" then
			apply_if(first, indentation, output)
		else
			write("{\n", output)
			apply_statements(stmt.else_statements, indentation, output)
			indent(indentation, output)
			write("}\n", output)
		end
	else
		indent(indentation, output)
		write("}\n", output)
	end
end

local function apply_statement(stmt, indentation, output)
	local t = stmt.type

	if t == "VARIABLE_STATEMENT" then
		write(stmt.name, output)
		if stmt.variable_type then
			write(": " .. stmt.variable_type, output)
		end
		write(" = ", output)
		apply_expr(stmt.assignment, output)
		write("\n", output)
	elseif t == "CALL_STATEMENT" then
		write(stmt.name .. "(", output)
		for i, arg in ipairs(stmt.arguments or {}) do
			if i > 1 then
				write(", ", output)
			end
			apply_expr(arg, output)
		end
		write(")\n", output)
	elseif t == "IF_STATEMENT" then
		apply_if(stmt, indentation, output)
	elseif t == "RETURN_STATEMENT" then
		write("return", output)
		if stmt.expr then
			write(" ", output)
			apply_expr(stmt.expr, output)
		end
		write("\n", output)
	elseif t == "WHILE_STATEMENT" then
		write("while ", output)
		apply_expr(stmt.condition, output)
		write(" {\n", output)
		apply_statements(stmt.statements, indentation, output)
		indent(indentation, output)
		write("}\n", output)
	elseif t == "BREAK_STATEMENT" then
		write("break\n", output)
	elseif t == "CONTINUE_STATEMENT" then
		write("continue\n", output)
	elseif t == "COMMENT_STATEMENT" then
		write("# " .. stmt.comment .. "\n", output)
	end
end

apply_statements = function(statements, indentation, output)
	indentation[1] = indentation[1] + 1
	for _, s in ipairs(statements or {}) do
		if s.type == "EMPTY_LINE_STATEMENT" then
			write("\n", output)
		else
			indent(indentation, output)
			apply_statement(s, indentation, output)
		end
	end
	indentation[1] = indentation[1] - 1
end

local function apply_args(args, output)
	for i, a in ipairs(args or {}) do
		if i > 1 then
			write(", ", output)
		end
		write(a.name .. ": " .. a.type, output)
	end
end

local function ast_to_grug(ast)
	local output, indentation = {}, { 0 }

	for _, stmt in ipairs(ast) do
		local t = stmt.type

		if t == "GLOBAL_VARIABLE" then
			write(stmt.name .. ": " .. stmt.variable_type .. " = ", output)
			apply_expr(stmt.assignment, output)
			write("\n", output)
		elseif t == "GLOBAL_ON_FN" or t == "GLOBAL_HELPER_FN" then
			if t == "GLOBAL_ON_FN" then
				write("export ", output)
			elseif t == "GLOBAL_HELPER_FN" then
				write("local ", output)
			end

			write(stmt.name .. "(", output)
			apply_args(stmt.arguments, output)
			write(")", output)

			if t == "GLOBAL_HELPER_FN" and stmt.return_type then
				write(" " .. stmt.return_type, output)
			end

			write(" {\n", output)
			apply_statements(stmt.statements, indentation, output)
			write("}\n", output)
		elseif t == "GLOBAL_EMPTY_LINE" then
			write("\n", output)
		elseif t == "GLOBAL_COMMENT" then
			write("# " .. stmt.comment .. "\n", output)
		end
	end

	return table.concat(output)
end

-- BEGIN 06_grug_entity.lua
--
-- GrugEntity: the thin public-facing entity wrapper.
-- It holds the file/state references and a backend-specific `data` field.
-- on_ functions are looked up via __index and routed through the backend.
--
local GrugEntity = {}

function GrugEntity:__index(key) -- luacheck: ignore
	local val = rawget(GrugEntity, key)
	if val ~= nil then
		return val
	end

	local fn = self.state.backend:get_export_fn(self, key)
	rawset(self, key, fn) -- cache: future accesses hit the table directly, no __index
	return fn
end

-- Create a new GrugEntity for `file`.
-- Registers it in file.entities (weak), increments state.next_id,
-- then delegates to backend:init_entity to populate entity.data.
-- May raise a Lua error if a runtime error occurs during initialisation.
function GrugEntity.new(file)
	local self = setmetatable({
		me_id = file.state.next_id,
		file = file,
		state = file.state,
		data = nil, -- set by backend:init_entity
	}, GrugEntity)

	file.entities[self] = true
	file.state.next_id = file.state.next_id + 1

	-- Delegate initialisation of backend-specific data.
	-- For the InterpreterBackend this evaluates global-variable
	-- initialisers and stores an _InterpreterEntity in self.data.
	file.state.backend:init_entity(self)

	return self
end

-- BEGIN 07_transpiler_backend.lua
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

	if self.safe_mode and fn_name:sub(1, 1) ~= "_" and fn.needs_clock then
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

-- BEGIN 08_grug_file.lua
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
	export_fns,
	local_fns,
	host_fns,
	host_fn_return_types,
	state,
	version
)
	return setmetatable({
		relative_path = relative_path,
		mod = mod,
		global_variables = global_variables,
		export_fns = export_fns,
		local_fns = local_fns,
		host_fns = host_fns,
		host_fn_return_types = host_fn_return_types,
		state = state,
		version = version,
		entities = setmetatable({}, { __mode = "k" }), -- Files shouldn't keep entities alive.
	}, GrugFile)
end

function GrugFile:create_entity()
	return GrugEntity.new(self)
end

-- BEGIN 09_grug_dir.lua
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

-- BEGIN 10_init.lua
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

function grug:register(name, fn)
	self.host_fns[name] = fn
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

return grug
