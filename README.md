# grug for Lua

This is a Lua 5.1 implementation of [grug](https://github.com/grug-lang/grug).

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
