#!/usr/bin/env python3
"""
Visualize iters_per_sec of Lua benchmark specializations across multiple Lua implementations.
"""

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict, List

import matplotlib.pyplot as plt  # pyright: ignore[reportMissingImports]
import pandas as pd  # pyright: ignore[reportMissingImports]
import seaborn as sns  # pyright: ignore[reportMissingModuleSource]

sns.set_theme(style="whitegrid")


def load_results(directory: Path) -> List[Dict[str, Any]]:
    json_files = sorted(
        path for path in directory.rglob("*.json") if path.name != "mod_api.json"
    )
    if not json_files:
        sys.exit(f"Error: no .json files found in '{directory}'")

    records: List[Dict[str, Any]] = []
    for path in json_files:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            print(f"Warning: skipping '{path.name}': {exc}", file=sys.stderr)
            continue

        metadata = data["metadata"]
        lua_version = metadata["lua_version"]
        jit_version = metadata.get("jit_version", False)
        label = jit_version if jit_version else lua_version

        specializations = data.get("specializations", [])
        if not specializations:
            continue

        records.append({"label": label, "specializations": specializations})

    if not records:
        sys.exit("Error: no valid result files could be loaded.")

    return records


def build_dataframe(records: List[Dict[str, Any]]) -> pd.DataFrame:
    rows: List[Dict[str, Any]] = []
    for rec in records:
        label = rec["label"]
        for spec in rec["specializations"]:
            rows.append(
                {
                    "implementation": label,
                    "specialization": spec["name"],
                    "iters_per_sec": spec["iters_per_sec"],
                }
            )
    return pd.DataFrame(rows)


def main() -> None:
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "-i",
        "--input",
        type=Path,
        default="benchmarks",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default="results.svg",
    )
    parser.add_argument("--title")

    args = parser.parse_args()

    directory = args.input.resolve()
    if not directory.is_dir():
        sys.exit(f"Error: '{directory}' is not a directory.")

    print(f"Loading JSON files from: {directory}")
    records = load_results(directory)

    print(f"Loaded {len(records)} implementation(s)")
    for rec in records:
        print(f"  • {rec['label']}")

    df = build_dataframe(records)

    # Order specs consistently
    spec_order = sorted(df["specialization"].unique())  # type: ignore

    fig_width = 10

    num_specs = len(spec_order)
    fig_height = num_specs * 1.3

    plt.figure(figsize=(fig_width, fig_height))  # type: ignore

    ax = sns.barplot(
        data=df,
        x="iters_per_sec",
        y="specialization",
        hue="implementation",
        order=spec_order,
        errorbar=None,
    )

    ax.set_title(args.title)  # type: ignore
    ax.set_xlabel("Iterations per second (Logarithmic)")  # type: ignore
    ax.set_xscale("log")  # type: ignore
    ax.yaxis.label.set_visible(False)

    plt.legend(title="Implementation", bbox_to_anchor=(1.05, 1), loc="upper left")  # type: ignore

    plt.tight_layout()

    output = args.output

    plt.savefig(output)  # type: ignore
    print(f"\nChart saved to: {output}")


if __name__ == "__main__":
    main()
