#!/usr/bin/env python3

import argparse
import os
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path
from typing import Dict


@contextmanager
def change_dir(path: Path):
    prev_cwd = Path.cwd()
    try:
        os.chdir(path)
        yield
    finally:
        os.chdir(prev_cwd)


def run(executable: str, json_filename: str):
    result = subprocess.run([executable, "benchmark.lua", json_filename])
    if result.returncode != 0:
        print(f"Command failed with exit code {result.returncode}")
        sys.exit(result.returncode)


def parse_args() -> Dict[str, str]:
    parser = argparse.ArgumentParser(description="Run Lua benchmarks")

    parser.add_argument(
        "--impl",
        nargs=2,
        action="append",
        metavar=("EXECUTABLE", "JSON"),
        help="Add implementation (e.g. lua lua5.5.json)",
        required=True,
    )

    args = parser.parse_args()

    return {exe: json_file for exe, json_file in args.impl}


def main():
    configs = parse_args()

    benchmarks_root = Path("benchmarks")
    dirs = sorted(d for d in benchmarks_root.iterdir() if d.is_dir())

    for d in dirs:
        benchmark_file = d / "benchmark.lua"

        if not benchmark_file.is_file():
            print(f"Skipping {d.name}: no benchmark.lua found")
            continue

        print(f"=== Running benchmark {d.name}/ ===")

        with change_dir(d):
            for executable, json_file in configs.items():
                run(executable, json_file)


if __name__ == "__main__":
    main()
