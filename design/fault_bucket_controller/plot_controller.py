#!/usr/bin/env python3
"""Plot fault bucket controller decisions from controller.csv."""

from __future__ import annotations

import argparse
import csv
from pathlib import Path
from typing import Iterable, Optional


BUCKET_LABELS = (
    "<=128",
    "<=256",
    "<=512",
    "<=1024",
    "<=2048",
    "<=4096",
    "<=8192",
    ">8192",
)


def to_int(value: str, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def to_float(value: str, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def load_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="ascii") as f:
        return list(csv.DictReader(f))


def try_import_matplotlib():
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    return plt


def save(fig, output_base: Path) -> None:
    output_base.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output_base.with_suffix(".svg"), bbox_inches="tight")
    fig.savefig(output_base.with_suffix(".pdf"), bbox_inches="tight")


def plot_buckets(plt, rows: list[dict[str, str]], output_base: Path) -> None:
    samples = [row for row in rows if row.get("event") not in {"start", "exit"}]
    x = [to_float(row.get("elapsed_ms", "0")) / 1000.0 for row in samples]
    local = [to_int(row.get("local_p80_bucket_index", "-1"), -1) for row in samples]
    remote = [to_int(row.get("remote_p20_bucket_index", "-1"), -1) for row in samples]
    states = [row.get("controller_state", "") for row in samples]

    fig, ax = plt.subplots(figsize=(8.2, 3.8))
    ax.plot(x, local, marker="o", linewidth=1.4, markersize=3.8, label="local P80")
    ax.plot(x, remote, marker="s", linewidth=1.4, markersize=3.8, label="remote P20")
    for xpos, state in zip(x, states):
        if state == "off":
            ax.axvline(xpos, color="#D62728", linewidth=0.7, alpha=0.18)
            break
    ax.set_title("Fault latency bucket controller")
    ax.set_xlabel("Elapsed time (s)")
    ax.set_ylabel("Bucket index")
    ax.set_yticks(range(len(BUCKET_LABELS)))
    ax.set_yticklabels(BUCKET_LABELS)
    ax.grid(axis="y", color="#dddddd", linewidth=0.6)
    ax.set_axisbelow(True)
    ax.legend(frameon=False)
    fig.tight_layout()
    save(fig, output_base)
    plt.close(fig)


def plot_gap(plt, rows: list[dict[str, str]], output_base: Path) -> None:
    samples = [row for row in rows if row.get("event") not in {"start", "exit"}]
    x = [to_float(row.get("elapsed_ms", "0")) / 1000.0 for row in samples]
    gap = [
        float("nan") if row.get("gap", "") == "" else to_float(row.get("gap", "0"))
        for row in samples
    ]
    effective = [to_int(row.get("effective_consecutive", "0")) for row in samples]
    no_improve = [to_int(row.get("no_improve_consecutive", "0")) for row in samples]

    fig, ax1 = plt.subplots(figsize=(8.2, 3.8))
    ax1.plot(x, gap, marker="o", linewidth=1.4, markersize=3.8, color="#4C78A8", label="gap")
    ax1.axhline(0, color="#222222", linewidth=0.8, alpha=0.5)
    ax1.set_title("Controller gap and consecutive counters")
    ax1.set_xlabel("Elapsed time (s)")
    ax1.set_ylabel("gap = local P80 index - remote P20 index")
    ax1.grid(axis="y", color="#dddddd", linewidth=0.6)
    ax1.set_axisbelow(True)

    ax2 = ax1.twinx()
    ax2.step(x, effective, where="post", color="#54A24B", linewidth=1.2, label="effective count")
    ax2.step(x, no_improve, where="post", color="#E45756", linewidth=1.2, label="no-improve count")
    ax2.set_ylabel("Consecutive count")

    handles1, labels1 = ax1.get_legend_handles_labels()
    handles2, labels2 = ax2.get_legend_handles_labels()
    ax1.legend(handles1 + handles2, labels1 + labels2, frameon=False, loc="best")
    fig.tight_layout()
    save(fig, output_base)
    plt.close(fig)


def main(argv: Optional[Iterable[str]] = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("controller_csv", type=Path)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--prefix", default="fault_bucket_controller")
    args = parser.parse_args(argv)

    rows = load_rows(args.controller_csv)
    if not rows:
        raise SystemExit(f"empty controller CSV: {args.controller_csv}")

    plt = try_import_matplotlib()
    plot_buckets(plt, rows, args.out_dir / f"{args.prefix}_bucket_indices")
    plot_gap(plt, rows, args.out_dir / f"{args.prefix}_gap_counts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
