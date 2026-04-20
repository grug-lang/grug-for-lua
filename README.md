# grug for Lua

This is a Lua 5.1 implementation of [grug](https://github.com/grug-lang/grug).

## Dependencies

- Lua 5.1 or newer

## Running tests

Clone [grug-tests](https://github.com/grug-lang/grug-tests) next to this repository and build it, and then run this [luajit](https://luajit.org/index.html) command in grug-for-lua:

```sh
python amalgamate.py && luajit tests.lua
```

## Contributing

If you edit Python files like `amalgamate.py`, note that the CI rejects unformatted Python code and type errors.

To catch these automatically before pushing, set up the pre-commit hook:

```bash
pip install pre-commit
pre-commit install
```

Black and Pyright will then run on every `git commit`. You can also run them manually at any time with `pre-commit run --all-files`.
