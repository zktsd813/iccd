#!/usr/bin/env python3
"""Plot the resident-capacity quantile controller CSV."""

from __future__ import annotations

import argparse
import csv
from pathlib import Path
from typing import Iterable, Optional


PPM = 1_000_000


def optional_float(value: Optional[str]) -> float:
    if value in (None, ""):
        return float("nan")
    try:
        return float(value)
    except ValueError:
        return float("nan")


def load_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="ascii") as source:
        return list(csv.DictReader(source))


def sample_rows(rows: list[dict[str, str]]) -> list[dict[str, str]]:
    return [row for row in rows if row.get("event") not in {"start", "exit"}]


def import_matplotlib():
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    return plt


def save(fig, output_base: Path) -> None:
    output_base.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output_base.with_suffix(".svg"), bbox_inches="tight")
    fig.savefig(output_base.with_suffix(".pdf"), bbox_inches="tight")


def plot_policy(plt, rows: list[dict[str, str]], output_base: Path) -> None:
    samples = sample_rows(rows)
    if not samples:
        raise ValueError("controller CSV contains no policy samples")

    elapsed = [optional_float(row.get("elapsed_ms")) / 1000 for row in samples]
    local_p75 = [optional_float(row.get("local_p75_ns")) / 1e9 for row in samples]
    local_reference = [
        optional_float(row.get("p75_stagnation_reference_local_p75_ns")) / 1e9
        for row in samples
    ]
    remote_query_q = [
        optional_float(row.get("remote_query_q_ns")) / 1e9 for row in samples
    ]
    remote_reference = [
        optional_float(row.get("p75_stagnation_reference_remote_q_ns")) / 1e9
        for row in samples
    ]
    remote_lt = [
        optional_float(row.get("remote_cdf_lt_local_p75_ppm")) * 100 / PPM
        for row in samples
    ]
    remote_le = [
        optional_float(row.get("remote_cdf_le_local_p75_ppm")) * 100 / PPM
        for row in samples
    ]
    required = [
        optional_float(
            row.get("start_remote_quantile_rank_ppm")
            or row.get("remote_percentile_ppm")
        )
        * 100
        / PPM
        for row in samples
    ]
    stop_ratio = [optional_float(row.get("stop_capacity_ratio")) for row in samples]
    stop_threshold = [
        optional_float(row.get("stop_capacity_ratio_threshold")) for row in samples
    ]
    start_count = [optional_float(row.get("start_consecutive")) for row in samples]
    restart_count = [
        optional_float(row.get("p75_stagnation_forced_off_consecutive"))
        for row in samples
    ]
    migration_on = [1 if row.get("controller_state") == "on" else 0 for row in samples]

    fig, axes = plt.subplots(4, 1, figsize=(10, 9), sharex=True)
    p75_ax, capacity_ax, stop_ax, state_ax = axes

    p75_ax.plot(
        elapsed, local_p75, color="#31688E", linewidth=1.5, label="Local P75"
    )
    p75_ax.plot(
        elapsed,
        local_reference,
        color="#D95F02",
        linewidth=1.1,
        linestyle="--",
        label="Latched local reference",
    )
    p75_ax.plot(
        elapsed,
        remote_query_q,
        color="#21918C",
        linewidth=1.3,
        label="Remote fixed-rank query",
    )
    p75_ax.plot(
        elapsed,
        remote_reference,
        color="#7A5195",
        linewidth=1.1,
        linestyle="--",
        label="Latched remote reference",
    )
    p75_ax.set_ylabel("Fault latency (s)")
    p75_ax.set_title("Resident-capacity quantile controller")
    p75_ax.legend(frameon=False, ncol=2, fontsize=8, loc="best")

    capacity_ax.plot(
        elapsed,
        remote_lt,
        color="#21918C",
        linewidth=1.4,
        label="Remote share faster than local P75 (inverse query)",
    )
    capacity_ax.plot(
        elapsed,
        remote_le,
        color="#35B779",
        linewidth=1.2,
        label="Remote share no slower than local P75",
    )
    capacity_ax.plot(
        elapsed,
        required,
        color="#440154",
        linewidth=1.4,
        label="START remote latency rank (chosen by capacity)",
    )
    capacity_ax.axhline(100, color="#555555", linewidth=0.8, linestyle=":")
    capacity_ax.set_ylabel("Remote rank / CDF (%)")
    capacity_ax.legend(frameon=False, ncol=3, fontsize=8, loc="best")

    stop_ax.plot(
        elapsed,
        stop_ratio,
        color="#D95F02",
        linewidth=1.5,
        label="STOP capacity ratio",
    )
    stop_ax.plot(
        elapsed,
        stop_threshold,
        color="#333333",
        linewidth=1.0,
        linestyle="--",
        label="STOP threshold",
    )
    stop_ax.set_ylabel("STOP ratio")
    stop_ax.legend(frameon=False, loc="best")

    state_ax.step(
        elapsed,
        migration_on,
        where="post",
        color="#4C78A8",
        linewidth=1.6,
        label="Migration enabled",
    )
    state_ax.step(
        elapsed,
        start_count,
        where="post",
        color="#E45756",
        linewidth=1.3,
        label="START consecutive",
    )
    state_ax.step(
        elapsed,
        restart_count,
        where="post",
        color="#F2CF5B",
        linewidth=1.3,
        label="Joint restart consecutive",
    )
    state_ax.set_yticks((0, 1, 2, 3))
    state_ax.set_ylabel("State / count")
    state_ax.set_xlabel("Elapsed time (s)")
    state_ax.legend(frameon=False, ncol=3, loc="best")

    for axis in axes:
        axis.grid(axis="y", color="#dddddd", linewidth=0.6)
        axis.set_axisbelow(True)
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
    plot_policy(
        import_matplotlib(),
        rows,
        args.out_dir / f"{args.prefix}_policy",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
