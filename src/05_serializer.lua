local function serialize_expr(expr)
    local result = {}
    
    if expr.bool_val == true then
        result.type = "TRUE_EXPR"
    elseif expr.bool_val == false then
        result.type = "FALSE_EXPR"
    elseif expr.value ~= nil then
        result.type = "NUMBER_EXPR"
        result.value = expr.string
    elseif expr.string ~= nil then
        local res_type = (type(expr.result) == "table") and expr.result.type_name or expr.result
        if res_type == "string" then
            result.type = "STRING_EXPR"
        elseif res_type == "resource" then
            result.type = "RESOURCE_EXPR"
        elseif res_type == "entity" then
            result.type = "ENTITY_EXPR"
        else
            result.type = "STRING_EXPR"
        end
        result.str = expr.string
    elseif expr.name ~= nil and not expr.fn_name then
        result.type = "IDENTIFIER_EXPR"
        result.str = expr.name
    elseif expr.operator ~= nil then
        if expr.left_expr ~= nil then
            if expr.operator == "AND_TOKEN" or expr.operator == "OR_TOKEN" then
                result.type = "LOGICAL_EXPR"
            else
                result.type = "BINARY_EXPR"
            end
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
        if expr.arguments and #expr.arguments > 0 then
            result.arguments = {}
            for _, arg in ipairs(expr.arguments) do
                table.insert(result.arguments, serialize_expr(arg))
            end
        end
    elseif expr.expr ~= nil then
        result.type = "PARENTHESIZED_EXPR"
        result.expr = serialize_expr(expr.expr)
    end
    
    return result
end

local function serialize_statement(stmt)
    local result = {}
    local stmt_type = stmt.stmt_type

    if stmt_type == "VariableStatement" then
        result.type = "VARIABLE_STATEMENT"
        result.name = stmt.name
        if stmt.type then
            result.variable_type = stmt.type_name
        end
        result.assignment = serialize_expr(stmt.expr)
    elseif stmt_type == "CallStatement" then
        result.type = "CALL_STATEMENT"
        result.name = stmt.expr.fn_name
        if stmt.expr.arguments and #stmt.expr.arguments > 0 then
            result.arguments = {}
            for _, arg in ipairs(stmt.expr.arguments) do
                table.insert(result.arguments, serialize_expr(arg))
            end
        end
    elseif stmt_type == "IfStatement" then
        result.type = "IF_STATEMENT"
        result.condition = serialize_expr(stmt.condition)
        if stmt.if_body and #stmt.if_body > 0 then
            result.if_statements = {}
            for _, s in ipairs(stmt.if_body) do
                table.insert(result.if_statements, serialize_statement(s))
            end
        end
        if stmt.else_body and #stmt.else_body > 0 then
            result.else_statements = {}
            for _, s in ipairs(stmt.else_body) do
                table.insert(result.else_statements, serialize_statement(s))
            end
        end
    elseif stmt_type == "ReturnStatement" then
        result.type = "RETURN_STATEMENT"
        if stmt.value then
            result.expr = serialize_expr(stmt.value)
        end
    elseif stmt_type == "WhileStatement" then
        result.type = "WHILE_STATEMENT"
        result.condition = serialize_expr(stmt.condition)
        result.statements = {}
        if stmt.body_statements then
            for _, s in ipairs(stmt.body_statements) do
                table.insert(result.statements, serialize_statement(s))
            end
        end
    elseif stmt_type == "CommentStatement" then
        result.type = "COMMENT_STATEMENT"
        result.comment = stmt.string
    elseif stmt_type == "BreakStatement" then
        result.type = "BREAK_STATEMENT"
    elseif stmt_type == "ContinueStatement" then
        result.type = "CONTINUE_STATEMENT"
    elseif stmt_type == "EmptyLineStatement" then
        result.type = "EMPTY_LINE_STATEMENT"
    end

    return result
end

local function serialize_arguments(arguments)
    local result = {}
    for _, arg in ipairs(arguments) do
        table.insert(result, { name = arg.name, type = arg.type_name })
    end
    return result
