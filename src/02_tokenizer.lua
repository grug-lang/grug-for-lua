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
}

local function error_at(msg, line_number)
	error(msg .. " on line " .. line_number)
end

-- Returns the 1-based column of the character at `pos` (1-based index into `src`).
local function get_column(src, pos)
	local last_newline = 0
	for j = pos - 1, 1, -1 do
		if src:sub(j, j) == "\n" then
			last_newline = j
			break
		end
	end
	return pos - last_newline
end

-- Returns the (whitespace-trimmed) source line that contains `pos` (1-based index into `src`).
local function get_source_line(src, pos)
	local line_start = pos
	while line_start > 1 and src:sub(line_start - 1, line_start - 1) ~= "\n" do
		line_start = line_start - 1
	end

	local line_end = pos
	while line_end <= #src and src:sub(line_end, line_end) ~= "\n" do
		line_end = line_end + 1
	end

	return (src:sub(line_start, line_end - 1):gsub("^%s+", ""))
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

local function tokenize_string(src, line_number, start_idx)
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

local function tokenize(src)
	local tokens = {}
	local i = 1
	local line_number = 1

	while i <= #src do
		local start_i = i
		local start_line = line_number

		local c = src:sub(i, i)
		local double_c = src:sub(i, i + 1)

		-- 1. Double-character symbols (==, !=, >=, <=)
		if DOUBLE_SYMBOLS[double_c] then
			push(tokens, { type = DOUBLE_SYMBOLS[double_c], value = double_c })
			i = i + 2

		-- 2. Single-character symbols (+, -, (, ), etc.)
		elseif SYMBOLS[c] then
			push(tokens, { type = SYMBOLS[c], value = c })
			if c == "\n" then
				line_number = line_number + 1
			end
			i = i + 1

		-- 3. Spaces and Indentation
		elseif c == " " then
			local next_c = src:sub(i + 1, i + 1)

			-- Single space
			if next_c ~= " " then
				push(tokens, { type = "SPACE_TOKEN", value = " " })
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
						),
						line_number
					)
				end

				push(tokens, {
					type = "INDENTATION_TOKEN",
					value = string.rep(" ", spaces),
				})
			end

		-- 4. Standard Strings
		elseif c == '"' then
			local str_val, new_i = tokenize_string(src, line_number, i)
			push(tokens, { type = "STRING_TOKEN", value = str_val })
			i = new_i + 1

		-- 5. Entity Strings (e"...")
		elseif c == "e" and src:sub(i + 1, i + 1) == '"' then
			local str_val, new_i = tokenize_string(src, line_number, i + 1)
			push(tokens, { type = "ENTITY_TOKEN", value = str_val })
			i = new_i + 1

		-- 6. Resource Strings (r"...")
		elseif c == "r" and src:sub(i + 1, i + 1) == '"' then
			local str_val, new_i = tokenize_string(src, line_number, i + 1)
			push(tokens, { type = "RESOURCE_TOKEN", value = str_val })
			i = new_i + 1

		-- 7. Words (Identifiers and Keywords)
		elseif c:match("[%a_]") then
			local start = i
			while i <= #src and src:sub(i, i):match("[%w_]") do
				i = i + 1
			end

			local word = src:sub(start, i - 1)
			if KEYWORDS[word] then
				push(tokens, { type = KEYWORDS[word], value = word })
			else
				push(tokens, { type = "WORD_TOKEN", value = word })
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
						error_at("Encountered two '.' periods in a number", line_number)
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

			push(tokens, { type = "NUMBER_TOKEN", value = num_str })

		-- 9. Comments (# ...)
		elseif c == "#" then
			i = i + 1
			if i > #src or src:sub(i, i) ~= " " then
				error_at("Expected a single space after the '#'", line_number)
			end

			i = i + 1
			local start = i

			while i <= #src and src:sub(i, i) ~= "\n" do
				if src:sub(i, i) == "\0" then
					error_at("Unexpected null byte", line_number)
				end
				i = i + 1
			end

			local comment_len = i - start
			if comment_len == 0 then
				error_at("Expected the comment to contain some text", line_number)
			end

			if src:sub(i - 1, i - 1):match("%s") then
				error_at("A comment has trailing whitespace", line_number)
			end

			push(tokens, { type = "COMMENT_TOKEN", value = src:sub(start, i - 1) })

		-- 10. Fallback Error
		else
			error_at("Unrecognized character '" .. c .. "'", line_number)
		end

		tokens[#tokens].pos = start_i
		tokens[#tokens].line = start_line
	end

	return tokens
end
