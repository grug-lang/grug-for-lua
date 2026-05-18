#!/usr/bin/env python3

import argparse
import json
import os
import shlex
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path
from typing import Dict, List

SPECIALIZATIONS = [
    "safe grug transpiler backend",
    "unsafe grug transpiler backend",
    "safe grug interpreter backend",
    "unsafe grug interpreter backend",
    "unsafe lua reference",
]


@contextmanager
def change_dir(path: Path):
    prev_cwd = Path.cwd()
    try:
        os.chdir(path)
        yield
    finally:
        os.chdir(prev_cwd)


def run(cmd: List[str], json_filename: str, specialization: str):
    full_cmd = cmd + [
        "benchmark.lua",
        json_filename,
        "--specialization",
        specialization,
    ]

    result = subprocess.run(full_cmd)

    if result.returncode != 0:
        print(f"Command failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(result.returncode)


def check_unsafe_grug_transpiler_backend_wasnt_slow(specializations):
    grug_speed = None
    ref_speed = None

    for spec in specializations:
        name = spec["name"]
        speed = spec["iters_per_sec"]

        if name == "unsafe grug transpiler backend":
            grug_speed = speed
        elif name == "unsafe lua reference":
            ref_speed = speed

    if grug_speed is None or ref_speed is None:
        return

    percent_slower = ((ref_speed - grug_speed) / ref_speed) * 100

    if percent_slower > 3:
        print(
            f"Error: The unsafe grug transpiler backend was {percent_slower:.2f}% slower than the Lua reference!",
            file=sys.stderr,
        )
        print(f"  grug: {grug_speed:.2f} iters/sec", file=sys.stderr)
        print(f"  Lua:  {ref_speed:.2f} iters/sec", file=sys.stderr)
        sys.exit(1)

    elif percent_slower < -3:
        print(
            f"Error: The unsafe grug transpiler backend was suspiciously fast ({abs(percent_slower):.2f}% faster than the Lua reference)!",
            file=sys.stderr,
        )
        print(f"  grug: {grug_speed:.2f} iters/sec", file=sys.stderr)
        print(f"  Lua:  {ref_speed:.2f} iters/sec", file=sys.stderr)
        sys.exit(1)

    elif percent_slower < 0:
        print(
            f"Success: The unsafe grug transpiler backend was {abs(percent_slower):.2f}% faster than the Lua reference",
            file=sys.stderr,
        )
    else:
        print(
            f"Success: The unsafe grug transpiler backend was only {percent_slower:.2f}% slower than the Lua reference",
            file=sys.stderr,
        )


def parse_args():
    parser = argparse.ArgumentParser(description="Run Lua benchmarks")

    parser.add_argument(
        "--impl",
        nargs=2,
        action="append",
        metavar=("EXECUTABLE", "JSON"),
        help="Add implementation (e.g. --impl 'luajit -jv' luajit.json)",
        required=True,
    )

    parser.add_argument(
        "--benchmark",
        help="Run only a single benchmark directory",
    )

    parser.add_argument(
        "--specialization",
        choices=SPECIALIZATIONS,
        action="append",
        help="Run only a single specialization (can be passed multiple times)",
    )

    return parser.parse_args()


def main():
    args = parse_args()

    configs: Dict[str, str] = {exe: json_file for exe, json_file in args.impl}

    specializations = args.specialization if args.specialization else SPECIALIZATIONS

    benchmarks_root = Path("benchmarks")

    if args.benchmark:
        benchmark_dir = benchmarks_root / args.benchmark

        if not benchmark_dir.is_dir():
            print(f"Benchmark '{args.benchmark}' does not exist", file=sys.stderr)
            sys.exit(1)

        dirs = [benchmark_dir]
    else:
        dirs = sorted(d for d in benchmarks_root.iterdir() if d.is_dir())

    for d in dirs:
        print(f"=== Running benchmark {d.name}/ ===", file=sys.stderr)

        # Accumulates all specializations for this benchmark.
        aggregated = []

        with change_dir(d):
            for specialization in specializations:
                print(f"--- Specialization: {specialization} ---", file=sys.stderr)

                for executable, json_file in configs.items():
                    run(shlex.split(executable), json_file, specialization)

                    # Load results after each run.
                    with Path("results.json").open("r") as f:
                        current = json.load(f)

                    aggregated.extend(current["specializations"])

        check_unsafe_grug_transpiler_backend_wasnt_slow(aggregated)


if __name__ == "__main__":
    main()
