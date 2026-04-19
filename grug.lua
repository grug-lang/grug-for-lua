local grug = {}

-- BEGIN 00_json.lua
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

-- BEGIN 01_tokenizer.lua
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

-- BEGIN 02_init.lua
local function read(path)
    local file = assert(io.open(path, "r"))
    local data, err = file:read("*all")
    file:close()
    assert(data, err)
    return data
end

local function compile_grug_file(self, grug_file_relative_path)
    local grug_file_absolute_path = self.mods_dir_path .. '/' .. grug_file_relative_path
    print('grug_file_absolute_path: ' .. grug_file_absolute_path)

    local text = read(grug_file_absolute_path)
    print('text: ' .. text)
end

function grug.init(settings)
    -- local runtime_error_handler = settings.runtime_error_handler or default_runtime_error_handler -- TODO: USE!
    local mod_api_path = settings.mod_api_path or "mod_api.json"
    local mods_dir_path = settings.mods_dir_path or "mods"
    -- local on_fn_time_limit_ms = settings.on_fn_time_limit_ms or 100 -- TODO: USE!
    -- local packages = settings.packages or {} -- TODO: USE!

    local mod_api_text = read(mod_api_path)
    local mod_api = json.decode(mod_api_text)

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

    return {
        mods_dir_path = mods_dir_path,
        compile_grug_file = compile_grug_file
    }
end

return grug
