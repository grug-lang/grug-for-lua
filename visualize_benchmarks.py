#!/usr/bin/env python3
"""
Visualize iters_per_sec of Lua benchmark specializations across multiple Lua implementations.
Iterates through each directory in 'benchmarks' and generates a local results.svg.
"""

import json
import sys
from pathlib import Path
from typing import Any, Dict, List

import matplotlib.pyplot as plt  # pyright: ignore[reportMissingImports]
import pandas as pd  # pyright: ignore[reportMissingImports]
import seaborn as sns  # pyright: ignore[reportMissingModuleSource]

sns.set_theme(style="whitegrid")

SPECIALIZATIONS = [
    "unsafe lua reference",
    "unsafe grug transpiler backend",
    "safe grug transpiler backend",
    "unsafe grug interpreter backend",
    "safe grug interpreter backend",
]


def load_results(directory: Path) -> List[Dict[str, Any]]:
    # Ignore both the temporary 'results.json' and 'mod_api.json'
    json_files = sorted(
        path
        for path in directory.glob("*.json")
        if path.name not in ["mod_api.json", "results.json"]
    )

    if not json_files:
        sys.exit(f"Error: no valid .json files found in '{directory}'")

    records: List[Dict[str, Any]] = []
    for path in json_files:
        data = json.loads(path.read_text(encoding="utf-8"))

        specializations = data["specializations"]

        records.append({"label": path.stem, "specializations": specializations})

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
    benchmarks_root = Path("benchmarks")

    if not benchmarks_root.is_dir():
        sys.exit(f"Error: '{benchmarks_root}' directory not found.")

    # Iterate over all subdirectories in the benchmarks directory
    for bench_dir in sorted(benchmarks_root.iterdir()):
        if not bench_dir.is_dir():
            continue

        print(f"Processing benchmark: {bench_dir.name}")
        records = load_results(bench_dir)

        df = build_dataframe(records)

        # Filter to valid specializations and order the labels (y-axis)
        # by the highest single 'iters_per_sec' value in each group
        spec_order = (
            df[df["specialization"].isin(SPECIALIZATIONS)]
            .groupby("specialization")["iters_per_sec"]
            .max()
            .sort_values(ascending=False)
            .index.tolist()
        )

        # Determine the order of the bars (implementations) within each label
        imp_order = (
            df.groupby("implementation")["iters_per_sec"]
            .max()
            .sort_values(ascending=False)
            .index.tolist()
        )

        fig_width = 10
        fig_height = len(spec_order) * 1.3

        plt.figure(figsize=(fig_width, fig_height))  # type: ignore

        ax = sns.barplot(
            data=df,
            x="iters_per_sec",
            y="specialization",
            hue="implementation",
            order=spec_order,  # Enforces dynamic label ordering (fastest group first)
            hue_order=imp_order,  # Enforces dynamic bar ordering (fastest bar first)
            errorbar=None,
        )

        ax.set_xlabel("Iterations per second (Logarithmic)")  # type: ignore
        ax.set_xscale("log")  # type: ignore
        ax.yaxis.label.set_visible(False)

        plt.legend(title="Implementation", bbox_to_anchor=(1.05, 1), loc="upper left")  # type: ignore
        plt.tight_layout()

        output_path = bench_dir / "results.svg"
        plt.savefig(output_path)  # type: ignore
        plt.close()  # Close the figure to free memory and avoid overplotting

        print(f"  Chart saved to: {output_path}")


if __name__ == "__main__":
    main()
