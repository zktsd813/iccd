#!/usr/bin/env python3
import argparse
import csv
import shutil
from pathlib import Path


MODE_LABELS = {
    "all_fast": "all fast",
    "all_slow": "all slow",
    "half_local": "half local",
}


def to_float(value, default=0.0):
    try:
        text = str(value).strip().replace(",", "")
        if text == "":
            return default
        return float(text)
    except (TypeError, ValueError):
        return default


def read_csv(path):
    if not path.exists():
        return []
    with path.open(newline="", errors="replace") as f:
        return list(csv.DictReader(f))


def normalize_all_fast(rows):
    normalized = []
    for row in rows:
        local_gib = to_float(row.get("local_mem_gib"))
        out = dict(row)
        out["mode"] = "all_fast"
        out["mode_label"] = MODE_LABELS["all_fast"]
        out["placement_mode"] = "window-split"
        out["initial_local_hotset_gib"] = min(local_gib, 32.0)
        out["initial_slow_hotset_gib"] = max(0.0, 32.0 - local_gib)
        out["initial_local_hotset_pct"] = min(local_gib, 32.0) / 32.0 * 100.0
        normalized.append(out)
    return normalized


def normalize_interleave(rows):
    normalized = []
    for row in rows:
        mode = row.get("mode", "")
        if mode not in {"all_slow", "half_local"}:
            continue
        out = dict(row)
        out["mode_label"] = MODE_LABELS.get(mode, mode)
        normalized.append(out)
    return normalized


def write_csv(rows, output):
    if not rows:
        return
    fields = [
        "mode",
        "mode_label",
        "local_mem_gib",
        "case_dir",
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
        "on_user_cpu_s",
        "on_system_cpu_s",
        "on_numa_hint_faults",
        "on_numa_pages_migrated",
        "on_migrated_gib",
        "on_pgdemote_total",
        "on_demoted_gib",
        "on_memory_psi_some_s",
        "on_memory_psi_full_s",
    ]
    with output.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def try_import_matplotlib():
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt

        return plt
    except Exception:
        return None


def save_figure(fig, output_base, copy_dir=None):
    svg = output_base.with_suffix(".svg")
    pdf = output_base.with_suffix(".pdf")
    fig.savefig(svg, bbox_inches="tight")
    fig.savefig(pdf, bbox_inches="tight")
    if copy_dir is not None:
        copy_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(svg, copy_dir / svg.name)
        shutil.copy2(pdf, copy_dir / pdf.name)


def mode_sort_key(row):
    return to_float(row.get("local_mem_gib"))


def group_by_mode(rows):
    grouped = {}
    for row in rows:
        grouped.setdefault(row["mode"], []).append(row)
    for mode_rows in grouped.values():
        mode_rows.sort(key=mode_sort_key)
    return grouped


def annotate_points(ax, xs, values, suffix="", ypad=0.0):
    for x, value in zip(xs, values):
        ax.text(x, value + ypad, f"{value:.2f}{suffix}", ha="center",
                va="bottom", fontsize=7)


