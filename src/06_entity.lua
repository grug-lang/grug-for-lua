local Entity = {}

local MAX_DEPTH = 100

-- Control flow exception tokens used to mimic Python's exception-based control flow
local BREAK = { type = "BREAK" }
local CONTINUE = { type = "CONTINUE" }
local RETURN = { type = "RETURN" }

local unpack = unpack or table.unpack

function Entity.new(file)
    local self = setmetatable({
        me_id = file.state.next_id,
        file = file,
        state = file.state,
        game_fns = file.game_fns,
        game_fn_return_types = file.game_fn_return_types,
        on_fn_time_limit_sec = file.state.on_fn_time_limit_ms / 1000,
        local_variables = {},
        on_fn_depth = 0,
        global_variables = {},
        fn_name = "",
        start_time = 0,
    }, Entity)

    file.state.next_id = file.state.next_id + 1

    self:_init_globals(file.global_variables)

    return self
end

function Entity:_init_globals(global_variables)
    self.fn_name = "init_globals"
    self.global_variables["me"] = self.me_id

    local old_fn_depth = self.state.fn_depth
    self.state.fn_depth = self.state.fn_depth + 1

    self.start_time = os.clock()

    local success, err = pcall(function()
        for _, g in ipairs(global_variables) do
            self.global_variables[g.name] = self:_run_expr(g.expr)
        end
    end)

    self.state.fn_depth = old_fn_depth

    if not success then
        error(err)
    end
end

-- Python's __getattr__ dynamic method logic translated to Lua's __index.
-- This allows calling on_ functions defined in the .grug file (e.g., dog.spawn()).
function Entity:__index(key)
    local val = rawget(Entity, key)
    if val ~= nil then return val end

    return function(...)
        return self:_run_on_fn(key, ...)
    end
end

function Entity:_run_on_fn(on_fn_name, ...)
    local on_fn = self.file.on_fns[on_fn_name]
    if not on_fn then
        error("The function '" .. on_fn_name .. "' is not defined by the file " .. self.file.relative_path)
    end

    local args = {...}
    local parent_local_variables = self.local_variables
    self.local_variables = {}

    self.fn_name = on_fn_name

    -- Assign and verify argument types
    for i, argument in ipairs(on_fn.arguments) do
        local arg = args[i]
        local expected = self:_get_expected_type(argument.type_name)
        if type(arg) ~= expected then
            error(string.format("Argument '%s' of %s() must be %s, got %s",
                argument.name, on_fn_name, argument.type_name, type(arg)))
        end
        self.local_variables[argument.name] = arg
    end

    local old_fn_depth = self.state.fn_depth
    self.state.fn_depth = self.state.fn_depth + 1

    local old_on_fn_depth = self.on_fn_depth
    self.on_fn_depth = self.on_fn_depth + 1
    if self.on_fn_depth == 1 then
        self.start_time = os.clock()
    end

    local status, err = pcall(function()
        self:_run_statements(on_fn.body_statements)
    end)

    if not status then
        if type(err) == "table" and err.type == "RETURN" then
            -- On-functions do not return values to the host in Grug
        elseif type(err) == "table" and (err.type == "STACK_OVERFLOW" or err.type == "TIME_LIMIT_EXCEEDED" or err.type == "RERAISED_GAME_FN_ERROR") then
            if self.state.fn_depth > 1 then
                self.state.fn_depth = old_fn_depth
                self.on_fn_depth = old_on_fn_depth
                self.local_variables = parent_local_variables
                error(err)
            end
        else
            self.state.fn_depth = old_fn_depth
            self.on_fn_depth = old_on_fn_depth
            self.local_variables = parent_local_variables
            error(err)
        end
    end

    self.state.fn_depth = old_fn_depth
    self.on_fn_depth = old_on_fn_depth
    self.local_variables = parent_local_variables
end

function Entity:_get_expected_type(type_name)
    if type_name == "number" then return "number" end
    if type_name == "bool" then return "boolean" end
    if type_name == "string" or type_name == "resource" or type_name == "entity" then
        return "string"
    end
    return "userdata"
end

function Entity:_run_statements(statements)
    for _, statement in ipairs(statements) do
        self:_run_statement(statement)
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
        error(BREAK)
    elseif t == "ContinueStatement" then
        error(CONTINUE)
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
    if expr.bool_val ~= nil then
        return expr.bool_val
    elseif expr.value ~= nil then
        return expr.value
    elseif expr.string ~= nil then
        if expr.result == "string" then
            return expr.string
        elseif expr.result == "resource" then
            return self.file.mod .. "/" .. expr.string
        elseif expr.result == "entity" then
            if string.find(expr.string, ":") then
                return expr.string
            else
                return self.file.mod .. ":" .. expr.string
            end
        end
    elseif expr.name ~= nil then
        if self.global_variables[expr.name] ~= nil then
            return self.global_variables[expr.name]
        end
        return self.local_variables[expr.name]
    elseif expr.operator ~= nil then
        if expr.left_expr ~= nil then
            if expr.operator == "AND_TOKEN" or expr.operator == "OR_TOKEN" then
                return self:_run_logical_expr(expr)
            else
                return self:_run_binary_expr(expr)
            end
        else
            return self:_run_unary_expr(expr)
        end
    elseif expr.fn_name ~= nil then
        local val = self:_run_call_expr(expr)
        assert(val ~= nil)
        return val
    elseif expr.expr ~= nil then
        return self:_run_expr(expr.expr)
    end
