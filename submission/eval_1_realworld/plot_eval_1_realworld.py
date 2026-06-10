#!/usr/bin/env python3
"""Plot Eval 1 real-world normalized execution time and promotions."""

from __future__ import annotations

import csv
import shutil
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patheffects as path_effects
from matplotlib.lines import Line2D
from matplotlib.patches import Patch


REPO_ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = Path(__file__).resolve().parent
SOURCE_DIR = OUT_DIR / "source"
FIGURE_DIR = REPO_ROOT / "experiments" / "figure"

SOURCE_CSV = (
    REPO_ROOT
    / "motivation/3_realworld/VM/summaries/vm32_realworld_combined_with_controller_summary.csv"
)

LOCAL_SIZES = [16, 32, 48]
WORKLOADS = [
    ("pr", "PR"),
    ("bc", "BC"),
    ("gups", "GUPS"),
    ("graph500", "Graph500"),
    ("btree", "BTree"),
    ("redis_uniform", "Redis-U"),
    ("redis_ycsb_a", "Redis-A"),
    ("faster_uniform", "FASTER-U"),
    ("faster_ycsb_a", "FASTER-A"),
]
POLICIES = [
    ("tiering_0x2", "memory tiering", "#4C78A8", ""),
    ("tpp_0x4", "TPP", "#9D5DE8", "///"),
    ("controller_0x2", "migration-gatekeeper", "#2A9D55", "xx"),
]
DATA_POLICIES = [policy for policy, _label, _color, _hatch in POLICIES]


def read_rows() -> list[dict[str, str]]:
    with SOURCE_CSV.open() as file:
        rows = list(csv.DictReader(file))
    return [
        row
        for row in rows
        if int(row["local_size_gib"]) in LOCAL_SIZES
        and row["workload"] in {workload for workload, _label in WORKLOADS}
        and row["config"] in {"migration_off", *DATA_POLICIES}
    ]


