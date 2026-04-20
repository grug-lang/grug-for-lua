local SPACES_PER_INDENT = 4

local src

-- TODO: REMOVE!
local function dump(tbl, indent)
    indent = indent or 0
    local prefix = string.rep("  ", indent)

    if type(tbl) ~= "table" then
        print(prefix .. tostring(tbl))
        return
    end

    print(prefix .. "{")
    for k, v in pairs(tbl) do
        io.write(prefix .. "  [" .. tostring(k) .. "] = ")
        if type(v) == "table" then
            dump(v, indent + 1)
        else
            print(tostring(v))
        end
    end
    print(prefix .. "}")
end

local function get_character_line_number(idx)
    local prefix = src:sub(1, idx - 1)
    local _, count = prefix:gsub("\n", "")
    return count + 1
end

local function is_end_of_word(idx)
    if idx > #src then
        return true
    end
    local c = src:sub(idx, idx)
    return not c:match("[%w_]")
end

local function tokenize_string(i)
    local open_quote_index = i
    i = i + 1
    local start = i

    while i <= #src and src:sub(i, i) ~= '"' do
        local c = src:sub(i, i)
        if c == "\0" then
            error("Unexpected null byte on line " .. get_character_line_number(i))
        elseif c == "\\" and i + 1 <= #src and src:sub(i + 1, i + 1) == "\n" then
            error("Unexpected line break in string on line " .. get_character_line_number(i))
        end
        i = i + 1
    end

    if i > #src then
        error('Unclosed " on line ' .. get_character_line_number(open_quote_index))
    end

    return src:sub(start, i - 1), i
end

