local grug = {}

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
  [ "\\" ] = "\\",
  [ "\"" ] = "\"",
  [ "\b" ] = "b",
  [ "\f" ] = "f",
  [ "\n" ] = "n",
  [ "\r" ] = "r",
  [ "\t" ] = "t",
}

local escape_char_map_inv = { [ "/" ] = "/" }
for k, v in pairs(escape_char_map) do
  escape_char_map_inv[v] = k
end


local function escape_char(c)
  return "\\" .. (escape_char_map[c] or string.format("u%04x", c:byte()))
end


local function encode_nil(val)
  return "null"
end


local function encode_table(val, stack)
  local res = {}
  stack = stack or {}

  -- Circular reference?
  if stack[val] then error("circular reference") end

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
    for i, v in ipairs(val) do
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
  [ "nil"     ] = encode_nil,
  [ "table"   ] = encode_table,
  [ "string"  ] = encode_string,
  [ "number"  ] = encode_number,
  [ "boolean" ] = tostring,
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
  return ( encode(val) )
end


-------------------------------------------------------------------------------
-- Decode
-------------------------------------------------------------------------------

local parse

local function create_set(...)
  local res = {}
  for i = 1, select("#", ...) do
    res[ select(i, ...) ] = true
  end
  return res
end

local space_chars   = create_set(" ", "\t", "\r", "\n")
local delim_chars   = create_set(" ", "\t", "\r", "\n", "]", "}", ",")
local escape_chars  = create_set("\\", "/", '"', "b", "f", "n", "r", "t", "u")
local literals      = create_set("true", "false", "null")