end

local function serialize_global_statement(stmt)
    local result = {}
    local stmt_type = stmt.stmt_type

    if stmt_type == "OnFn" then
        result.type = "GLOBAL_ON_FN"
        result.name = stmt.fn_name
        if stmt.arguments and #stmt.arguments > 0 then
            result.arguments = serialize_arguments(stmt.arguments)
        end
        result.statements = {}
        if stmt.body_statements then
            for _, s in ipairs(stmt.body_statements) do
                table.insert(result.statements, serialize_statement(s))
            end
        end
    elseif stmt_type == "HelperFn" then
        result.type = "GLOBAL_HELPER_FN"
        result.name = stmt.fn_name
        if stmt.arguments and #stmt.arguments > 0 then
            result.arguments = serialize_arguments(stmt.arguments)
        end
        if stmt.return_type then
            result.return_type = stmt.return_type_name
        end
        result.statements = {}
        if stmt.body_statements then
            for _, s in ipairs(stmt.body_statements) do
                table.insert(result.statements, serialize_statement(s))
            end
        end
    elseif stmt_type == "VariableStatement" then
        result.type = "GLOBAL_VARIABLE"
        result.name = stmt.name
        result.variable_type = stmt.type_name
        result.assignment = serialize_expr(stmt.expr)
    elseif stmt_type == "CommentStatement" then
        result.type = "GLOBAL_COMMENT"
        result.comment = stmt.string
    elseif stmt_type == "EmptyLineStatement" then
        result.type = "GLOBAL_EMPTY_LINE"
    end

    return result
end

local function ast_to_json_text(ast)
    local serialized = {}
    for _, node in ipairs(ast) do
        table.insert(serialized, serialize_global_statement(node))
    end
    return json.encode(serialized)
end

