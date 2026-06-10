#!/usr/bin/env python3
import csv
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.lines import Line2D
from matplotlib.patches import Patch


ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "source" / "vm32_realworld_main_local16_32_48_summary.csv"

CONFIG_ORDER = ["migration_off", "tiering_0x2", "tpp_0x4"]
CONFIG_LABEL = {
    "migration_off": "Off",
    "tiering_0x2": "Migration on\n(tiering 0x2)",
    "tpp_0x4": "TPP\n(0x4)",
}
CONFIG_COLOR = {
    "migration_off": "#5b6573",
    "tiering_0x2": "#d07a35",
    "tpp_0x4": "#4f9d8f",
}
PROMOTION_COLOR = "#111827"

WORKLOAD_ORDER = [
    "bc",
    "btree",
    "faster_uniform",
    "faster_ycsb_a",
    "graph500",
    "gups",
    "liblinear",
    "pr",
    "redis_uniform",
    "redis_ycsb_a",
    "silo",
]

PANELS = [
    {
        "name": "local16_pr",
        "title": "Local memory 16 GiB / pr",
        "predicate": lambda row: row["local_size_gib"] == "16"
        and row["workload"] == "pr",
        "workloads": ["pr"],
    },
    {
        "name": "local32_btree",
        "title": "Local memory 32 GiB / btree",
        "predicate": lambda row: row["local_size_gib"] == "32"
        and row["workload"] == "btree",
        "workloads": ["btree"],
    },
    {
        "name": "local48_gups",
        "title": "Local memory 48 GiB / gups",
        "predicate": lambda row: row["local_size_gib"] == "48"
        and row["workload"] == "gups",
        "workloads": ["gups"],
    },
]


def read_rows():
    with SOURCE.open(newline="") as handle:
        rows = list(csv.DictReader(handle))
    rows = [
        row
        for row in rows
        if row["config"] in CONFIG_ORDER and row.get("returncode", "0") == "0"
    ]
    return rows


def write_csv(path, rows):
    if not rows:
        raise RuntimeError(f"no rows to write: {path}")
    fieldnames = [
        "panel",
        "local_size_gib",
        "workload",
        "config",
        "elapsed_s",
        "promoted_GiB",
        "demoted_GiB",
        "max_rss_kb",
        "max_process_N0_GiB",
        "max_process_N1_GiB",
        "source_result_dir",
        "command",
        "placement",
    ]
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(
                {
                    "panel": row.get("panel", ""),
                    "local_size_gib": row["local_size_gib"],
                    "workload": row["workload"],
                    "config": row["config"],
                    "elapsed_s": row["elapsed_s"],
                    "promoted_GiB": row["promoted_GiB"],
                    "demoted_GiB": row["demoted_GiB"],
                    "max_rss_kb": row["max_rss_kb"],
                    "max_process_N0_GiB": row["max_process_N0_GiB"],
                    "max_process_N1_GiB": row["max_process_N1_GiB"],
                    "source_result_dir": row["result_dir"],
                    "command": row["command"],
                    "placement": row["placement"],
                }
            )


def selected_rows(rows):
    all_selected = []
    by_panel = {}
    for panel in PANELS:
        panel_rows = []
        for row in rows:
            if panel["predicate"](row):
                copied = dict(row)
                copied["panel"] = panel["name"]
                panel_rows.append(copied)
        panel_rows.sort(
            key=lambda row: (
                panel["workloads"].index(row["workload"])
                if row["workload"] in panel["workloads"]
                else 10_000,
                CONFIG_ORDER.index(row["config"]),
            )
        )
        by_panel[panel["name"]] = panel_rows
        all_selected.extend(panel_rows)
    return by_panel, all_selected


