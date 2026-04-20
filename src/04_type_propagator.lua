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