def write_selected_csv(rows: list[dict[str, str]], path: Path) -> None:
    fieldnames = [
        "local_size_gib",
        "workload",
        "workload_label",
        "policy",
        "policy_label",
        "migration_off_elapsed_s",
        "policy_elapsed_s",
        "normalized_execution_time_vs_off",
        "pgpromote_success",
        "execution_time_s",
    ]
    workload_labels = dict(WORKLOADS)
    policy_labels = {policy: label for policy, label, _color, _hatch in POLICIES}
    with path.open("w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=fieldnames)
        writer.writeheader()
        for local_size in LOCAL_SIZES:
            for workload, _workload_label in WORKLOADS:
                matches = [
                    row
                    for row in rows
                    if int(row["local_size_gib"]) == local_size and row["workload"] == workload
                ]
                off_match = next((row for row in matches if row["config"] == "migration_off"), None)
                if not off_match:
                    continue
                off_elapsed = float(off_match["elapsed_s"])
                for policy, _policy_label, _color, _hatch in POLICIES:
                    match = next((row for row in matches if row["config"] == policy), None)
                    if not match:
                        continue
                    elapsed_s = float(match["elapsed_s"])
                    normalized_elapsed = elapsed_s / off_elapsed if off_elapsed else 0.0
                    writer.writerow(
                        {
                            "local_size_gib": local_size,
                            "workload": workload,
                            "workload_label": workload_labels[workload],
                            "policy": policy,
                            "policy_label": policy_labels[policy],
                            "migration_off_elapsed_s": f"{off_elapsed:.6f}",
                            "policy_elapsed_s": f"{elapsed_s:.6f}",
                            "normalized_execution_time_vs_off": f"{normalized_elapsed:.6f}",
                            "pgpromote_success": match.get("pgpromote_success", "0"),
                            "execution_time_s": f"{elapsed_s:.6f}",
                        }
                    )


def metric_lookup(
    rows: list[dict[str, str]]
) -> tuple[dict[tuple[int, str, str], float], dict[tuple[int, str, str], float]]:
    elapsed_ratios: dict[tuple[int, str, str], float] = {}
    promotion_m: dict[tuple[int, str, str], float] = {}
    off_elapsed: dict[tuple[int, str], float] = {}
    for row in rows:
        local_size = int(row["local_size_gib"])
        workload = row["workload"]
        if row["config"] == "migration_off":
            off_elapsed[(local_size, workload)] = float(row["elapsed_s"])
    for row in rows:
        if row["config"] not in DATA_POLICIES:
            continue
        local_size = int(row["local_size_gib"])
        workload = row["workload"]
        elapsed = float(row["elapsed_s"])
        baseline = off_elapsed[(local_size, workload)]
        elapsed_ratios[(local_size, workload, row["config"])] = elapsed / baseline
        promotion_m[(local_size, workload, row["config"])] = float(row.get("pgpromote_success") or 0) / 1_000_000.0
    return elapsed_ratios, promotion_m


def plot(rows: list[dict[str, str]], output_base: Path) -> None:
    elapsed_ratios, promotion_m = metric_lookup(rows)
    x = list(range(len(WORKLOADS)))
    width = 0.24

    fig, axes = plt.subplots(1, 3, figsize=(14.9, 4.0), sharey=True)
    max_value = max(elapsed_ratios.values())
    y_top = max_value * 1.14
    promotion_y_top = max(1.0, max(promotion_m.values()) * 1.18)

    for ax, local_size in zip(axes, LOCAL_SIZES):
        ax_prom = ax.twinx()
        policy_offsets: dict[str, list[float]] = {}
        for policy_idx, (policy, _label, color, hatch) in enumerate(POLICIES):
            offsets = [pos + (policy_idx - 1) * width for pos in x]
            policy_offsets[policy] = offsets
            heights = [
                elapsed_ratios[(local_size, workload, policy)]
                for workload, _label in WORKLOADS
            ]
            ax.bar(
                offsets,
                heights,
                width=width,
                color=color,
                edgecolor="white",
                linewidth=0.45,
                hatch=hatch,
                alpha=0.72,
            )

        for workload_idx, (workload, _label) in enumerate(WORKLOADS):
            segment_x = [
                policy_offsets[policy][workload_idx]
                for policy, _policy_label, _color, _hatch in POLICIES
            ]
            segment_y = [
                promotion_m[(local_size, workload, policy)]
                for policy, _policy_label, _color, _hatch in POLICIES
            ]
            (line,) = ax_prom.plot(
                segment_x,
                segment_y,
                color="#111827",
                linestyle="-",
                linewidth=1.75,
                alpha=0.92,
                zorder=8,
            )
            line.set_path_effects(
                [
                    path_effects.Stroke(linewidth=3.7, foreground="white"),
                    path_effects.Normal(),
                ]
            )

        for policy, _label, _color, _hatch in POLICIES:
            promotions = [
                promotion_m[(local_size, workload, policy)]
                for workload, _workload_label in WORKLOADS
            ]
            scatter = ax_prom.scatter(
                policy_offsets[policy],
                promotions,
                color="#111827",
                marker="o",
                s=28,
                edgecolors="white",
                linewidths=0.75,
                zorder=11,
            )
            scatter.set_path_effects(
                [
                    path_effects.Stroke(linewidth=1.65, foreground="white"),
                    path_effects.Normal(),
                ]
            )

        ax.axhline(1.0, color="#333333", linewidth=1.0)
        ax.set_title(f"Local memory = {local_size} GiB", fontsize=11, pad=8)
        ax.set_xticks(x)
        ax.set_xticklabels([label for _workload, label in WORKLOADS], rotation=38, ha="right")
        ax.set_ylim(0, y_top)
        ax.grid(axis="y", color="#d9dde3", linewidth=0.6)
        ax.set_axisbelow(True)
        ax.tick_params(axis="both", labelsize=8.5)
        ax_prom.set_ylim(0, promotion_y_top)
        ax_prom.tick_params(axis="y", labelsize=8.5, colors="#5b3b00")
        ax_prom.grid(False)
        if ax is axes[-1]:
            ax_prom.set_ylabel("Promotions (pgpromote_success, M)", color="#5b3b00")
        else:
            ax_prom.set_yticklabels([])

    axes[0].set_ylabel("Normalized execution time\n(migration off = 1.0)")
    for ax in axes:
        ax.set_xlabel("Workload")

    handles = [
        Patch(facecolor=color, edgecolor="white", hatch=hatch, label=label)
        for _policy, label, color, hatch in POLICIES
    ]
    handles.append(
        Line2D(
            [0],
            [0],
            color="#111827",
            linestyle="-",
            linewidth=1.75,
            label="promotion line",
        )
    )
    handles.append(
        Line2D(
            [0],
            [0],
            color="none",
            marker="o",
            markerfacecolor="#111827",
            markeredgecolor="white",
            markeredgewidth=0.75,
            markersize=5.0,
            label="promotion point",
        )
    )
    fig.legend(
        handles=handles,
        loc="upper center",
        ncol=4,
        frameon=False,
        fontsize=8.5,
        bbox_to_anchor=(0.5, 1.07),
    )
    fig.tight_layout(rect=(0, 0, 1, 0.84), w_pad=1.6)

    for suffix in [".pdf", ".svg", ".png"]:
        fig.savefig(output_base.with_suffix(suffix), bbox_inches="tight")
    plt.close(fig)


def copy_sources() -> None:
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    shutil.copy2(SOURCE_CSV, SOURCE_DIR / SOURCE_CSV.name)


def copy_to_figure_dir(output_base: Path) -> None:
    FIGURE_DIR.mkdir(parents=True, exist_ok=True)
    for suffix in [".pdf", ".svg", ".png"]:
        shutil.copy2(
            output_base.with_suffix(suffix),
            FIGURE_DIR / f"submission_eval_1_realworld_normalized_execution_time_promotions{suffix}",
        )


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    rows = read_rows()
    expected = len(LOCAL_SIZES) * len(WORKLOADS) * (len(DATA_POLICIES) + 1)
    if len(rows) != expected:
        raise RuntimeError(f"Expected {expected} selected rows, found {len(rows)}")
    write_selected_csv(rows, OUT_DIR / "eval_1_realworld_normalized_execution_time_promotions.csv")
    output_base = OUT_DIR / "eval_1_realworld_normalized_execution_time_promotions"
    plot(rows, output_base)
    copy_sources()
    copy_to_figure_dir(output_base)


if __name__ == "__main__":
    main()
