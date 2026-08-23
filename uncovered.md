# Missing tests in grug-tests

- `function TranspilerBackend:call_on_function(entity, export_fn_name, ...)`
    - `error({ type = "RERAISED_TIME_LIMIT_EXCEEDED", reason = err.reason }, 0)`
    - `error({ type = "RERAISED_GAME_FN_ERROR", reason = err.reason }, 0)`
    - `error({ type = "RERAISED_STACK_OVERFLOW" }, 0)`
    - `error(err, 0)`


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