def plot(by_panel):
    fig, axes = plt.subplots(
        nrows=1,
        ncols=3,
        figsize=(15, 4.8),
        constrained_layout=False,
    )
    fig.subplots_adjust(left=0.07, right=0.995, top=0.77, bottom=0.22, wspace=0.28)

    for ax, panel in zip(axes, PANELS):
        panel_rows = by_panel[panel["name"]]
        by_config = {}
        workload = ""
        local_size = ""
        for row in panel_rows:
            by_config[row["config"]] = row
            workload = row["workload"]
            local_size = row["local_size_gib"]

        x = np.arange(len(CONFIG_ORDER))
        elapsed = np.array([float(by_config[config]["elapsed_s"]) for config in CONFIG_ORDER])
        promoted = np.array(
            [float(by_config[config]["promoted_GiB"]) for config in CONFIG_ORDER]
        )

        bars = ax.bar(
            x,
            elapsed,
            width=0.56,
            color=[CONFIG_COLOR[config] for config in CONFIG_ORDER],
        )
        for bar, value in zip(bars, elapsed):
            ax.text(
                bar.get_x() + bar.get_width() / 2.0,
                bar.get_height(),
                f"{value:.0f}s",
                ha="center",
                va="bottom",
                fontsize=9.0,
                rotation=0,
            )

        ax2 = ax.twinx()
        ax2.plot(
            x,
            promoted,
            color=PROMOTION_COLOR,
            marker="o",
            markersize=5,
            linewidth=2.0,
        )
        ax2.set_ylabel("Promoted (GiB)")
        prom_max = float(promoted.max())
        ax2.set_ylim(0, prom_max * 1.25 if prom_max > 0 else 1.0)
        ax2.tick_params(axis="y", labelsize=8)

        ax.set_title(panel["title"], loc="left", fontsize=12, pad=10)
        ax.set_ylabel("Execution time (s)")
        ax.set_ylim(0, float(elapsed.max()) * 1.25)
        ax.grid(axis="y", linewidth=0.6, alpha=0.25)
        ax.set_axisbelow(True)
        ax.set_xticks(x)
        ax.set_xticklabels([CONFIG_LABEL[config] for config in CONFIG_ORDER], fontsize=8)
        ax.set_xlabel(f"{workload}, local {local_size}G")
        ax.set_xlim(-0.55, len(CONFIG_ORDER) - 0.45)

    handles = [
        Patch(facecolor=CONFIG_COLOR[config], label=CONFIG_LABEL[config].replace("\n", " "))
        for config in CONFIG_ORDER
    ]
    handles.append(
        Line2D(
            [0],
            [0],
            color=PROMOTION_COLOR,
            marker="o",
            linewidth=2.0,
            label="Promoted GiB (right axis)",
        )
    )
    fig.legend(
        handles=handles,
        loc="upper center",
        bbox_to_anchor=(0.5, 0.88),
        ncols=4,
        frameon=False,
    )
    fig.suptitle(
        "VM32 selected real-world results: execution time, controller excluded",
        fontsize=15,
        y=0.985,
    )
    fig.text(
        0.07,
        0.045,
        "Bars are elapsed seconds on the left linear y-axis. The black line shows promoted GiB on the right linear y-axis.",
        fontsize=9,
        color="#4b5563",
    )

    for suffix in ("png", "pdf", "svg"):
        fig.savefig(ROOT / f"vm32_selected_execution_time.{suffix}", dpi=220)
    plt.close(fig)


def write_readme():
    readme = ROOT / "README.md"
    readme.write_text(
        """# Motivation 1 VM32 Selected Results

This directory contains selected VM32 real-world results copied from
`motivation/3_realworld/VM` for submission figure generation.

Selection:

- local memory 16 GiB: `pr`, configs `migration_off`, `tiering_0x2`, `tpp_0x4`
- local memory 32 GiB: `btree`, same configs
- local memory 48 GiB: `gups`, same configs
- `controller_0x2` is excluded

Generated artifacts:

- `vm32_selected_results.csv`: all selected rows
- `vm32_local16_pr_results.csv`
- `vm32_local32_btree_results.csv`
- `vm32_local48_gups_results.csv`
- `vm32_selected_execution_time.{png,pdf,svg}`
- `plot_vm32_selected.py`: source used to regenerate the CSVs and figure

The figure uses dual linear y-axes: execution time bars on the left y-axis and
promoted GiB as a line plot on the right y-axis.
"""
    )


def main():
    rows = read_rows()
    by_panel, all_selected = selected_rows(rows)
    write_csv(ROOT / "vm32_selected_results.csv", all_selected)
    write_csv(ROOT / "vm32_local16_pr_results.csv", by_panel["local16_pr"])
    write_csv(ROOT / "vm32_local32_btree_results.csv", by_panel["local32_btree"])
    write_csv(ROOT / "vm32_local48_gups_results.csv", by_panel["local48_gups"])
    plot(by_panel)
    write_readme()


if __name__ == "__main__":
    main()
