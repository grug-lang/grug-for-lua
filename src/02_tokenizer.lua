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