local function tokenize(input_src)
    src = input_src

    local tokens = {}
    local i = 1

    while i <= #src do
        local c = src:sub(i, i)

        if c == "(" then
            table.insert(tokens, {type = "OPEN_PARENTHESIS_TOKEN", value = c})
            i = i + 1

        elseif c == ")" then
            table.insert(tokens, {type = "CLOSE_PARENTHESIS_TOKEN", value = c})
            i = i + 1

        elseif c == "{" then
            table.insert(tokens, {type = "OPEN_BRACE_TOKEN", value = c})
            i = i + 1

        elseif c == "}" then
            table.insert(tokens, {type = "CLOSE_BRACE_TOKEN", value = c})
            i = i + 1

        elseif c == "+" then
            table.insert(tokens, {type = "PLUS_TOKEN", value = c})
            i = i + 1

        elseif c == "-" then
            table.insert(tokens, {type = "MINUS_TOKEN", value = c})
            i = i + 1

        elseif c == "*" then
            table.insert(tokens, {type = "MULTIPLICATION_TOKEN", value = c})
            i = i + 1

        elseif c == "/" then
            table.insert(tokens, {type = "DIVISION_TOKEN", value = c})
            i = i + 1

        elseif c == "," then
            table.insert(tokens, {type = "COMMA_TOKEN", value = c})
            i = i + 1

        elseif c == ":" then
            table.insert(tokens, {type = "COLON_TOKEN", value = c})
            i = i + 1

        elseif c == "\n" then
            table.insert(tokens, {type = "NEWLINE_TOKEN", value = c})
            i = i + 1

        elseif c == "=" and i + 1 <= #src and src:sub(i + 1, i + 1) == "=" then
            table.insert(tokens, {type = "EQUALS_TOKEN", value = "=="})
            i = i + 2

        elseif c == "!" and i + 1 <= #src and src:sub(i + 1, i + 1) == "=" then
            table.insert(tokens, {type = "NOT_EQUALS_TOKEN", value = "!="})
            i = i + 2

        elseif c == "=" then
            table.insert(tokens, {type = "ASSIGNMENT_TOKEN", value = c})
            i = i + 1

        elseif c == ">" and i + 1 <= #src and src:sub(i + 1, i + 1) == "=" then
            table.insert(tokens, {type = "GREATER_OR_EQUAL_TOKEN", value = ">="})
            i = i + 2

        elseif c == ">" then
            table.insert(tokens, {type = "GREATER_TOKEN", value = ">"})
            i = i + 1

        elseif c == "<" and i + 1 <= #src and src:sub(i + 1, i + 1) == "=" then
            table.insert(tokens, {type = "LESS_OR_EQUAL_TOKEN", value = "<="})
            i = i + 2

        elseif c == "<" then
            table.insert(tokens, {type = "LESS_TOKEN", value = "<"})
            i = i + 1

        elseif src:sub(i, i + 2) == "and" and is_end_of_word(i + 3) then
            table.insert(tokens, {type = "AND_TOKEN", value = "and"})
            i = i + 3

        elseif src:sub(i, i + 1) == "or" and is_end_of_word(i + 2) then
            table.insert(tokens, {type = "OR_TOKEN", value = "or"})
            i = i + 2

        elseif src:sub(i, i + 2) == "not" and is_end_of_word(i + 3) then
            table.insert(tokens, {type = "NOT_TOKEN", value = "not"})
            i = i + 3

        elseif src:sub(i, i + 3) == "true" and is_end_of_word(i + 4) then
            table.insert(tokens, {type = "TRUE_TOKEN", value = "true"})
            i = i + 4

        elseif src:sub(i, i + 4) == "false" and is_end_of_word(i + 5) then
            table.insert(tokens, {type = "FALSE_TOKEN", value = "false"})
            i = i + 5

        elseif src:sub(i, i + 1) == "if" and is_end_of_word(i + 2) then
            table.insert(tokens, {type = "IF_TOKEN", value = "if"})
            i = i + 2

        elseif src:sub(i, i + 3) == "else" and is_end_of_word(i + 4) then
            table.insert(tokens, {type = "ELSE_TOKEN", value = "else"})
            i = i + 4

        elseif src:sub(i, i + 4) == "while" and is_end_of_word(i + 5) then
            table.insert(tokens, {type = "WHILE_TOKEN", value = "while"})
            i = i + 5

        elseif src:sub(i, i + 4) == "break" and is_end_of_word(i + 5) then
            table.insert(tokens, {type = "BREAK_TOKEN", value = "break"})
            i = i + 5

        elseif src:sub(i, i + 5) == "return" and is_end_of_word(i + 6) then
            table.insert(tokens, {type = "RETURN_TOKEN", value = "return"})
            i = i + 6

        elseif src:sub(i, i + 7) == "continue" and is_end_of_word(i + 8) then
            table.insert(tokens, {type = "CONTINUE_TOKEN", value = "continue"})
            i = i + 8

        elseif c == " " then
            if i + 1 > #src or src:sub(i + 1, i + 1) ~= " " then
                table.insert(tokens, {type = "SPACE_TOKEN", value = " "})
                i = i + 1
            else
                local old_i = i
                while i <= #src and src:sub(i, i) == " " do
                    i = i + 1
                end

                local spaces = i - old_i

                if spaces % SPACES_PER_INDENT ~= 0 then
                    error(string.format(
                        "Encountered %d spaces, while indentation expects multiples of %d spaces, on line %d",
                        spaces,
                        SPACES_PER_INDENT,
                        get_character_line_number(i)
                    ))
                end

                table.insert(tokens, {
                    type = "INDENTATION_TOKEN",
                    value = string.rep(" ", spaces)
                })
            end

        elseif c == '"' then
            local str_val, new_i = tokenize_string(i)
            table.insert(tokens, {type = "STRING_TOKEN", value = str_val})
            i = new_i + 1

        elseif c == "e" and i + 1 <= #src and src:sub(i + 1, i + 1) == '"' then
            i = i + 1
            local str_val, new_i = tokenize_string(i)
            table.insert(tokens, {type = "ENTITY_TOKEN", value = str_val})
            i = new_i + 1

        elseif c == "r" and i + 1 <= #src and src:sub(i + 1, i + 1) == '"' then
            i = i + 1
            local str_val, new_i = tokenize_string(i)
            table.insert(tokens, {type = "RESOURCE_TOKEN", value = str_val})
            i = new_i + 1

        elseif c:match("[%a_]") then
            local start = i
            while i <= #src and src:sub(i, i):match("[%w_]") do
                i = i + 1
            end
            table.insert(tokens, {
                type = "WORD_TOKEN",
                value = src:sub(start, i - 1)
            })

        elseif c:match("%d") then
            local start = i
            local seen_period = false
            i = i + 1

            while i <= #src and (src:sub(i, i):match("%d") or src:sub(i, i) == ".") do
                if src:sub(i, i) == "." then
                    if seen_period then
                        error("Encountered two '.' periods in a number on line " .. get_character_line_number(i))
                    end
                    seen_period = true
                end
                i = i + 1
            end

            if src:sub(i - 1, i - 1) == "." then
                error("Missing digit after decimal point in '" .. src:sub(start, i - 1) .. "'")
            end

            table.insert(tokens, {
                type = "NUMBER_TOKEN",
                value = src:sub(start, i - 1)
            })

        elseif c == "#" then
            i = i + 1

            if i > #src or src:sub(i, i) ~= " " then
                error("Expected a single space after the '#' on line " .. get_character_line_number(i))
            end

            i = i + 1
            local start = i

            while i <= #src and src:sub(i, i) ~= "\n" do
                if src:sub(i, i) == "\0" then
                    error("Unexpected null byte on line " .. get_character_line_number(i))
                end
                i = i + 1
            end

            local comment_len = i - start
            if comment_len == 0 then
                error("Expected the comment to contain some text on line " .. get_character_line_number(i))
            end

            if src:sub(i - 1, i - 1):match("%s") then
                error("A comment has trailing whitespace on line " .. get_character_line_number(i))
            end

            table.insert(tokens, {
                type = "COMMENT_TOKEN",
                value = src:sub(start, i - 1)
            })

        else
            error("Unrecognized character '" .. c .. "' on line " .. get_character_line_number(i))
        end
    end

    return tokens
end