local literal_map = {
  [ "true"  ] = true,
  [ "false" ] = false,
  [ "null"  ] = nil,
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
  error( string.format("%s at line %d col %d", msg, line_count, col_count) )
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
    return string.char(f(n / 262144) + 240, f(n % 262144 / 4096) + 128,
                       f(n % 4096 / 64) + 128, n % 64 + 128)
  end
  error( string.format("invalid unicode codepoint '%x'", n) )
end


local function parse_unicode_escape(s)
  local n1 = tonumber( s:sub(1, 4),  16 )
  local n2 = tonumber( s:sub(7, 10), 16 )
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
    if chr == "]" then break end
    if chr ~= "," then decode_error(str, i, "expected ']' or ','") end
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
    if chr == "}" then break end
    if chr ~= "," then decode_error(str, i, "expected '}' or ','") end
  end
  return res, i
end


local char_func_map = {
  [ '"' ] = parse_string,
  [ "0" ] = parse_number,
  [ "1" ] = parse_number,
  [ "2" ] = parse_number,
  [ "3" ] = parse_number,
  [ "4" ] = parse_number,
  [ "5" ] = parse_number,
  [ "6" ] = parse_number,
  [ "7" ] = parse_number,
  [ "8" ] = parse_number,
  [ "9" ] = parse_number,
  [ "-" ] = parse_number,
  [ "t" ] = parse_literal,
  [ "f" ] = parse_literal,
  [ "n" ] = parse_literal,
  [ "[" ] = parse_array,
  [ "{" ] = parse_object,
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

local src

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

-- BEGIN 03_parser.lua
local MAX_PARSING_DEPTH = 100
local SPACES_PER_INDENT = 4

local MIN_F64 = 2.2250738585072014e-308
local MAX_F64 = 1.7976931348623157e308

-- Expressions
local function TrueExpr()
    return { result = "bool" }
end

local function FalseExpr()
    return { result = "bool" }
end

local function StringExpr(s)
    return { string = s, result = "string" }
end

local function ResourceExpr(s)
    return { string = s, result = "resource" }
end

local function EntityExpr(s)
    return { string = s, result = "entity" }
end

local function IdentifierExpr(name)
    return { name = name }
end

local function NumberExpr(value, string_val)
    return { value = value, string = string_val, result = "number" }
end

local function UnaryExpr(op, expr)
    return { operator = op, expr = expr }
end

local function BinaryExpr(l, op, r)
    return { left_expr = l, operator = op, right_expr = r }
end

local function LogicalExpr(l, op, r)
    return { left_expr = l, operator = op, right_expr = r }
end

local function CallExpr(name)
    return { fn_name = name, arguments = {} }
end

local function ParenthesizedExpr(expr)
    return { expr = expr }
end

-- Statements
local function VariableStatement(name, t, tname, expr)
    return { stmt_type = "VariableStatement", name = name, type = t, type_name = tname, expr = expr }
end

local function CallStatement(expr)
    return { stmt_type = "CallStatement", expr = expr }
end

local function IfStatement(cond, ifb, elseb)
    return { stmt_type = "IfStatement", condition = cond, if_body = ifb, else_body = elseb }
end

local function ReturnStatement(value)
    return { stmt_type = "ReturnStatement", value = value }
end

local function WhileStatement(cond, body)
    return { stmt_type = "WhileStatement", condition = cond, body_statements = body }
end

local function BreakStatement()
    return { stmt_type = "BreakStatement" }
end

local function ContinueStatement()
    return { stmt_type = "ContinueStatement" }
end

local function EmptyLineStatement()
    return { stmt_type = "EmptyLineStatement" }
end

local function CommentStatement(s)
    return { stmt_type = "CommentStatement", string = s }
end

-- Top-level AST Nodes
local function Argument(name, t, tname)
    return { name = name, type = t, type_name = tname }
end

local function OnFn(name)
    return { stmt_type = "OnFn", fn_name = name, arguments = {}, body_statements = {} }
end

local function HelperFn(name)
    return { stmt_type = "HelperFn", fn_name = name, arguments = {}, body_statements = {} }
end


-- Parser
local Parser = {}
Parser.__index = Parser

function Parser.new(tokens)
    return setmetatable({
        tokens = tokens,
        ast = {},
        helper_fns = {},
        on_fns = {},
        statements = {},
        arguments = {},
        parsing_depth = 0,
        loop_depth = 0,
        indentation = 0,
        called_helper_fn_names = {}
    }, Parser)
end

function Parser:parse()
    local seen_on_fn = false
    local seen_newline = false
    local newline_allowed = false
    local newline_required = false

    -- Use a table to pass index by reference
    local i = {1}

    while i[1] <= #self.tokens do
        local token = self.tokens[i[1]]
        local next_token = self.tokens[i[1] + 1]

        if token.type == "WORD_TOKEN" and next_token and next_token.type == "COLON_TOKEN" then
            if seen_on_fn then
                error("Move the global variable '" .. token.value .. "' so it is above the on_ functions")
            end

            table.insert(self.ast, self:parse_global_variable(i))
            self:consume_type(i, "NEWLINE_TOKEN")

            newline_allowed = true
            newline_required = true

        elseif token.type == "WORD_TOKEN" and string.sub(token.value, 1, 3) == "on_" and next_token and next_token.type == "OPEN_PARENTHESIS_TOKEN" then
            if next(self.helper_fns) ~= nil then
                error(token.value .. "() must be defined before all helper_ functions")
            end
            if newline_required then
                error("Expected an empty line, on line " .. self:get_token_line_number(i[1]))
            end

            local fn = self:parse_on_fn(i)
            if self.on_fns[fn.fn_name] then
                error("The function '" .. fn.fn_name .. "' was defined several times in the same file")
            end
            self.on_fns[fn.fn_name] = fn

            self:consume_type(i, "NEWLINE_TOKEN")

            seen_on_fn = true
            newline_allowed = true
            newline_required = true

        elseif token.type == "WORD_TOKEN" and string.sub(token.value, 1, 7) == "helper_" and next_token and next_token.type == "OPEN_PARENTHESIS_TOKEN" then
            if newline_required then
                error("Expected an empty line, on line " .. self:get_token_line_number(i[1]))
            end

            local fn = self:parse_helper_fn(i)
            if self.helper_fns[fn.fn_name] then
                error("The function '" .. fn.fn_name .. "' was defined several times in the same file")
            end
            self.helper_fns[fn.fn_name] = fn

            self:consume_type(i, "NEWLINE_TOKEN")

            newline_allowed = true
            newline_required = true

        elseif token.type == "NEWLINE_TOKEN" then
            if not newline_allowed then
                error("Unexpected empty line, on line " .. self:get_token_line_number(i[1]))
            end

            seen_newline = true
            newline_allowed = false
            newline_required = false

            table.insert(self.ast, EmptyLineStatement())
            i[1] = i[1] + 1

        elseif token.type == "COMMENT_TOKEN" then
            newline_allowed = true
            table.insert(self.ast, CommentStatement(token.value))
            i[1] = i[1] + 1
            self:consume_type(i, "NEWLINE_TOKEN")

        else
            error("Unexpected token '" .. tostring(token.value) .. "' on line " .. self:get_token_line_number(i[1]))
        end
    end

    if seen_newline and not newline_allowed then
        error("Unexpected empty line, on line " .. self:get_token_line_number(#self.tokens))
    end

    return self.ast
end

function Parser:get_token_line_number(idx)
    local line = 1
    for i = 1, idx - 1 do
        if self.tokens[i] and self.tokens[i].type == "NEWLINE_TOKEN" then
            line = line + 1
        end
    end
    return line
end

function Parser:peek(i)
    if i > #self.tokens then
        -- Subtract 1 to match the 0-based indexing expected by the test runner
        error("token_index " .. (i - 1) .. " was out of bounds in peek_token()")
    end
    return self.tokens[i]
end

function Parser:consume(i)
    local t = self:peek(i[1])
    i[1] = i[1] + 1
    return t
end

function Parser:assert_type(idx, expected)
    local t = self:peek(idx)
    if t.type ~= expected then
        error("Expected token type " .. expected .. ", but got " .. t.type .. " on line " .. self:get_token_line_number(idx))
    end
end

function Parser:consume_type(i, expected)
    self:assert_type(i[1], expected)
    i[1] = i[1] + 1
end

function Parser:consume_space(i)
    local tok = self:peek(i[1])
    if tok.type ~= "SPACE_TOKEN" then
        error("Expected token type SPACE_TOKEN, but got " .. tok.type .. " on line " .. self:get_token_line_number(i[1]))
    end
    i[1] = i[1] + 1
end

function Parser:consume_indentation(i)
    self:assert_type(i[1], "INDENTATION_TOKEN")
    local spaces = string.len(self:peek(i[1]).value)
    local expected = self.indentation * SPACES_PER_INDENT
    if spaces ~= expected then
        error("Expected " .. expected .. " spaces, but got " .. spaces .. " spaces on line " .. self:get_token_line_number(i[1]))
    end
    i[1] = i[1] + 1
end

function Parser:is_end_of_block(i)
    local tok = self:peek(i[1])
    if tok.type == "CLOSE_BRACE_TOKEN" then
        return true
    elseif tok.type == "NEWLINE_TOKEN" then
        return false
    elseif tok.type == "INDENTATION_TOKEN" then
        local spaces = string.len(tok.value)
        return spaces == (self.indentation - 1) * SPACES_PER_INDENT
    else
        error("Expected indentation, newline, or '}', but got '" .. tostring(tok.value) .. "' on line " .. self:get_token_line_number(i[1]))
    end
end

function Parser:increase_parsing_depth()
    self.parsing_depth = self.parsing_depth + 1
    if self.parsing_depth >= MAX_PARSING_DEPTH then
        error("There is a function that contains more than " .. MAX_PARSING_DEPTH .. " levels of nested expressions")
    end
end

function Parser:decrease_parsing_depth()
    self.parsing_depth = self.parsing_depth - 1
end

function Parser:parse_type(type_str)
    if type_str == "bool" then return "BOOL" end
    if type_str == "number" then return "NUMBER" end
    if type_str == "string" then return "STRING" end
    if type_str == "resource" then return "RESOURCE" end
    if type_str == "entity" then return "ENTITY" end
    return "ID"
end

-- Statements & Functions
function Parser:parse_arguments(i)
    local arguments = {}

    local name_token = self:consume(i)
    local arg_name = name_token.value

    self:consume_type(i, "COLON_TOKEN")
    self:consume_space(i)
    self:assert_type(i[1], "WORD_TOKEN")
    
    local type_token = self:consume(i)
    local type_name = type_token.value
    local arg_type = self:parse_type(type_name)

    if arg_type == "RESOURCE" or arg_type == "ENTITY" then
        error("The argument '" .. arg_name .. "' can't have '" .. type_name .. "' as its type")
    end

    table.insert(arguments, Argument(arg_name, arg_type, type_name))

    while true do
        if i[1] > #self.tokens or self:peek(i[1]).type ~= "COMMA_TOKEN" then
            break
        end
        i[1] = i[1] + 1

        self:consume_space(i)
        self:assert_type(i[1], "WORD_TOKEN")
        name_token = self:consume(i)
        arg_name = name_token.value

        self:consume_type(i, "COLON_TOKEN")
        self:consume_space(i)

        self:assert_type(i[1], "WORD_TOKEN")
        type_token = self:consume(i)

        type_name = type_token.value
        arg_type = self:parse_type(type_name)

        if arg_type == "RESOURCE" or arg_type == "ENTITY" then
            error("The argument '" .. arg_name .. "' can't have '" .. type_name .. "' as its type")
        end

        table.insert(arguments, Argument(arg_name, arg_type, type_name))
    end

    return arguments
end

function Parser:parse_helper_fn(i)
    local fn_name_token = self:consume(i)
    local fn = HelperFn(fn_name_token.value)

    if not self.called_helper_fn_names[fn.fn_name] then
        error(fn.fn_name .. "() is defined before the first time it gets called")
    end

    self:consume_type(i, "OPEN_PARENTHESIS_TOKEN")

    local token = self:peek(i[1])
    if token.type == "WORD_TOKEN" then
        fn.arguments = self:parse_arguments(i)
    end

    self:consume_type(i, "CLOSE_PARENTHESIS_TOKEN")
    self:assert_type(i[1], "SPACE_TOKEN")
    
    token = self:peek(i[1] + 1)
    if token.type == "WORD_TOKEN" then
        i[1] = i[1] + 2
        fn.return_type = self:parse_type(token.value)
        fn.return_type_name = token.value

        if fn.return_type == "RESOURCE" or fn.return_type == "ENTITY" then
            error("The function '" .. fn.fn_name .. "' can't have '" .. fn.return_type_name .. "' as its return type")
        end
    end

    self.indentation = 0
    fn.body_statements = self:parse_statements(i)

    local is_empty = true
    for _, s in ipairs(fn.body_statements) do
        if s.stmt_type ~= "EmptyLineStatement" and s.stmt_type ~= "CommentStatement" then
            is_empty = false
            break
        end
    end
    if is_empty then error(fn.fn_name .. "() can't be empty") end

    table.insert(self.ast, fn)
    return fn
end

function Parser:parse_on_fn(i)
    local fn_token = self:consume(i)
    local fn = OnFn(fn_token.value)

    self:consume_type(i, "OPEN_PARENTHESIS_TOKEN")
    local next_tok = self:peek(i[1])
    if next_tok.type == "WORD_TOKEN" then
        fn.arguments = self:parse_arguments(i)
    end
    self:consume_type(i, "CLOSE_PARENTHESIS_TOKEN")

    fn.body_statements = self:parse_statements(i)
    
    local is_empty = true
    for _, s in ipairs(fn.body_statements) do
        if s.stmt_type ~= "EmptyLineStatement" and s.stmt_type ~= "CommentStatement" then
            is_empty = false
            break
        end
    end
    if is_empty then error(fn.fn_name .. "() can't be empty") end

    table.insert(self.ast, fn)
    return fn
end

function Parser:parse_statements(i)
    local stmts = {}

    self:increase_parsing_depth()
    self:consume_space(i)
    self:consume_type(i, "OPEN_BRACE_TOKEN")
    self:consume_type(i, "NEWLINE_TOKEN")

    self.indentation = self.indentation + 1

    local seen_newline = false
    local newline_allowed = false

    while true do
        if self:is_end_of_block(i) then
            break
        end

        local tok = self:peek(i[1])
        if tok.type == "NEWLINE_TOKEN" then
            if not newline_allowed then
                error("Unexpected empty line, on line " .. self:get_token_line_number(i[1]))
            end
            i[1] = i[1] + 1
            seen_newline = true
            newline_allowed = false
            table.insert(stmts, EmptyLineStatement())
        else
            newline_allowed = true
            self:consume_indentation(i)

            local stmt = self:parse_statement(i)
            table.insert(stmts, stmt)

            self:consume_type(i, "NEWLINE_TOKEN")
        end
    end

    if seen_newline and not newline_allowed then
        error("Unexpected empty line, on line " .. self:get_token_line_number(i[1] - 1))
    end

    self.indentation = self.indentation - 1

    if self.indentation > 0 then
        self:consume_indentation(i)
    end

    self:consume_type(i, "CLOSE_BRACE_TOKEN")
    self:decrease_parsing_depth()

    return stmts
end

function Parser:parse_statement(i)
    self:increase_parsing_depth()
    local switch_token = self:peek(i[1])
    local statement

    if switch_token.type == "WORD_TOKEN" then
        local token = self:peek(i[1] + 1)
        if token.type == "OPEN_PARENTHESIS_TOKEN" then
            local expr = self:parse_call(i)
            statement = CallStatement(expr)
        elseif token.type == "COLON_TOKEN" or token.type == "SPACE_TOKEN" then
            statement = self:parse_local_variable(i)
        else
            error("Expected '(', or ':', or ' =' after the word '" .. switch_token.value .. "' on line " .. self:get_token_line_number(i[1]))
        end
    elseif switch_token.type == "IF_TOKEN" then
        i[1] = i[1] + 1
        statement = self:parse_if_statement(i)
    elseif switch_token.type == "RETURN_TOKEN" then
        i[1] = i[1] + 1
        local token = self:peek(i[1])
        if token.type == "NEWLINE_TOKEN" then
            statement = ReturnStatement()
        else
            self:consume_space(i)
            local expr = self:parse_expression(i)
            statement = ReturnStatement(expr)
        end
    elseif switch_token.type == "WHILE_TOKEN" then
        i[1] = i[1] + 1
        statement = self:parse_while_statement(i)
    elseif switch_token.type == "BREAK_TOKEN" then
        if self.loop_depth == 0 then
            error("There is a break statement that isn't inside of a while loop")
        end
        i[1] = i[1] + 1
        statement = BreakStatement()
    elseif switch_token.type == "CONTINUE_TOKEN" then
        if self.loop_depth == 0 then
            error("There is a continue statement that isn't inside of a while loop")
        end
        i[1] = i[1] + 1
        statement = ContinueStatement()
    elseif switch_token.type == "NEWLINE_TOKEN" then
        i[1] = i[1] + 1
        statement = EmptyLineStatement()
    elseif switch_token.type == "COMMENT_TOKEN" then
        i[1] = i[1] + 1
        statement = CommentStatement(switch_token.value)
    else
        error("Expected a statement token, but got token type " .. switch_token.type .. " on line " .. self:get_token_line_number(i[1]))
    end

    self:decrease_parsing_depth()
    return statement
end

function Parser:parse_local_variable(i)
    local name_token_index = i[1]
    local var_token = self:consume(i)
    local var_name = var_token.value

    local var_type = nil
    local var_type_name = nil

    if self:peek(i[1]).type == "COLON_TOKEN" then
        i[1] = i[1] + 1

        if var_name == "me" then
            error("The local variable 'me' has to have its name changed to something else, since grug already declares that variable")
        end

        self:consume_space(i)
        self:assert_type(i[1], "WORD_TOKEN")
        local type_token = self:consume(i)

        var_type_name = type_token.value
        var_type = self:parse_type(var_type_name)

        if var_type == "RESOURCE" or var_type == "ENTITY" then
            error("The variable '" .. var_name .. "' can't have '" .. var_type_name .. "' as its type")
        end
    end

    if self:peek(i[1]).type ~= "SPACE_TOKEN" then
        error("The variable '" .. var_name .. "' was not assigned a value on line " .. self:get_token_line_number(name_token_index))
    end

    self:consume_space(i)
    self:consume_type(i, "ASSIGNMENT_TOKEN")

    if var_name == "me" then
        error("Assigning a new value to the entity's 'me' variable is not allowed")
    end

    self:consume_space(i)
    local expr = self:parse_expression(i)

    return VariableStatement(var_name, var_type, var_type_name, expr)
end

function Parser:parse_global_variable(i)
    local name_token_index = i[1]
    local name_token = self:consume(i)
    local global_name = name_token.value

    if global_name == "me" then
        error("The global variable 'me' has to have its name changed to something else, since grug already declares that variable")
    end

    self:consume_type(i, "COLON_TOKEN")
    self:consume_space(i)

    self:assert_type(i[1], "WORD_TOKEN")
    local type_token = self:consume(i)

    local global_type_name = type_token.value
    local global_type = self:parse_type(global_type_name)

    if global_type == "RESOURCE" or global_type == "ENTITY" then
        error("The global variable '" .. global_name .. "' can't have '" .. global_type_name .. "' as its type")
    end

    if self:peek(i[1]).type ~= "SPACE_TOKEN" then
        error("The global variable '" .. global_name .. "' was not assigned a value on line " .. self:get_token_line_number(name_token_index))
    end

    self:consume_space(i)
    self:consume_type(i, "ASSIGNMENT_TOKEN")
    self:consume_space(i)
    local expr = self:parse_expression(i)

    return VariableStatement(global_name, global_type, global_type_name, expr)
end

function Parser:parse_if_statement(i)
    self:increase_parsing_depth()
    self:consume_space(i)
    local condition = self:parse_expression(i)
    local if_body = self:parse_statements(i)

    local else_body = {}
    local tok = self:peek(i[1])
    if tok and tok.type == "SPACE_TOKEN" then
        i[1] = i[1] + 1
        self:consume_type(i, "ELSE_TOKEN")

        if self:peek(i[1]).type == "SPACE_TOKEN" and self:peek(i[1] + 1).type == "IF_TOKEN" then
            i[1] = i[1] + 2
            else_body = { self:parse_if_statement(i) }
        else
            else_body = self:parse_statements(i)
        end
    end

    self:decrease_parsing_depth()
    return IfStatement(condition, if_body, else_body)
end

function Parser:parse_while_statement(i)
    self:increase_parsing_depth()
    self:consume_space(i)
    local condition = self:parse_expression(i)

    self.loop_depth = self.loop_depth + 1
    local body = self:parse_statements(i)
    self.loop_depth = self.loop_depth - 1

    self:decrease_parsing_depth()
    return WhileStatement(condition, body)
end

function Parser:str_to_number(s)
    local f = tonumber(s)

    if not f or f ~= f or math.abs(f) > MAX_F64 then
        error("The number " .. s .. " is too big")
    end

    if f ~= 0 and math.abs(f) < MIN_F64 then
        error("The number " .. s .. " is too close to zero")
    end

    if f == 0 then
        if s:find("[123456789]") then
            error("The number " .. s .. " is too close to zero")
        end
    end

    return f
end

-- PRIMARY
function Parser:parse_primary(i)
    self:increase_parsing_depth()
    local t = self:peek(i[1])
    local expr

    if t.type == "OPEN_PARENTHESIS_TOKEN" then
        i[1] = i[1] + 1
        expr = ParenthesizedExpr(self:parse_expression(i))
        self:consume_type(i, "CLOSE_PARENTHESIS_TOKEN")
    elseif t.type == "TRUE_TOKEN" then
        i[1] = i[1] + 1
        expr = TrueExpr()
    elseif t.type == "FALSE_TOKEN" then
        i[1] = i[1] + 1
        expr = FalseExpr()
    elseif t.type == "STRING_TOKEN" then
        i[1] = i[1] + 1
        expr = StringExpr(t.value)
    elseif t.type == "ENTITY_TOKEN" then
        i[1] = i[1] + 1
        expr = EntityExpr(t.value)
    elseif t.type == "RESOURCE_TOKEN" then
        i[1] = i[1] + 1
        expr = ResourceExpr(t.value)
    elseif t.type == "WORD_TOKEN" then
        i[1] = i[1] + 1
        expr = IdentifierExpr(t.value)
    elseif t.type == "NUMBER_TOKEN" then
        i[1] = i[1] + 1
        expr = NumberExpr(self:str_to_number(t.value), t.value)
    else
        error("Expected a primary expression token, but got token type " .. t.type .. " on line " .. self:get_token_line_number(i[1]))
    end

    self:decrease_parsing_depth()
    return expr
end

-- CALL
function Parser:parse_call(i)
    self:increase_parsing_depth()
    local expr = self:parse_primary(i)
    local t = self:peek(i[1])

    if t.type ~= "OPEN_PARENTHESIS_TOKEN" then
        self:decrease_parsing_depth()
        return expr
    end

    if expr.name == nil then
        error("Unexpected '(' after non-identifier at line " .. self:get_token_line_number(i[1]))
    end

    local fn_name = expr.name
    local call = CallExpr(fn_name)

    if string.sub(fn_name, 1, 7) == "helper_" then
        self.called_helper_fn_names[fn_name] = true
    end

    i[1] = i[1] + 1

    if self:peek(i[1]).type == "CLOSE_PARENTHESIS_TOKEN" then
        i[1] = i[1] + 1
        self:decrease_parsing_depth()
        return call
    end

    while true do
        table.insert(call.arguments, self:parse_expression(i))

        local tok = self:peek(i[1])
        if tok.type ~= "COMMA_TOKEN" then
            self:consume_type(i, "CLOSE_PARENTHESIS_TOKEN")
            break
        end

        i[1] = i[1] + 1
        self:consume_space(i)
    end

    self:decrease_parsing_depth()
    return call
end

-- UNARY
function Parser:parse_unary(i)
    self:increase_parsing_depth()
    local t = self:peek(i[1])

    if t.type == "MINUS_TOKEN" or t.type == "NOT_TOKEN" then
        i[1] = i[1] + 1
        if t.type == "NOT_TOKEN" then
            self:consume_space(i)
        end
        local expr = UnaryExpr(t.type, self:parse_unary(i))
        self:decrease_parsing_depth()
        return expr
    end

    self:decrease_parsing_depth()
    return self:parse_call(i)
end

-- binary helpers
local function make_binary(self, i, next_fn, ops, ctor)
    local expr = next_fn(self, i)

    while true do
        local t = i[1] <= #self.tokens and self:peek(i[1]) or nil

        if t and t.type == "SPACE_TOKEN" then
            local t2 = i[1] + 1 <= #self.tokens and self:peek(i[1] + 1) or nil
            if t2 and ops[t2.type] then
                i[1] = i[1] + 1
                local op = self:consume(i).type
                self:consume_space(i)
                local right = next_fn(self, i)
                expr = ctor(expr, op, right)
            else
                break
            end
        else
            break
        end
    end

    return expr
end

function Parser:parse_factor(i)
    return make_binary(self, i, Parser.parse_unary, {
        MULTIPLICATION_TOKEN = true,
        DIVISION_TOKEN = true
    }, BinaryExpr)
end

function Parser:parse_term(i)
    return make_binary(self, i, Parser.parse_factor, {
        PLUS_TOKEN = true,
        MINUS_TOKEN = true
    }, BinaryExpr)
end

function Parser:parse_comparison(i)
    return make_binary(self, i, Parser.parse_term, {
        GREATER_TOKEN = true,
        GREATER_OR_EQUAL_TOKEN = true,
        LESS_TOKEN = true,
        LESS_OR_EQUAL_TOKEN = true
    }, BinaryExpr)
end

function Parser:parse_equality(i)
    return make_binary(self, i, Parser.parse_comparison, {
        EQUALS_TOKEN = true,
        NOT_EQUALS_TOKEN = true
    }, BinaryExpr)
end

function Parser:parse_and(i)
    return make_binary(self, i, Parser.parse_equality, {
        AND_TOKEN = true
    }, LogicalExpr)
end

function Parser:parse_or(i)
    return make_binary(self, i, Parser.parse_and, {
        OR_TOKEN = true
    }, LogicalExpr)
end

function Parser:parse_expression(i)
    self:increase_parsing_depth()
    local expr = self:parse_or(i)
    self:decrease_parsing_depth()
    return expr
end

-- BEGIN 04_type_propagator.lua
-- Data Structures
local function Variable(name, t, tname)
    return { name = name, type = t, type_name = tname }
end

local function Argument(name, t, tname, resource_extension, entity_type)
    return {
        name = name,
        type = t,
        type_name = tname,
        resource_extension = resource_extension,
        entity_type = entity_type
    }
end

local function GameFn(fn_name, arguments, return_type, return_type_name)
    return {
        fn_name = fn_name,
        arguments = arguments or {},
        return_type = return_type,
        return_type_name = return_type_name
    }
end

-- Helpers
local function parse_type(type_str)
    if not type_str then return nil end
    if type_str == "bool" then return "BOOL" end
    if type_str == "number" then return "NUMBER" end
    if type_str == "string" then return "STRING" end
    if type_str == "resource" then return "RESOURCE" end
    if type_str == "entity" then return "ENTITY" end
    return "ID"
end

local function parse_args(lst)
    local args = {}
    for _, obj in ipairs(lst or {}) do
        table.insert(args, Argument(
            obj.name,
            parse_type(obj.type),
            obj.type,
            obj.resource_extension,
            obj.entity_type
        ))
    end
    return args
end

local function parse_game_fn(fn_name, fn)
    return GameFn(
        fn_name,
        parse_args(fn.arguments),
        fn.return_type and parse_type(fn.return_type) or nil,
        fn.return_type
    )
end

-- TypePropagator Class
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
        entity_on_functions = {}
    }, TypePropagator)

    -- Extract on_fns and helper_fns from AST
    for _, s in ipairs(ast) do
        if s.stmt_type == "OnFn" then
            self.on_fns[s.fn_name] = s
        elseif s.stmt_type == "HelperFn" then
            self.helper_fns[s.fn_name] = s
        end
    end

    -- Parse game_functions from mod_api
    if mod_api.game_functions then
        for fn_name, fn in pairs(mod_api.game_functions) do
            self.game_functions[fn_name] = parse_game_fn(fn_name, fn)
        end
    end

    -- Load entity on_functions
    if mod_api.entities and mod_api.entities[entity_type] and mod_api.entities[entity_type].on_functions then
        self.entity_on_functions = mod_api.entities[entity_type].on_functions
    end

    return self
end

function TypePropagator:add_global_variable(name, var_type, type_name)
    if self.global_variables[name] then
        error("The global variable '" .. name .. "' shadows an earlier global variable")
    end
    self.global_variables[name] = Variable(name, var_type, type_name)
end

function TypePropagator:get_variable(name)
    if self.local_variables[name] then
        return self.local_variables[name]
    end
    if self.global_variables[name] then
        return self.global_variables[name]
    end
    return nil
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

function TypePropagator:are_incompatible_types(first_type, first_type_name, second_type, second_type_name)
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

    local mod = self.mod
    local entity_name = str
    local colon_pos = string.find(str, ":")

    if colon_pos then
        if colon_pos == 1 then
            error("Entity '" .. str .. "' is missing a mod name")
        end

        mod = string.sub(str, 1, colon_pos - 1)
        entity_name = string.sub(str, colon_pos + 1)

        if entity_name == "" then
            error("Entity '" .. str .. "' specifies the mod name '" .. mod .. "', but it is missing an entity name after the ':'")
        end

        if mod == self.mod then
            error("Entity '" .. str .. "' its mod name '" .. mod .. "' is invalid, since the file it is in refers to its own mod; just change it to '" .. entity_name .. "'")
        end
    end

    for i = 1, #mod do
        local c = string.sub(mod, i, i)
        if not (string.match(c, "%l") or string.match(c, "%d") or c == "_" or c == "-") then
            error("Entity '" .. str .. "' its mod name contains the invalid character '" .. c .. "'")
        end
    end

    for i = 1, #entity_name do
        local c = string.sub(entity_name, i, i)
        if not (string.match(c, "%l") or string.match(c, "%d") or c == "_" or c == "-") then
            error("Entity '" .. str .. "' its entity name contains the invalid character '" .. c .. "'")
        end
    end
end

function TypePropagator:validate_resource_string(str, resource_extension)
    if not str or str == "" then
        error("Resources can't be empty strings")
    end
    if string.sub(str, 1, 1) == "/" then
        error("Remove the leading slash from the resource \"" .. str .. "\"")
    end
    if string.sub(str, -1) == "/" then
        error("Remove the trailing slash from the resource \"" .. str .. "\"")
    end
    if string.find(str, "\\", 1, true) then
        error("Replace the '\\' with '/' in the resource \"" .. str .. "\"")
    end
    if string.find(str, "//", 1, true) then
        error("Replace the '//' with '/' in the resource \"" .. str .. "\"")
    end

    local dot_index = string.find(str, "%.")
    if dot_index then
        if dot_index == 1 then
            if #str == 1 or string.sub(str, 2, 2) == "/" then
                error("Remove the '.' from the resource \"" .. str .. "\"")
            end
        elseif string.sub(str, dot_index - 1, dot_index - 1) == "/" then
            if dot_index + 1 > #str or string.sub(str, dot_index + 1, dot_index + 1) == "/" then
                error("Remove the '.' from the resource \"" .. str .. "\"")
            end
        end
    end

    local dotdot_index = string.find(str, "%.%.")
    if dotdot_index then
        if dotdot_index == 1 then
            if #str == 2 or string.sub(str, 3, 3) == "/" then
                error("Remove the '..' from the resource \"" .. str .. "\"")
            end
        elseif string.sub(str, dotdot_index - 1, dotdot_index - 1) == "/" then
            if dotdot_index + 2 > #str or string.sub(str, dotdot_index + 2, dotdot_index + 2) == "/" then
                error("Remove the '..' from the resource \"" .. str .. "\"")
            end
        end
    end

    if string.sub(str, -1) == "." then
        error("resource name \"" .. str .. "\" cannot end with .")
    end

    if resource_extension and string.sub(str, -#resource_extension) ~= resource_extension then
        error("The resource '" .. str .. "' was supposed to have the extension '" .. resource_extension .. "'")
    end
end

function TypePropagator:check_arguments(params, call_expr)
    local fn_name = call_expr.fn_name
    local args = call_expr.arguments

    if #args < #params then
        error("Function call '" .. fn_name .. "' expected the argument '" .. params[#args + 1].name .. "' with type " .. params[#args + 1].type_name)
    end

    if #args > #params then
        error("Function call '" .. fn_name .. "' got an unexpected extra argument with type " .. tostring(args[#params + 1].result.type_name))
    end

    for i = 1, #args do
        local arg = args[i]
        local param = params[i]
        
        local is_string = arg.string ~= nil and arg.result.type == "STRING"
        local is_entity = arg.string ~= nil and arg.result.type == "ENTITY"
        local is_resource = arg.string ~= nil and arg.result.type == "RESOURCE"

        if is_string and param.type == "ENTITY" then
            error("The host function '" .. fn_name .. "' expects an entity string, so put an 'e' in front of string \"" .. arg.string .. "\"")
        elseif is_string and param.type == "RESOURCE" then
            error("The host function '" .. fn_name .. "' expects a resource string, so put an 'r' in front of string \"" .. arg.string .. "\"")
        end

        if is_entity then
            self:validate_entity_string(arg.string)
        elseif is_resource then
            self:validate_resource_string(arg.string, param.resource_extension)
        end

        if not arg.result or not arg.result.type then
            error("Function call '" .. fn_name .. "' expected the type " .. param.type_name .. " for argument '" .. param.name .. "', but got a function call that doesn't return anything")
        end

        if self:are_incompatible_types(param.type, param.type_name, arg.result.type, arg.result.type_name) then
            error("Function call '" .. fn_name .. "' expected the type " .. param.type_name .. " for argument '" .. param.name .. "', but got " .. arg.result.type_name)
        end
    end
end

function TypePropagator:fill_call_expr(expr)
    for _, arg in ipairs(expr.arguments) do
        self:fill_expr(arg)
    end

    local fn_name = expr.fn_name

    if self.helper_fns[fn_name] then
        local helper_fn = self.helper_fns[fn_name]
        expr.result = expr.result or {}
        expr.result.type = helper_fn.return_type
        expr.result.type_name = helper_fn.return_type_name
        self:check_arguments(helper_fn.arguments, expr)
        return
    end

    if self.game_functions[fn_name] then
        local game_fn = self.game_functions[fn_name]
        expr.result = expr.result or {}
        expr.result.type = game_fn.return_type
        expr.result.type_name = game_fn.return_type_name
        self:check_arguments(game_fn.arguments, expr)
        return
    end

    if string.sub(fn_name, 1, 3) == "on_" then
        error("Mods aren't allowed to call their own on_ functions, but '" .. fn_name .. "' was called")
    end

    if string.sub(fn_name, 1, 7) == "helper_" then
        error("The helper function '" .. fn_name .. "' was not defined by this grug file")
    end

    error("The game function '" .. fn_name .. "' was not declared by mod_api.json")
end

function TypePropagator:fill_binary_expr(expr)
    local left = expr.left_expr
    local right = expr.right_expr

    self:fill_expr(left)
    self:fill_expr(right)

    local op = expr.operator

    if left.result.type == "STRING" then
        if op ~= "EQUALS_TOKEN" and op ~= "NOT_EQUALS_TOKEN" then
            error("You can't use the " .. op .. " operator on a string")
        end
    end

    local is_id = (left.result.type_name == "id" or right.result.type_name == "id")
    if not is_id and left.result.type_name ~= right.result.type_name then
        error("The left and right operand of a binary expression ('" .. op .. "') must have the same type, but got " .. tostring(left.result.type_name) .. " and " .. tostring(right.result.type_name))
    end

    expr.result = expr.result or {}

    if op == "EQUALS_TOKEN" or op == "NOT_EQUALS_TOKEN" then
        expr.result.type = "BOOL"
        expr.result.type_name = "bool"
    elseif op == "GREATER_OR_EQUAL_TOKEN" or op == "GREATER_TOKEN" or op == "LESS_OR_EQUAL_TOKEN" or op == "LESS_TOKEN" then
        if left.result.type ~= "NUMBER" then
            error("'" .. op .. "' operator expects number")
        end
        expr.result.type = "BOOL"
        expr.result.type_name = "bool"
    elseif op == "AND_TOKEN" or op == "OR_TOKEN" then
        if left.result.type ~= "BOOL" then
            error("'" .. op .. "' operator expects bool")
        end
        expr.result.type = "BOOL"
        expr.result.type_name = "bool"
    else
        if left.result.type ~= "NUMBER" then
            error("'" .. op .. "' operator expects number")
        end
        expr.result.type = left.result.type
        expr.result.type_name = left.result.type_name
    end
end

function TypePropagator:fill_expr(expr)
    -- Upgrade parser's string literal results into robust table results
    if type(expr.result) == "string" then
        local res_str = expr.result
        expr.result = { type_name = res_str, type = string.upper(res_str) }
        return
    end

    expr.result = expr.result or {}

    if expr.name and not expr.fn_name then
        local var = self:get_variable(expr.name)
        if not var then
            error("The variable '" .. expr.name .. "' does not exist")
        end
        expr.result.type = var.type
        expr.result.type_name = var.type_name
    elseif expr.operator and not expr.left_expr then
        local op = expr.operator
        local inner = expr.expr

        if inner.operator == op and not inner.left_expr then
            error("Found '" .. op .. "' directly next to another '" .. op .. "', which can be simplified by just removing both of them")
        end

        self:fill_expr(inner)
        expr.result.type = inner.result.type
        expr.result.type_name = inner.result.type_name

        if op == "NOT_TOKEN" then
            if expr.result.type ~= "BOOL" then
                error("Found 'not' before " .. tostring(expr.result.type_name) .. ", but it can only be put before a bool")
            end
        else
            if expr.result.type ~= "NUMBER" then
                error("Found '-' before " .. tostring(expr.result.type_name) .. ", but it can only be put before a number")
            end
        end
    elseif expr.operator and expr.left_expr then
        self:fill_binary_expr(expr)
    elseif expr.fn_name then
        self:fill_call_expr(expr)
    elseif expr.expr and not expr.operator then
        self:fill_expr(expr.expr)
        expr.result.type = expr.expr.result.type
        expr.result.type_name = expr.expr.result.type_name
    end
end

function TypePropagator:fill_variable_statement(stmt)
    self:fill_expr(stmt.expr)

    local var = self:get_variable(stmt.name)

    if stmt.type then
        if self:are_incompatible_types(stmt.type, stmt.type_name, stmt.expr.result.type, stmt.expr.result.type_name) then
            error("Can't assign " .. tostring(stmt.expr.result.type_name) .. " to '" .. stmt.name .. "', which has type " .. tostring(stmt.type_name))
        end
        self:add_local_variable(stmt.name, stmt.type, stmt.type_name)
    else
        if not var then
            error("Can't assign to the variable '" .. stmt.name .. "', since it does not exist")
        end

        if self.global_variables[stmt.name] and var.type == "ID" then
            error("Global id variables can't be reassigned")
        end

        if self:are_incompatible_types(var.type, var.type_name, stmt.expr.result.type, stmt.expr.result.type_name) then
            error("Can't assign " .. tostring(stmt.expr.result.type_name) .. " to '" .. var.name .. "', which has type " .. tostring(var.type_name))
        end
    end
end

function TypePropagator:remove_local_variables_in_statements(statements)
    for _, stmt in ipairs(statements) do
        if stmt.stmt_type == "VariableStatement" and stmt.type then
            self.local_variables[stmt.name] = nil
        end
    end
end

function TypePropagator:fill_statements(statements)
    for _, stmt in ipairs(statements) do
        if stmt.stmt_type == "VariableStatement" then
            self:fill_variable_statement(stmt)
        elseif stmt.stmt_type == "CallStatement" then
            self:fill_call_expr(stmt.expr)
        elseif stmt.stmt_type == "IfStatement" then
            self:fill_expr(stmt.condition)
            self:fill_statements(stmt.if_body)
            if stmt.else_body and #stmt.else_body > 0 then
                self:fill_statements(stmt.else_body)
            end
        elseif stmt.stmt_type == "ReturnStatement" then
            if stmt.value then
                self:fill_expr(stmt.value)

                if not self.fn_return_type then
                    error("Function '" .. tostring(self.filled_fn_name) .. "' wasn't supposed to return any value")
                end

                if self:are_incompatible_types(self.fn_return_type, self.fn_return_type_name, stmt.value.result.type, stmt.value.result.type_name) then
                    error("Function '" .. tostring(self.filled_fn_name) .. "' is supposed to return " .. tostring(self.fn_return_type_name) .. ", not " .. tostring(stmt.value.result.type_name))
                end
            elseif self.fn_return_type then
                error("Function '" .. tostring(self.filled_fn_name) .. "' is supposed to return a value of type " .. tostring(self.fn_return_type_name))
            end
        elseif stmt.stmt_type == "WhileStatement" then
            self:fill_expr(stmt.condition)
            self:fill_statements(stmt.body_statements)
        end
    end

    self:remove_local_variables_in_statements(statements)
end

function TypePropagator:add_argument_variables(arguments)
    self.local_variables = {}
    for _, arg in ipairs(arguments) do
        self:add_local_variable(arg.name, arg.type, arg.type_name)
    end
end

function TypePropagator:fill_helper_fns()
    for fn_name, fn in pairs(self.helper_fns) do
        self.fn_return_type = fn.return_type
        self.fn_return_type_name = fn.return_type_name
        self.filled_fn_name = fn_name

        self:add_argument_variables(fn.arguments)
        self:fill_statements(fn.body_statements)

        if fn.return_type then
            local last_stmt = fn.body_statements[#fn.body_statements]
            if not last_stmt or last_stmt.stmt_type ~= "ReturnStatement" then
                error("Function '" .. tostring(self.filled_fn_name) .. "' is supposed to return " .. tostring(self.fn_return_type_name) .. " as its last line")
            end
        end
    end
end

function TypePropagator:fill_on_fns()
    local expected_functions_map = {}
    for _, expected_fn in ipairs(self.entity_on_functions) do
        expected_functions_map[expected_fn.name] = expected_fn
    end

    for fn_name, _ in pairs(self.on_fns) do
        if not expected_functions_map[fn_name] then
            error("The function '" .. fn_name .. "' was not declared by entity '" .. self.file_entity_type .. "' in mod_api.json")
        end
    end

    local parser_on_fn_names = {}
    for _, s in ipairs(self.ast) do
        if s.stmt_type == "OnFn" then
            table.insert(parser_on_fn_names, s.fn_name)
        end
    end

    local function index_of(tbl, val)
        for i, v in ipairs(tbl) do
            if v == val then return i end
        end
        return -1
    end

    local previous_on_fn_index = 0

    for _, expected_fn in ipairs(self.entity_on_functions) do
        local expected_fn_name = expected_fn.name

        if self.on_fns[expected_fn_name] then
            local fn = self.on_fns[expected_fn_name]

            local current_parser_index = index_of(parser_on_fn_names, expected_fn_name)
            if previous_on_fn_index > current_parser_index then
                error("The function '" .. expected_fn_name .. "' needs to be moved before/after a different on_ function, according to the entity '" .. self.file_entity_type .. "' in mod_api.json")
            end
            previous_on_fn_index = current_parser_index

            self.fn_return_type = nil
            self.fn_return_type_name = nil
            self.filled_fn_name = expected_fn_name

            local params = expected_fn.arguments or {}

            if #fn.arguments ~= #params then
                if #fn.arguments < #params then
                    error("Function '" .. expected_fn_name .. "' expected the parameter '" .. params[#fn.arguments + 1].name .. "' with type " .. params[#fn.arguments + 1].type)
                else
                    error("Function '" .. expected_fn_name .. "' got an unexpected extra parameter '" .. fn.arguments[#params + 1].name .. "' with type " .. fn.arguments[#params + 1].type_name)
                end
            end

            for i = 1, #fn.arguments do
                local arg = fn.arguments[i]
                local param = params[i]

                if arg.name ~= param.name then
                    error("Function '" .. expected_fn_name .. "' its '" .. arg.name .. "' parameter was supposed to be named '" .. param.name .. "'")
                end

                if arg.type_name ~= param.type then
                    error("Function '" .. expected_fn_name .. "' its '" .. param.name .. "' parameter was supposed to have the type " .. param.type .. ", but got " .. arg.type_name)
                end
            end

            self:add_argument_variables(fn.arguments)
            self:fill_statements(fn.body_statements)
        end
    end
end

function TypePropagator:check_global_expr(expr, name)
    if expr.operator and not expr.left_expr then
        self:check_global_expr(expr.expr, name)
    elseif expr.operator and expr.left_expr then
        self:check_global_expr(expr.left_expr, name)
        self:check_global_expr(expr.right_expr, name)
    elseif expr.fn_name then
        if string.sub(expr.fn_name, 1, 7) == "helper_" then
            error("The global variable '" .. name .. "' isn't allowed to call helper functions")
        end
        for _, arg in ipairs(expr.arguments) do
            self:check_global_expr(arg, name)
        end
    elseif expr.expr and not expr.operator then
        self:check_global_expr(expr.expr, name)
    end
end

function TypePropagator:fill_global_variables()
    self:add_global_variable("me", "ID", self.file_entity_type)

    for _, stmt in ipairs(self.ast) do
        if stmt.stmt_type == "VariableStatement" then
            self:check_global_expr(stmt.expr, stmt.name)
            self:fill_expr(stmt.expr)

            if stmt.expr.name and not stmt.expr.fn_name then
                if stmt.expr.name == "me" then
                    error("Global variables can't be assigned 'me'")
                end
            end

            if self:are_incompatible_types(stmt.type, stmt.type_name, stmt.expr.result.type, stmt.expr.result.type_name) then
                error("Can't assign " .. tostring(stmt.expr.result.type_name) .. " to '" .. stmt.name .. "', which has type " .. tostring(stmt.type_name))
            end

            self:add_global_variable(stmt.name, stmt.type, stmt.type_name)
        end
    end
end

function TypePropagator:fill()
    self:fill_global_variables()
    self:fill_on_fns()
    self:fill_helper_fns()
end

-- BEGIN 05_init.lua
local grug = {}
grug.__index = grug

local function read(path)
    local file = assert(io.open(path, "r"))
    local data, err = file:read("*all")
    file:close()
    assert(data, err)
    return data
end

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

local function check_custom_id_is_pascal(type_name)
    -- Validate that a custom ID type name is in PascalCase

    if type_name == nil or type_name == "" then
        error("type_name is empty")
    end

    local first_char = type_name:sub(1, 1)

    if first_char:match("%l") then
        error("'" .. type_name .. "' seems like a custom ID type, but it doesn't start in Uppercase")
    end

    for i = 1, #type_name do
        local c = type_name:sub(i, i)
        if not c:match("%a") and not c:match("%d") then
            error("'" .. type_name .. "' seems like a custom ID type, but it contains '" .. c .. "', which isn't uppercase/lowercase/a digit")
        end
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

function grug:compile_grug_file(grug_file_relative_path)
    local grug_file_absolute_path = self.mods_dir_path .. '/' .. grug_file_relative_path

    local text = read(grug_file_absolute_path)

    local tokens = tokenize(text)

    local ast = Parser.new(tokens):parse()

    local mod = grug_file_relative_path:match("([^/]+)")

    local filename = grug_file_relative_path:match("([^/]+)$")
    local entity_type = get_file_entity_type(filename)

    TypePropagator.new(ast, mod, entity_type, self.mod_api):fill()
end

local function assert_on_functions_sorted(entity_name, on_functions)
    local keys = {}
    for _, fn in ipairs(on_functions) do
        table.insert(keys, fn.name)
    end

    local sorted_keys = {}
    for _, k in ipairs(keys) do
        table.insert(sorted_keys, k)
    end
    table.sort(sorted_keys)

    for i, actual in ipairs(keys) do
        local expected = sorted_keys[i]
        if actual ~= expected then
            error(string.format(
                "Error: on_functions for entity '%s' must be sorted alphabetically in mod_api.json, " ..
                "so '%s' must come before '%s'",
                entity_name, expected, actual
            ))
        end
    end
end

local function assert_mod_api(mod_api)
    local entities = mod_api.entities
    if type(entities) ~= "table" then
        error("Error: 'entities' must be a JSON object")
    end

    for entity_name, entity in pairs(entities) do
        if type(entity) ~= "table" then
            error(string.format("Error: entity '%s' must be a JSON object", entity_name))
        end

        local on_functions = entity.on_functions
        if on_functions == nil then
            goto continue
        end

        if type(on_functions) ~= "table" then
            error(string.format(
                "Error: 'on_functions' for entity '%s' must be a JSON array",
                entity_name
            ))
        end

        assert_on_functions_sorted(entity_name, on_functions)

        ::continue::
    end

    local game_functions = mod_api.game_functions
    if type(game_functions) ~= "table" then
        error("Error: 'game_functions' must be a JSON object")
    end
end

function grug.init(settings)
    local runtime_error_handler = settings.runtime_error_handler or default_runtime_error_handler
    local mod_api_path = settings.mod_api_path or "mod_api.json"
    local mods_dir_path = settings.mods_dir_path or "mods"
    local on_fn_time_limit_ms = settings.on_fn_time_limit_ms or 100
    local packages = settings.packages or {}

    local mod_api_text = read(mod_api_path)
    local mod_api = json.decode(mod_api_text)

    if type(mod_api) ~= "table" then
        error("Error: mod API JSON root must be an object")
    end

    assert_mod_api(mod_api)

    if type(mod_api) ~= "table" then
        return nil
    end

    if type(mod_api.entities) ~= "table" then
        return nil
    end
    for k, v in pairs(mod_api.entities) do
        if type(v) ~= "table" then
            return nil
        end
    end

    if type(mod_api.game_functions) ~= "table" then
        return nil
    end

    return setmetatable({
        runtime_error_handler = runtime_error_handler,
        mods_dir_path = mods_dir_path,
        on_fn_time_limit_ms = on_fn_time_limit_ms,
        mod_api = mod_api
    }, grug)
end

return grug