local function ast_to_grug(ast)
    local output = {}
    local indentation = 0

    local function write(text)
        table.insert(output, text)
    end

    local function apply_indentation()
        write(string.rep("    ", indentation))
    end

    local apply_expr
    local apply_statement
    local apply_statements

    apply_expr = function(expr)
        local expr_type = expr.type

        if expr_type == "TRUE_EXPR" then
            write("true")
        elseif expr_type == "FALSE_EXPR" then
            write("false")
        elseif expr_type == "STRING_EXPR" then
            write('"' .. expr.str .. '"')
        elseif expr_type == "ENTITY_EXPR" then
            write('e"' .. expr.str .. '"')
        elseif expr_type == "RESOURCE_EXPR" then
            write('r"' .. expr.str .. '"')
        elseif expr_type == "IDENTIFIER_EXPR" then
            write(expr.str)
        elseif expr_type == "NUMBER_EXPR" then
            write(tostring(expr.value))
        elseif expr_type == "UNARY_EXPR" then
            local op = expr.operator
            if op == "MINUS_TOKEN" then
                write("-")
            else
                write("not ")
            end
            apply_expr(expr.expr)
        elseif expr_type == "BINARY_EXPR" then
            apply_expr(expr.left_expr)
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
                LESS_TOKEN = "<"
            }
            write(" " .. op_map[expr.operator] .. " ")
            apply_expr(expr.right_expr)
        elseif expr_type == "LOGICAL_EXPR" then
            apply_expr(expr.left_expr)
            local op = (expr.operator == "AND_TOKEN") and "and" or "or"
            write(" " .. op .. " ")
            apply_expr(expr.right_expr)
        elseif expr_type == "CALL_EXPR" then
            write(expr.name .. "(")
            if expr.arguments then
                for i, arg in ipairs(expr.arguments) do
                    if i > 1 then write(", ") end
                    apply_expr(arg)
                end
            end
            write(")")
        elseif expr_type == "PARENTHESIZED_EXPR" then
            write("(")
            apply_expr(expr.expr)
            write(")")
        end
    end

    local function try_get_else_if(else_statements)
        if else_statements and #else_statements > 0 and else_statements[1].type == "IF_STATEMENT" then
            return else_statements[1]
        end
        return nil
    end

    local function apply_comment(statement)
        write("# " .. statement.comment .. "\n")
    end

    local function apply_if_statement(statement)
        write("if ")
        apply_expr(statement.condition)
        write(" {\n")

        if statement.if_statements then
            apply_statements(statement.if_statements)
        end

        if statement.else_statements and #statement.else_statements > 0 then
            apply_indentation()
            write("} else ")

            local else_if_node = try_get_else_if(statement.else_statements)
            if else_if_node then
                apply_if_statement(else_if_node)
            else
                write("{\n")
                apply_statements(statement.else_statements)
                apply_indentation()
                write("}\n")
            end
        else
            apply_indentation()
            write("}\n")
        end
    end

    apply_statement = function(statement)
        local stmt_type = statement.type

        if stmt_type == "VARIABLE_STATEMENT" then
            write(statement.name)
            if statement.variable_type then
                write(": " .. statement.variable_type)
            end
            write(" = ")
            apply_expr(statement.assignment)
            write("\n")
        elseif stmt_type == "CALL_STATEMENT" then
            write(statement.name .. "(")
            if statement.arguments then
                for i, arg in ipairs(statement.arguments) do
                    if i > 1 then write(", ") end
                    apply_expr(arg)
                end
            end
            write(")\n")
        elseif stmt_type == "IF_STATEMENT" then
            apply_if_statement(statement)
        elseif stmt_type == "RETURN_STATEMENT" then
            write("return")
            if statement.expr then
                write(" ")
                apply_expr(statement.expr)
            end
            write("\n")
        elseif stmt_type == "WHILE_STATEMENT" then
            write("while ")
            apply_expr(statement.condition)
            write(" {\n")
            apply_statements(statement.statements)
            apply_indentation()
            write("}\n")
        elseif stmt_type == "BREAK_STATEMENT" then
            write("break\n")
        elseif stmt_type == "CONTINUE_STATEMENT" then
            write("continue\n")
        elseif stmt_type == "COMMENT_STATEMENT" then
            apply_comment(statement)
        end
    end

    apply_statements = function(statements)
        indentation = indentation + 1
        for _, statement in ipairs(statements) do
            if statement.type == "EMPTY_LINE_STATEMENT" then
                write("\n")
            else
                apply_indentation()
                apply_statement(statement)
            end
        end
        indentation = indentation - 1
    end

    local function apply_arguments(arguments)
        for i, arg in ipairs(arguments) do
            if i > 1 then write(", ") end
            write(arg.name .. ": " .. arg.type)
        end
    end

    local function apply_helper_fn(statement)
        write(statement.name .. "(")
        if statement.arguments then
            apply_arguments(statement.arguments)
        end
        write(")")
        if statement.return_type then
            write(" " .. statement.return_type)
        end
        write(" {\n")
        apply_statements(statement.statements)
        write("}\n")
    end

    local function apply_on_fn(statement)
        write(statement.name .. "(")
        if statement.arguments then
            apply_arguments(statement.arguments)
        end
        write(") {\n")
        apply_statements(statement.statements)
        write("}\n")
    end

    local function apply_global_variable(statement)
        write(statement.name .. ": " .. statement.variable_type .. " = ")
        apply_expr(statement.assignment)
        write("\n")
    end

    local function apply_root(root)
        for _, statement in ipairs(root) do
            local stmt_type = statement.type

            if stmt_type == "GLOBAL_VARIABLE" then
                apply_global_variable(statement)
            elseif stmt_type == "GLOBAL_ON_FN" then
                apply_on_fn(statement)
            elseif stmt_type == "GLOBAL_HELPER_FN" then
                apply_helper_fn(statement)
            elseif stmt_type == "GLOBAL_EMPTY_LINE" then
                write("\n")
            elseif stmt_type == "GLOBAL_COMMENT" then
                apply_comment(statement)
            end
        end
    end

    apply_root(ast)
    return table.concat(output)
end
