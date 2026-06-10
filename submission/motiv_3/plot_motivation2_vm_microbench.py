#!/usr/bin/env python3
import csv
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np


ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "source" / "placement_modes.csv"

LOCAL_MEM_GIB = "16"
MODE_ORDER = ["all_fast", "half_local", "all_slow"]
MODE_LABEL = {
    "all_fast": "all_fast",
    "half_local": "half_fast",
    "all_slow": "all_slow",
}
BAR_LABEL = {
    "off": "Migration off",
    "on": "Migration on",
}
BAR_COLOR = {
    "off": "#5b6573",
    "on": "#d07a35",
}


def load_rows():
    with SOURCE.open(newline="") as handle:
        rows = list(csv.DictReader(handle))
    selected = []
    by_mode = {}
    for row in rows:
        if row["local_mem_gib"] == LOCAL_MEM_GIB and row["mode"] in MODE_ORDER:
            row = dict(row)
            row["display_mode"] = MODE_LABEL[row["mode"]]
            by_mode[row["mode"]] = row
    missing = [mode for mode in MODE_ORDER if mode not in by_mode]
    if missing:
        raise RuntimeError(f"missing modes for local_mem_gib={LOCAL_MEM_GIB}: {missing}")
    for mode in MODE_ORDER:
        selected.append(by_mode[mode])
    return selected


def write_selected_csv(rows):
    fields = [
        "display_mode",
        "mode",
        "local_mem_gib",
        "placement_mode",
        "initial_local_hotset_gib",
        "initial_slow_hotset_gib",
        "initial_local_hotset_pct",
        "target_ops",
        "off_elapsed_s",
        "on_elapsed_s",
        "time_ratio_on_off",
        "off_mops",
        "on_mops",
        "throughput_ratio_on_off",
        "on_numa_hint_faults",
        "on_numa_pages_migrated",
        "on_migrated_gib",
        "on_pgdemote_total",
        "on_demoted_gib",
    ]
    out = ROOT / "motivation2_vm_microbench_selected.csv"
    with out.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: row.get(field, "") for field in fields})
    return out


def plot(rows):
    labels = [row["display_mode"] for row in rows]
    sublabels = [
        f"{float(row['initial_local_hotset_gib']):.0f}G fast / "
        f"{float(row['initial_slow_hotset_gib']):.0f}G slow"
        for row in rows
    ]
    x = np.arange(len(rows))
    width = 0.34
    off = np.array([float(row["off_elapsed_s"]) for row in rows])
    on = np.array([float(row["on_elapsed_s"]) for row in rows])
    ratio = np.array([float(row["time_ratio_on_off"]) for row in rows])

    fig, ax = plt.subplots(figsize=(7.8, 4.6))
    fig.subplots_adjust(left=0.105, right=0.99, top=0.84, bottom=0.23)

    b_off = ax.bar(x - width / 2, off, width, color=BAR_COLOR["off"], label=BAR_LABEL["off"])
    b_on = ax.bar(x + width / 2, on, width, color=BAR_COLOR["on"], label=BAR_LABEL["on"])

    ax.set_title("VM fixed-ops microbenchmark execution time", fontsize=13, pad=13)
    ax.set_ylabel("Execution time to target ops (s)")
    ax.set_xticks(x)
    ax.set_xticklabels(
        [f"{label}\n{sublabel}" for label, sublabel in zip(labels, sublabels)],
        fontsize=9,
    )
    ax.set_ylim(0, max(off.max(), on.max()) * 1.28)
    ax.grid(axis="y", linewidth=0.6, alpha=0.25)
    ax.set_axisbelow(True)
    ax.legend(loc="upper left", frameon=False, ncols=2)

    for bars in (b_off, b_on):
        for bar in bars:
            value = bar.get_height()
            ax.text(
                bar.get_x() + bar.get_width() / 2,
                value + ax.get_ylim()[1] * 0.018,
                f"{value:.1f}",
                ha="center",
                va="bottom",
                fontsize=8.5,
            )

    for idx, value in enumerate(ratio):
        ax.text(
            x[idx],
            max(off[idx], on[idx]) + ax.get_ylim()[1] * 0.105,
            f"on/off {value:.2f}x",
            ha="center",
            va="bottom",
            fontsize=9,
        )

    fig.text(
        0.105,
        0.055,
        "32 GiB active hotset, local memory = 16 GiB, target_ops = 43,686,414,250. Lower is better.",
        ha="left",
        fontsize=8.5,
        color="#4b5563",
    )

    for suffix in ("png", "pdf", "svg"):
        fig.savefig(ROOT / f"motivation2_vm_microbench_execution_time.{suffix}", dpi=220)
    plt.close(fig)


def write_readme(rows):
    csv_rows = "\n".join(
        [
            f"| {row['display_mode']} | {float(row['initial_local_hotset_gib']):.0f}G / "
            f"{float(row['initial_slow_hotset_gib']):.0f}G | "
            f"{float(row['off_elapsed_s']):.1f} | {float(row['on_elapsed_s']):.1f} | "
            f"{float(row['time_ratio_on_off']):.2f}x | "
            f"{float(row['off_mops']):.1f} | {float(row['on_mops']):.1f} |"
            for row in rows
        ]
    )
    (ROOT / "README.md").write_text(
        f"""# Motivation 3 Microbenchmark Figure

This directory packages the VM fixed-ops microbenchmark data from
`motivation/2_microbenchmark` for submission.

Source data:

- `source/placement_modes.csv`

Selection:

- `local_mem_gib = 16`
- modes: `all_fast`, `half_fast` (source row `half_local`), `all_slow`
- each x-axis group shows migration off/on execution time for the same target
  operation count

Generated artifacts:

- `motivation2_vm_microbench_selected.csv`
- `motivation2_vm_microbench_execution_time.{{png,pdf,svg}}`
- `plot_motivation2_vm_microbench.py`

The figure reports elapsed seconds to complete the fixed `target_ops`, so lower
is better. Throughput is retained in the selected CSV and shown below for
reference.

| Mode | Initial placement | Off s | On s | On/off time | Off Mops/s | On Mops/s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
{csv_rows}
"""
    )


def main():
    rows = load_rows()
    write_selected_csv(rows)
    plot(rows)
    write_readme(rows)


if __name__ == "__main__":
    main()
