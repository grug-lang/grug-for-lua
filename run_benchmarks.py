#!/usr/bin/env python3

import argparse
import json
import os
import shlex
import subprocess
import sys
from collections import defaultdict
from contextlib import contextmanager
from pathlib import Path
from typing import Dict, List

SPECIALIZATIONS = [
    "unsafe lua reference",
    "unsafe grug transpiler backend",
    "safe grug transpiler backend",
    "unsafe grug interpreter backend",
    "safe grug interpreter backend",
]

NUM_RUNS = 10


@contextmanager
def change_dir(path: Path):
    prev_cwd = Path.cwd()
    try:
        os.chdir(path)
        yield
    finally:
        os.chdir(prev_cwd)


def run(cmd: List[str], specialization: str):
    full_cmd = cmd + [
        "benchmark.lua",
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

    if percent_slower > 5:
        print(
            f"Error: The unsafe grug transpiler backend was {percent_slower:.2f}% slower than the Lua reference!",
            file=sys.stderr,
        )
        print(f"  grug: {grug_speed:.2f} iters/sec", file=sys.stderr)
        print(f"  Lua:  {ref_speed:.2f} iters/sec", file=sys.stderr)
        sys.exit(1)

    elif percent_slower < -5:
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

        # Accumulates results for all configurations to check transpiler slowness at the end
        all_aggregated = []

        with change_dir(d):
            # Iterate through each Lua implementation configuration
            for executable, json_file in configs.items():
                print(f"--- Implementation: {executable} ---", file=sys.stderr)

                samples: Dict[str, list] = defaultdict(list)
                last_metadata = {}

                for specialization in specializations:
                    print(f"--- Specialization: {specialization} ---", file=sys.stderr)

                    for run_idx in range(1, NUM_RUNS + 1):
                        print(
                            f"  Run {run_idx}/{NUM_RUNS} ({executable})...",
                            file=sys.stderr,
                        )
                        run(shlex.split(executable), specialization)

                        # Reads the ephemeral results.json created by the Lua script
                        with Path("results.json").open("r") as f:
                            current = json.load(f)

                        last_metadata = current.get("metadata", {})
                        for spec in current["specializations"]:
                            samples[spec["name"]].append(spec)

                # Reduce each specialization name to its fastest iters_per_sec for this implementation
                aggregated_specs = []
                for name, specs in samples.items():
                    max_iters_per_sec = max(spec["iters_per_sec"] for spec in specs)
                    iterations = specs[0]["iterations"]
                    reduced_spec = {
                        "name": name,
                        "elapsed": iterations / max_iters_per_sec,
                        "iterations": iterations,
                        "iters_per_sec": max_iters_per_sec,
                    }
                    aggregated_specs.append(reduced_spec)

                    # Only assert regressions on standard engines, ignoring interpreter-only flag overhead
                    if "-joff" not in executable:
                        all_aggregated.append(reduced_spec)

                # Output the aggregated payload intended for visualize_benchmarks.py
                summary_data = {
                    "metadata": last_metadata,
                    "specializations": aggregated_specs,
                }

                with Path(json_file).open("w") as f:
                    json.dump(summary_data, f, indent=2)

        check_unsafe_grug_transpiler_backend_wasnt_slow(all_aggregated)


if __name__ == "__main__":
    main()