end

function Entity:_run_unary_expr(unary_expr)
    local op = unary_expr.operator
    local val = self:_run_expr(unary_expr.expr)
    if op == "MINUS_TOKEN" then
        return -val
    elseif op == "NOT_TOKEN" then
        return not val
    end
end

function Entity:_run_binary_expr(binary_expr)
    local left = self:_run_expr(binary_expr.left_expr)
    local right = self:_run_expr(binary_expr.right_expr)
    local op = binary_expr.operator

    if op == "PLUS_TOKEN" then return left + right
    elseif op == "MINUS_TOKEN" then return left - right
    elseif op == "MULTIPLICATION_TOKEN" then return left * right
    elseif op == "DIVISION_TOKEN" then return left / right
    elseif op == "EQUALS_TOKEN" then return left == right
    elseif op == "NOT_EQUALS_TOKEN" then return left ~= right
    elseif op == "GREATER_OR_EQUAL_TOKEN" then return left >= right
    elseif op == "GREATER_TOKEN" then return left > right
    elseif op == "LESS_OR_EQUAL_TOKEN" then return left <= right
    elseif op == "LESS_TOKEN" then return left < right
    end
end

function Entity:_run_logical_expr(logical_expr)
    local left = self:_run_expr(logical_expr.left_expr)
    if logical_expr.operator == "AND_TOKEN" then
        return left and self:_run_expr(logical_expr.right_expr)
    else
        return left or self:_run_expr(logical_expr.right_expr)
    end
end

function Entity:_run_call_expr(call_expr)
    local args = {}
    for _, arg in ipairs(call_expr.arguments) do
        table.insert(args, self:_run_expr(arg))
    end

    if string.sub(call_expr.fn_name, 1, 7) == "helper_" then
        return self:_run_helper_fn(call_expr.fn_name, unpack(args))
    else
        return self:_run_game_fn(call_expr.fn_name, unpack(args))
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
        error({ type = "RETURN", value = self:_run_expr(statement.value) })
    end
    error(RETURN)
end

function Entity:_run_while_statement(statement)
    local success, err = pcall(function()
        while self:_run_expr(statement.condition) do
            local loop_success, loop_err = pcall(function()
                self:_run_statements(statement.body_statements)
            end)

            if not loop_success then
                if type(loop_err) == "table" and loop_err.type == "CONTINUE" then
                    -- Catch continue and proceed to check time limit / next iteration
                else
                    error(loop_err)
                end
            end
            self:_check_time_limit_exceeded()
        end
    end)

    if not success then
        if type(err) == "table" and err.type == "BREAK" then
            return
        end
        error(err)
    end
end

function Entity:_check_time_limit_exceeded()
    if os.clock() - self.start_time > self.on_fn_time_limit_sec then
        self.state.runtime_error_handler(
            string.format("Took longer than %g milliseconds to run", self.on_fn_time_limit_sec * 1000),
            "TIME_LIMIT_EXCEEDED",
            self.fn_name,
            self.file.relative_path
        )
        error({ type = "TIME_LIMIT_EXCEEDED" })
    end
end

function Entity:_run_helper_fn(name, ...)
    local helper_fn = self.file.helper_fns[name]
    local args = {...}
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
        error({ type = "STACK_OVERFLOW" })
    end

    self:_check_time_limit_exceeded()

    local result
    local status, err = pcall(function()
        self:_run_statements(helper_fn.body_statements)
    end)

    self.state.fn_depth = old_fn_depth
    self.local_variables = parent_local_variables

    if not status then
        if type(err) == "table" and err.type == "RETURN" then
            return err.value
        end
        error(err)
    end

    return result
end

function Entity:_run_game_fn(name, ...)
    local game_fn = self.game_fns[name]
    assert(game_fn)

    local args = {...}

    local parent_fn_name = self.fn_name
    local success, result = pcall(game_fn, self.state, unpack(args))

    if not success then
        self.state.runtime_error_handler(
            result,
            "GAME_FN_ERROR",
            parent_fn_name,
            self.file.relative_path
        )
        error({ type = "RERAISED_GAME_FN_ERROR" })
    end

    self.fn_name = parent_fn_name

    local t = self.game_fn_return_types[name]
    if t == nil then return end

    local expected = self:_get_expected_type(t)
    if type(result) ~= expected then
        error(string.format("Return value of game function %s() must be %s, got %s",
            name, expected, type(result)))
    end

    return result
end
