# examples/host_fn_errors/ does not clearly print it's a game_fn_error, and exits with status 1

- `local function default_runtime_error_handler(reason, grug_runtime_error_type, export_fn_name, export_fn_path)`
    - `print("grug runtime error in "`

Right now grug-for-lua does not have this code from grug-for-python, so I don't get how it was possible for it to pass the tests without this. Should it be removed from grug-for-python?
```python
if self.state.fn_depth > 1:
    raise  # Propagate exception
```

# Check that when passing the _interpreter backend_ to examples/host_fn_errors/, it prints a clear game_fn_error error message, and exits with status 0

# Can tests.lua its `_raise_host_fn_error_if_needed` and other uses of `RERAISED_GAME_FN_ERROR` in it be simplified, now that grug.lua has game_fn_error()?

# Should this be raising `RERAISED_TIME_LIMIT_EXCEEDED` instead? Is this missing a test in grug-tests?

- `function TranspilerBackend:call_on_function(entity, export_fn_name, ...)`
    - `if type(err) == "table" and err.type == "TIME_LIMIT_EXCEEDED" then`

# SPORADIC RUNTIME CRASH

- `luajit -lluacov tests.lua spill_args_to_helper_fn_32_bit_f32`
    - Sporadically prints `/home/trez/Programming/grug-tests/tests.c:3694: Assertion 'X    ' (game_fn_offset_32_bit_f32_s1) == '1' failed.`



# Will be covered by Nikhil

- `function Parser:enter_scope(token)`
    - Max parsing depth; Nikhil is assigned to [Add tests/err/max_parsing_depth](https://github.com/grug-lang/grug-tests/issues/141)

# interpreter_backend.lua

- `function _InterpreterEntity:_run_call_expr(call_expr)`
    - `if self._flow then`: Nikhil is working on adding a test for this [here](https://discord.com/channels/1326985575475052675/1403883710406721546/1539000155397824625)

# Missing a test in grug-tests

- `function TypePropagator:fill_method_expr(expr)`
    - `elseif self.current_global then`; add this `tests/ok/method_return_value/input-D.grug` once grug-for-lua supports method chaining:
```py
n: number = vec_number_new().push(42).pop()

export a() {
    initialize(n)
}
```
