local MAX_PARSING_DEPTH = 100
local SPACES_PER_INDENT = 4
local MIN_F64 = 2.2250738585072014e-308
local MAX_F64 = 1.7976931348623157e308

-- AST Node Factories
local Nodes = {
    True = function() return { bool_val = true, result = "bool" } end,
    False = function() return { bool_val = false, result = "bool" } end,
    String = function(s) return { string = s, result = "string" } end,
    Resource = function(s) return { string = s, result = "resource" } end,
    Entity = function(s) return { string = s, result = "entity" } end,
    Identifier = function(name) return { name = name } end,
    Number = function(v, s) return { value = v, string = s, result = "number" } end,
    Unary = function(op, expr) return { operator = op, expr = expr } end,
    Binary = function(l, op, r) return { left_expr = l, operator = op, right_expr = r } end,
    Logical = function(l, op, r) return { left_expr = l, operator = op, right_expr = r } end,
    Call = function(name) return { fn_name = name, arguments = {} } end,
    Parenthesized = function(expr) return { expr = expr } end,
    Variable = function(name, t, tname, expr) return { stmt_type = "VariableStatement", name = name, type = t, type_name = tname, expr = expr } end,
    CallStmt = function(expr) return { stmt_type = "CallStatement", expr = expr } end,
    If = function(cond, ifb, elseb) return { stmt_type = "IfStatement", condition = cond, if_body = ifb, else_body = elseb } end,
    Return = function(val) return { stmt_type = "ReturnStatement", value = val } end,
    While = function(cond, body) return { stmt_type = "WhileStatement", condition = cond, body_statements = body } end,
    Break = function() return { stmt_type = "BreakStatement" } end,
    Continue = function() return { stmt_type = "ContinueStatement" } end,
    EmptyLine = function() return { stmt_type = "EmptyLineStatement" } end,
    Comment = function(s) return { stmt_type = "CommentStatement", string = s } end,
    Argument = function(name, t, tname) return { name = name, type = t, type_name = tname } end,
    OnFn = function(name) return { stmt_type = "OnFn", fn_name = name, arguments = {}, body_statements = {} } end,
    HelperFn = function(name) return { stmt_type = "HelperFn", fn_name = name, arguments = {}, body_statements = {} } end,
}

