local MAX_PARSING_DEPTH = 100
local SPACES_PER_INDENT = 4

local MIN_F64 = 2.2250738585072014e-308
local MAX_F64 = 1.7976931348623157e308

-- Expressions
local function TrueExpr()
    return { bool_val = true, result = "bool" }
end

local function FalseExpr()
    return { bool_val = false, result = "bool" }
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

-- TODO: Get rid of this fn, as it was just in Python to map strings to enums
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
