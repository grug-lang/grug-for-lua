These are all based on commit `3012ae57`, and the few local changes I made afterwards

# Use string.format() to fix

- Line 1155 in `function Parser:parse()`: `.. "' on line "`
- Line 1374 in `function Parser:parse_statement()`: `.. " on line "`
- Line 2237 in global scope: `.. "') must have the same type, but got "`
- Line 2239 in global scope: `.. " and "`
- Line 2261 in global scope: `.. "') must have the same type, but got "`
- Line 2263 in global scope: `.. " and "`
- Line 2321 in `function TypePropagator:fill_expr(expr)`: `.. "' directly next to another '"`
- Line 2377 in `function TypePropagator:fill_statements(statements)`: `.. " to '"`
- Line 2410 in `function TypePropagator:fill_statements(statements)`: `.. " to '"`
- Line 2476 in `function TypePropagator:fill_statements(statements)`: `.. "' is supposed to return "`
- Line 2478 in `function TypePropagator:fill_statements(statements)`: `.. ", not "`
- Line 2489 in `function TypePropagator:fill_statements(statements)`: `.. "' is supposed to return a value of type "`
- Line 2551 in `function TypePropagator:fill_global_variables()`: `.. " to '"`
- Line 2724 in `function TypePropagator:fill_local_fns()`: `.. "' is supposed to return "`

# Missing example test

- Line 3722 in `GrugFile.__index = function(self, key)`: `error(("GrugFile '%s' is not a directory and cannot be indexed")`
- Line 3776 in `GrugDir.__index = function(self, key)`: `error(("%s not found"):format(tostring(key)), 2)`
- Line 3788 in `function GrugDir:create_entity()`: `error(("'%s' is a directory, not a file"):format(self.name), 2)`
- Line 3946 in `function grug:update()`: `print(err)`
- Line 3961 in `function grug:_update_dir(current_path, grug_dir, seen_files, seen_dirs)`: `if self.fs.is_dir(entry_path) then`
- Line 4010 in `function grug:_update()`: `error("Error: grug:update() requires list_dir and is_dir OR a grug_files list.")`

# Missing a test in grug-tests

- Line 1363 in `function Parser:parse_statement()`: `elseif tok.type == "NEWLINE_TOKEN" then`
- Line 2202 in `function TypePropagator:fill_method_expr(expr)`: `elseif self.current_global then`

# Will be covered by Nikhil's test

- Line 1044 in `function Parser:enter_scope(token)`: Max parsing depth