def write_mode_figure(plt, mode, rows, figure_dir, copy_dir=None):
    label = MODE_LABELS.get(mode, mode)
    xs = [to_float(row["local_mem_gib"]) for row in rows]
    pos = list(range(len(xs)))
    width = 0.36

    fig, axes = plt.subplots(2, 2, figsize=(9.2, 6.2))
    fig.suptitle(f"{label}: 32-thread shared-window fixed-op sweep")

    ax = axes[0][0]
    off_elapsed = [to_float(row.get("off_elapsed_s")) for row in rows]
    on_elapsed = [to_float(row.get("on_elapsed_s")) for row in rows]
    ax.bar([x - width / 2 for x in pos], off_elapsed, width, label="migration off",
           color="#4C78A8", edgecolor="#222222", linewidth=0.5)
    ax.bar([x + width / 2 for x in pos], on_elapsed, width, label="migration on",
           color="#F58518", edgecolor="#222222", linewidth=0.5)
    ax.set_ylabel("Execution time (s)")
    ax.set_title("Fixed operations")
    ax.grid(axis="y", color="#dddddd", linewidth=0.6)
    ax.set_axisbelow(True)
    ax.legend(fontsize=8)

    ax = axes[0][1]
    ratios = [to_float(row.get("time_ratio_on_off")) for row in rows]
    ax.plot(pos, ratios, marker="o", linewidth=2.0, color="#E45756")
    ax.axhline(1.0, color="#333333", linestyle="--", linewidth=0.8)
    annotate_points(ax, pos, ratios, "x", 0.03)
    ax.set_ylabel("On / off time")
    ax.set_title("Migration impact")
    ax.grid(axis="y", color="#dddddd", linewidth=0.6)
    ax.set_axisbelow(True)

    ax = axes[1][0]
    migrated = [to_float(row.get("on_migrated_gib")) for row in rows]
    demoted = [to_float(row.get("on_demoted_gib")) for row in rows]
    ax.bar([x - width / 2 for x in pos], migrated, width, label="migrated",
           color="#72B7B2", edgecolor="#222222", linewidth=0.5)
    ax.bar([x + width / 2 for x in pos], demoted, width, label="demoted",
           color="#B279A2", edgecolor="#222222", linewidth=0.5)
    ax.set_xlabel("Local memory size (GiB)")
    ax.set_ylabel("GiB")
    ax.set_title("Migration activity")
    ax.grid(axis="y", color="#dddddd", linewidth=0.6)
    ax.set_axisbelow(True)
    ax.legend(fontsize=8)

    ax = axes[1][1]
    hint_faults_m = [to_float(row.get("on_numa_hint_faults")) / 1_000_000.0
                     for row in rows]
    system_cpu = [to_float(row.get("on_system_cpu_s")) for row in rows]
    bars = ax.bar(pos, hint_faults_m, width=0.58, color="#54A24B",
                  alpha=0.78, label="hint faults")
    ax.set_xlabel("Local memory size (GiB)")
    ax.set_ylabel("Hint faults (M)")
    ax.set_title("Kernel activity")
    ax.grid(axis="y", color="#dddddd", linewidth=0.6)
    ax.set_axisbelow(True)
    ax2 = ax.twinx()
    line = ax2.plot(pos, system_cpu, marker="o", linewidth=2.0,
                    color="#FF9DA6", label="system CPU s")
    ax2.set_ylabel("System CPU time (s)")
    ax.legend([bars, line[0]], ["hint faults", "system CPU s"], fontsize=8,
              loc="best")

    for ax in axes.flatten():
        ax.set_xticks(pos)
        ax.set_xticklabels([str(int(x)) for x in xs])

    fig.tight_layout()
    save_figure(fig, figure_dir / f"placement_{mode}", copy_dir)
    plt.close(fig)


def write_figures(rows, figure_dir, copy_dir=None):
    plt = try_import_matplotlib()
    if plt is None:
        raise SystemExit("matplotlib is required to write placement figures")
    grouped = group_by_mode(rows)
    for mode in ("all_fast", "all_slow", "half_local"):
        mode_rows = grouped.get(mode, [])
        if mode_rows:
            write_mode_figure(plt, mode, mode_rows, figure_dir, copy_dir)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--varying-local-csv", type=Path,
                        default=Path("motivation/2_microbenchmark/varying_local/local_mem_sweep.csv"))
    parser.add_argument("--interleave-csv", type=Path,
                        default=Path("motivation/2_microbenchmark/interleave/interleave_sweep.csv"))
    parser.add_argument("--output-csv", type=Path,
                        default=Path("motivation/2_microbenchmark/interleave/placement_modes.csv"))
    parser.add_argument("--figure-dir", type=Path,
                        default=Path("motivation/2_microbenchmark/interleave/figures"))
    parser.add_argument("--copy-dir", type=Path,
                        default=Path("motivation/2_microbenchmark/figure"))
    args = parser.parse_args()

    rows = []
    rows.extend(normalize_all_fast(read_csv(args.varying_local_csv)))
    rows.extend(normalize_interleave(read_csv(args.interleave_csv)))
    rows.sort(key=lambda row: (
        {"all_fast": 0, "all_slow": 1, "half_local": 2}.get(row["mode"], 99),
        mode_sort_key(row),
    ))

    args.output_csv.parent.mkdir(parents=True, exist_ok=True)
    args.figure_dir.mkdir(parents=True, exist_ok=True)
    write_csv(rows, args.output_csv)
    write_figures(rows, args.figure_dir, args.copy_dir)


if __name__ == "__main__":
    main()
