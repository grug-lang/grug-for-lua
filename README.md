# grug for Lua

A Lua implementation of [grug](https://github.com/grug-lang/grug).

## Example

Run the minimal example:

```sh
cd examples/minimal && lua example.lua
````

### `example.lua`

```lua
package.path = package.path .. ";../../?.lua"
local grug = require("grug")

local state = grug.init()

state:register("print_string", function(state, str)
	print(str)
end)

local file = state:compile_grug_file("animals/labrador-Dog.grug")
local dog1 = file:create_entity()
local dog2 = file:create_entity()

dog1:on_bark("woof")
dog2:on_bark("arf")
```

### `animals/labrador-Dog.grug`

```py
on_bark(sound: string) {
    print_string(sound)

    # Print "arf" a second time
    if sound == "arf" {
        print_string(sound)
    }
}
```

### Output

```
woof
arf
arf
```

## Dependencies

* Lua 5.1 or newer ([LuaJIT](https://luajit.org/index.html) recommended)

## Running tests

Clone [grug-tests](https://github.com/grug-lang/grug-tests) next to this repository and build it, then run:

```sh
python amalgamate.py && luajit tests.lua
```

This will:

* regenerate `grug.lua`
* run the full test suite

## Benchmarks

### Benchmark: [benchmarks/minimal/](https://github.com/grug-lang/grug-for-lua/tree/main/benchmarks/minimal)

![graph](benchmarks/minimal/results.svg)

### Benchmark: [benchmarks/fibonacci/](https://github.com/grug-lang/grug-for-lua/tree/main/benchmarks/fibonacci)

![graph](benchmarks/fibonacci/results.svg)

### Installing dependencies

```sh
pip install matplotlib seaborn
```

### Running all benchmarks

Customize this command to pass your own executable names and JSON output paths:
```sh
python run_benchmarks.py \
  --impl lua lua5.5.json \
  --impl luajit luajit.json
```

### Investigating slow benchmarks

The CI throws an error if it finds any [LuaJIT NYI](https://github.com/tarantool/tarantool/wiki/LuaJIT-Not-Yet-Implemented) in the trace, as NYIs cause slowdown:
```
[TRACE --- grug.lua:2715 -- NYI: bytecode FNEW   at grug.lua:2724]
```

If a specific benchmark is unexpectedly slow even with LuaJIT, `cd` into its directory and run `luajit -jv benchmark.lua` to print its trace.

You can also pass flags to `run_benchmarks.py` its executables: `--impl "luajit -jv" luajit.json`.

### Generating graphs for all results

```sh
python visualize_benchmarks.py
```

## CI behavior

The CI pipeline automatically:

* Regenerates `grug.lua` via `amalgamate.py`
* Ensures no uncommitted changes exist (`git diff --exit-code`)
* Runs the full test suite against `grug-tests`
* Executes the minimal Lua example as an integration test

## Contributing

If you modify Python or Lua source files, note that CI enforces:

* formatting (Black, StyLua)
* type checking (Pyright)
* static analysis (luacheck)
* up-to-date generated output

## Pre-commit hooks (recommended)

### Install pre-commit

```bash
pip install pre-commit
pre-commit install
```

### Install luacheck

You can install it using the [LuaRocks](https://github.com/luarocks/luarocks) package manager:
```bash
luarocks install luacheck
```

### Run manually

```bash
pre-commit run --all-files
```
