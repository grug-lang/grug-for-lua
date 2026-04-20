# grug for Lua

This is a Lua 5.1 implementation of [grug](https://github.com/grug-lang/grug).

## Example

Run `example.lua` like so:
```sh
cd examples/minimal && lua example.lua
```

Here is `example.lua`:
```lua
package.path = package.path .. ";../../?.lua"
grug = require("grug")

state = grug.init()

state:register_game_fn("print_string", function(state, str)
	print(str)
end)

file = state:compile_grug_file("animals/labrador-Dog.grug")
dog1 = file:create_entity()
dog2 = file:create_entity()

dog1:on_bark("woof")
dog2:on_bark("arf")
```

Here is the `animals/labrador-Dog.grug` file it executes:
```py
on_bark(sound: string) {
    print_string(sound)

    # Print "arf" a second time
    if sound == "arf" {
        print_string(sound)
    }
}
```

The example outputs:
```
woof
arf
arf
```

## Dependencies

- Lua 5.1 or newer

## Running tests

Clone [grug-tests](https://github.com/grug-lang/grug-tests) next to this repository and build it, then run:

```sh
python amalgamate.py && luajit tests.lua
```

This regenerates `grug.lua` and runs the test suite.

## CI behavior

The CI pipeline automatically:

* Regenerates `grug.lua` via `amalgamate.py`
* Verifies no uncommitted changes exist (`git diff --exit-code`)
* Runs the full test suite against `grug-tests`

## Contributing

If you edit Python or Lua files, note that CI rejects unformatted code, type errors, and stale generated output.

To catch issues locally before pushing, install pre-commit hooks:

```bash
pip install pre-commit
pre-commit install
```

Black, Pyright, and StyLua will then run on every commit. You can also run them manually:

```bash
pre-commit run --all-files
```
