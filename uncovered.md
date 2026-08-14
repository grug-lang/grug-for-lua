These are all based on commit `3012ae57`, and the few local changes I made afterwards

# Missing example test

- `GrugFile.__index = function(self, key)`
    - `error(("GrugFile '%s' is not a directory and cannot be indexed")`
- `GrugDir.__index = function(self, key)`
    - `error(("%s not found"):format(tostring(key)), 2)`
- `function GrugDir:create_entity()`
    - `error(("'%s' is a directory, not a file"):format(self.name), 2)`
- `function grug:update()`
    - `print(err)`
- `function grug:_update_dir(current_path, grug_dir, seen_files, seen_dirs)`
    - `if self.fs.is_dir(entry_path) then`
- `function grug:_update()`
    - `error("Error: grug:update() requires list_dir and is_dir OR a grug_files list.")`

# Missing a test in grug-tests

- `function Parser:parse_statement()`
    - `elseif tok.type == "NEWLINE_TOKEN" then`
- `function TypePropagator:fill_method_expr(expr)`
    - `elseif self.current_global then`

# Will be covered by Nikhil's test

- `function Parser:enter_scope(token)`
    - Max parsing depth