local TYPE_MAP = {
    bool = "BOOL",
    number = "NUMBER",
    string = "STRING",
    resource = "RESOURCE",
    entity = "ENTITY"
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
        called_helper_fn_names = {}
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
        error("Expected token type " .. expected .. ", but got " .. t.type .. " on line " .. self:get_token_line_number(self.idx))
    end
end

function Parser:consume_type(expected)
    self:assert_type(expected)
    return self:consume()
end

function Parser:consume_space()
    local tok = self:peek()
    if tok.type ~= "SPACE_TOKEN" then
        error("Expected token type SPACE_TOKEN, but got " .. tok.type .. " on line " .. self:get_token_line_number(self.idx))
    end
    self.idx = self.idx + 1
end

function Parser:consume_indentation()
    self:assert_type("INDENTATION_TOKEN")
    local spaces = #self:peek().value
    local expected = self.indentation * SPACES_PER_INDENT
    if spaces ~= expected then
        error("Expected " .. expected .. " spaces, but got " .. spaces .. " spaces on line " .. self:get_token_line_number(self.idx))
    end
    self.idx = self.idx + 1
end

function Parser:is_end_of_block()
    local tok = self:peek()
    if tok.type == "CLOSE_BRACE_TOKEN" then return true end
    if tok.type == "NEWLINE_TOKEN" then return false end
    if tok.type == "INDENTATION_TOKEN" then
        return #tok.value == (self.indentation - 1) * SPACES_PER_INDENT
    end
    error("Expected indentation, newline, or '}', but got '" .. tostring(tok.value) .. "' on line " .. self:get_token_line_number(self.idx))
end

function Parser:depth_scope(fn, ...)
    self.parsing_depth = self.parsing_depth + 1
    if self.parsing_depth >= MAX_PARSING_DEPTH then
        error("There is a function that contains more than " .. MAX_PARSING_DEPTH .. " levels of nested expressions")
    end
    local res = fn(self, ...)
    self.parsing_depth = self.parsing_depth - 1
    return res
end

function Parser:get_type(type_str)
    return TYPE_MAP[type_str] or "ID"
end

function Parser:validate_fn_body(fn)
    local is_empty = true
    for _, s in ipairs(fn.body_statements) do
        if s.stmt_type ~= "EmptyLineStatement" and s.stmt_type ~= "CommentStatement" then
            is_empty = false
            break
        end
    end
    if is_empty then error(fn.fn_name .. "() can't be empty") end
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

        elseif token.type == "WORD_TOKEN" and token.value:sub(1, 3) == "on_" and next_token and next_token.type == "OPEN_PARENTHESIS_TOKEN" then
            if next(self.helper_fns) then error(token.value .. "() must be defined before all helper_ functions") end
            if newline_required then error("Expected an empty line, on line " .. self:get_token_line_number(self.idx)) end

            local fn = self:parse_on_fn()
            if self.on_fns[fn.fn_name] then error("The function '" .. fn.fn_name .. "' was defined several times in the same file") end
            self.on_fns[fn.fn_name] = fn
            self:consume_type("NEWLINE_TOKEN")
            seen_on_fn, newline_allowed, newline_required = true, true, true

        elseif token.type == "WORD_TOKEN" and token.value:sub(1, 7) == "helper_" and next_token and next_token.type == "OPEN_PARENTHESIS_TOKEN" then
            if newline_required then error("Expected an empty line, on line " .. self:get_token_line_number(self.idx)) end

            local fn = self:parse_helper_fn()
            if self.helper_fns[fn.fn_name] then error("The function '" .. fn.fn_name .. "' was defined several times in the same file") end
            self.helper_fns[fn.fn_name] = fn
            self:consume_type("NEWLINE_TOKEN")
            newline_allowed, newline_required = true, true

        elseif token.type == "NEWLINE_TOKEN" then
            if not newline_allowed then error("Unexpected empty line, on line " .. self:get_token_line_number(self.idx)) end
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
        local arg_type = self:get_type(type_name)

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
    if not self.called_helper_fn_names[name] then error(name .. "() is defined before the first time it gets called") end
    
    local fn = Nodes.HelperFn(name)
    self:consume_type("OPEN_PARENTHESIS_TOKEN")
    if self:peek().type == "WORD_TOKEN" then fn.arguments = self:parse_arguments() end
    self:consume_type("CLOSE_PARENTHESIS_TOKEN")

    if self:peek().type == "SPACE_TOKEN" then
        local next_t = self:peek(1)
        if next_t.type == "WORD_TOKEN" then
            self.idx = self.idx + 2
            fn.return_type = self:get_type(next_t.value)
            fn.return_type_name = next_t.value
            if fn.return_type == "RESOURCE" or fn.return_type == "ENTITY" then
                error("The function '" .. name .. "' can't have '" .. fn.return_type_name .. "' as its return type")
            end
        end
    end

    self.indentation = 0
    fn.body_statements = self:parse_statements()
    self:validate_fn_body(fn)
    table.insert(self.ast, fn)
    return fn
end

function Parser:parse_on_fn()
    local name = self:consume().value
    local fn = Nodes.OnFn(name)
    self:consume_type("OPEN_PARENTHESIS_TOKEN")
    if self:peek().type == "WORD_TOKEN" then fn.arguments = self:parse_arguments() end
    self:consume_type("CLOSE_PARENTHESIS_TOKEN")
    fn.body_statements = self:parse_statements()
    self:validate_fn_body(fn)
    table.insert(self.ast, fn)
    return fn
end

function Parser:parse_statements()
    return self:depth_scope(function()
        local stmts = {}
        self:consume_space()
        self:consume_type("OPEN_BRACE_TOKEN")
        self:consume_type("NEWLINE_TOKEN")
        self.indentation = self.indentation + 1

        local newline_allowed = false
        while not self:is_end_of_block() do
            local tok = self:peek()
            if tok.type == "NEWLINE_TOKEN" then
                if not newline_allowed then error("Unexpected empty line, on line " .. self:get_token_line_number(self.idx)) end
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
        if self.indentation > 0 then self:consume_indentation() end
        self:consume_type("CLOSE_BRACE_TOKEN")
        return stmts
    end)
end

function Parser:parse_statement()
    return self:depth_scope(function()
        local tok = self:peek()
        if tok.type == "WORD_TOKEN" then
            local next_t = self:peek(1)
            if next_t.type == "OPEN_PARENTHESIS_TOKEN" then return Nodes.CallStmt(self:parse_call()) end
            if next_t.type == "COLON_TOKEN" or next_t.type == "SPACE_TOKEN" then return self:parse_local_variable() end
            error("Expected '(', or ':', or ' =' after the word '" .. tok.value .. "' on line " .. self:get_token_line_number(self.idx))
        elseif tok.type == "IF_TOKEN" then
            self.idx = self.idx + 1
            return self:parse_if_statement()
        elseif tok.type == "RETURN_TOKEN" then
            self.idx = self.idx + 1
            if self:peek().type == "NEWLINE_TOKEN" then return Nodes.Return() end
            self:consume_space()
            return Nodes.Return(self:parse_expression())
        elseif tok.type == "WHILE_TOKEN" then
            self.idx = self.idx + 1
            return self:parse_while_statement()
        elseif tok.type == "BREAK_TOKEN" or tok.type == "CONTINUE_TOKEN" then
            if self.loop_depth == 0 then
                local word = tok.type == "BREAK_TOKEN" and "break" or "continue"
                error("There is a " .. word .. " statement that isn't inside of a while loop")
            end
            self.idx = self.idx + 1
            return tok.type == "BREAK_TOKEN" and Nodes.Break() or Nodes.Continue()
        elseif tok.type == "NEWLINE_TOKEN" then
            self.idx = self.idx + 1
            return Nodes.EmptyLine()
        elseif tok.type == "COMMENT_TOKEN" then
            self.idx = self.idx + 1
            return Nodes.Comment(tok.value)
        end
        error("Expected a statement token, but got token type " .. tok.type .. " on line " .. self:get_token_line_number(self.idx))
    end)
end

function Parser:parse_local_variable()
    local start_idx = self.idx
    local name = self:consume().value
    local v_type, v_tname

    if self:peek().type == "COLON_TOKEN" then
        self.idx = self.idx + 1
        if name == "me" then error("The local variable 'me' has to have its name changed to something else, since grug already declares that variable") end
        self:consume_space()
        self:assert_type("WORD_TOKEN")
        v_tname = self:consume().value
        v_type = self:get_type(v_tname)
        if v_type == "RESOURCE" or v_type == "ENTITY" then error("The variable '" .. name .. "' can't have '" .. v_tname .. "' as its type") end
    end

    if self:peek().type ~= "SPACE_TOKEN" then error("The variable '" .. name .. "' was not assigned a value on line " .. self:get_token_line_number(start_idx)) end
    self:consume_space()
    self:consume_type("ASSIGNMENT_TOKEN")
    if name == "me" then error("Assigning a new value to the entity's 'me' variable is not allowed") end
    self:consume_space()
    return Nodes.Variable(name, v_type, v_tname, self:parse_expression())
end

function Parser:parse_global_variable()
    local start_idx = self.idx
    local name = self:consume().value
    if name == "me" then error("The global variable 'me' has to have its name changed to something else, since grug already declares that variable") end
    
    self:consume_type("COLON_TOKEN")
    self:consume_space()
    self:assert_type("WORD_TOKEN")
    local t_token = self:consume()
    local t_name = t_token.value
    local g_type = self:get_type(t_name)

    if g_type == "RESOURCE" or g_type == "ENTITY" then error("The global variable '" .. name .. "' can't have '" .. t_name .. "' as its type") end
    if self:peek().type ~= "SPACE_TOKEN" then error("The global variable '" .. name .. "' was not assigned a value on line " .. self:get_token_line_number(start_idx)) end
    
    self:consume_space()
    self:consume_type("ASSIGNMENT_TOKEN")
    self:consume_space()
    return Nodes.Variable(name, g_type, t_name, self:parse_expression())
end

function Parser:parse_if_statement()
    return self:depth_scope(function()
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
        return Nodes.If(cond, if_body, else_body)
    end)
end

function Parser:parse_while_statement()
    return self:depth_scope(function()
        self:consume_space()
        local cond = self:parse_expression()
        self.loop_depth = self.loop_depth + 1
        local body = self:parse_statements()
        self.loop_depth = self.loop_depth - 1
        return Nodes.While(cond, body)
    end)
end

function Parser:str_to_number(s)
    local f = tonumber(s)
    if not f or f ~= f or math.abs(f) > MAX_F64 then error("The number " .. s .. " is too big") end
    if f ~= 0 and math.abs(f) < MIN_F64 then error("The number " .. s .. " is too close to zero") end
    if f == 0 and s:find("[123456789]") then error("The number " .. s .. " is too close to zero") end
    return f
end

function Parser:parse_primary()
    return self:depth_scope(function()
        local t = self:consume()
        if t.type == "OPEN_PARENTHESIS_TOKEN" then
            local expr = Nodes.Parenthesized(self:parse_expression())
            self:consume_type("CLOSE_PARENTHESIS_TOKEN")
            return expr
        elseif t.type == "TRUE_TOKEN" then return Nodes.True()
        elseif t.type == "FALSE_TOKEN" then return Nodes.False()
        elseif t.type == "STRING_TOKEN" then return Nodes.String(t.value)
        elseif t.type == "ENTITY_TOKEN" then return Nodes.Entity(t.value)
        elseif t.type == "RESOURCE_TOKEN" then return Nodes.Resource(t.value)
        elseif t.type == "WORD_TOKEN" then return Nodes.Identifier(t.value)
        elseif t.type == "NUMBER_TOKEN" then return Nodes.Number(self:str_to_number(t.value), t.value)
        end
        error("Expected a primary expression token, but got token type " .. t.type .. " on line " .. self:get_token_line_number(self.idx - 1))
    end)
end

function Parser:parse_call()
    return self:depth_scope(function()
        local expr = self:parse_primary()
        if self:peek().type ~= "OPEN_PARENTHESIS_TOKEN" then return expr end
        if expr.name == nil then error("Unexpected '(' after non-identifier at line " .. self:get_token_line_number(self.idx)) end

        local fn_name = expr.name
        if fn_name:sub(1, 7) == "helper_" then self.called_helper_fn_names[fn_name] = true end
        
        local call = Nodes.Call(fn_name)
        self.idx = self.idx + 1
        if self:peek().type == "CLOSE_PARENTHESIS_TOKEN" then
            self.idx = self.idx + 1
            return call
        end

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
        return call
    end)
end

function Parser:parse_unary()
    return self:depth_scope(function()
        local t = self:peek()
        if t.type == "MINUS_TOKEN" or t.type == "NOT_TOKEN" then
            self.idx = self.idx + 1
            if t.type == "NOT_TOKEN" then self:consume_space() end
            return Nodes.Unary(t.type, self:parse_unary())
        end
        return self:parse_call()
    end)
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
                else break end
            else break end
        end
        return expr
    end
end

Parser.parse_factor = binary_op(Parser.parse_unary, { MULTIPLICATION_TOKEN = true, DIVISION_TOKEN = true }, Nodes.Binary)
Parser.parse_term = binary_op(Parser.parse_factor, { PLUS_TOKEN = true, MINUS_TOKEN = true }, Nodes.Binary)
Parser.parse_comparison = binary_op(Parser.parse_term, { GREATER_TOKEN = true, GREATER_OR_EQUAL_TOKEN = true, LESS_TOKEN = true, LESS_OR_EQUAL_TOKEN = true }, Nodes.Binary)
Parser.parse_equality = binary_op(Parser.parse_comparison, { EQUALS_TOKEN = true, NOT_EQUALS_TOKEN = true }, Nodes.Binary)
Parser.parse_and = binary_op(Parser.parse_equality, { AND_TOKEN = true }, Nodes.Logical)
Parser.parse_or = binary_op(Parser.parse_and, { OR_TOKEN = true }, Nodes.Logical)

function Parser:parse_expression()
    return self:depth_scope(self.parse_or)
end
