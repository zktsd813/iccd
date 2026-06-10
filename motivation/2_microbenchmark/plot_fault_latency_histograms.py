#!/usr/bin/env python3
import argparse
import csv
import shutil
from pathlib import Path


BUCKET_LABELS = [
    "<=1",
    "<=16",
    "<=64",
    "<=128",
    "<=256",
    "<=512",
    "<=1024",
    "<=2048",
    "<=4096",
    "<=8192",
    ">8192",
]


def parse_histogram(path):
    data = {
        "window_seq": "",
        "local_pages": [0] * len(BUCKET_LABELS),
        "remote_pages": [0] * len(BUCKET_LABELS),
    }
    for line in path.read_text(errors="replace").splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "window_seq" and len(parts) >= 2:
            data["window_seq"] = parts[1]
        elif parts[0] in {"local_pages", "remote_pages"}:
            values = [int(value) for value in parts[1:]]
            values = values[: len(BUCKET_LABELS)]
            if len(values) < len(BUCKET_LABELS):
                values.extend([0] * (len(BUCKET_LABELS) - len(values)))
            data[parts[0]] = values
    return data


def load_cases(run_root):
    cases = {}
    for case in ("off", "on"):
        path = run_root / case / "after.fault_latency_histograms"
        if path.exists():
            cases[case] = parse_histogram(path)
    return cases


def write_csv(cases, output):
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow([
            "case",
            "bucket_ms",
            "local_pages",
            "remote_pages",
            "total_pages",
            "remote_percent",
        ])
        for case, data in cases.items():
            remote_total = sum(data["remote_pages"])
            for label, local, remote in zip(
                BUCKET_LABELS, data["local_pages"], data["remote_pages"]
            ):
                total = local + remote
                pct = remote * 100.0 / remote_total if remote_total else 0.0
                writer.writerow([case, label, local, remote, total, f"{pct:.6f}"])


def try_import_matplotlib():
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    return plt


def save_figure(fig, output_base, copy_dir=None):
    output_base.parent.mkdir(parents=True, exist_ok=True)
    svg = output_base.with_suffix(".svg")
    pdf = output_base.with_suffix(".pdf")
    fig.savefig(svg, bbox_inches="tight")
    fig.savefig(pdf, bbox_inches="tight")
    if copy_dir is not None:
        copy_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(svg, copy_dir / svg.name)
        shutil.copy2(pdf, copy_dir / pdf.name)


def annotate_bars(ax, bars, scale=1.0, fmt="{:.1f}"):
    ymax = max([bar.get_height() for bar in bars] + [0])
    if ymax <= 0:
        return
    pad = ymax * 0.025
    for bar in bars:
        value = bar.get_height()
        if value <= 0:
            continue
        ax.text(
            bar.get_x() + bar.get_width() / 2,
            value + pad,
            fmt.format(value / scale),
            ha="center",
            va="bottom",
            fontsize=7,
            rotation=90,
        )


def plot_case(plt, case, data, output_base, copy_dir=None):
    remote = data["remote_pages"]
    local = data["local_pages"]
    totals = [l + r for l, r in zip(local, remote)]
    remote_total = sum(remote)
    total_pages = sum(totals)
    x = list(range(len(BUCKET_LABELS)))

    fig, axes = plt.subplots(1, 2, figsize=(10.5, 3.8))
    fig.suptitle(f"NUMA hint fault latency histogram: migration {case}")

    ax = axes[0]
    remote_m = [value / 1_000_000 for value in remote]
    local_m = [value / 1_000_000 for value in local]
    bars_remote = ax.bar(
        x,
        remote_m,
        label="remote pages",
        color="#E45756",
        edgecolor="#222222",
        linewidth=0.5,
    )
    if any(local):
        ax.bar(
            x,
            local_m,
            bottom=remote_m,
            label="local pages",
            color="#4C78A8",
            edgecolor="#222222",
            linewidth=0.5,
        )
    annotate_bars(ax, bars_remote)
    ax.set_ylabel("Pages (million)")
    ax.set_xlabel("Latency bucket (ms)")
    ax.set_xticks(x)
    ax.set_xticklabels(BUCKET_LABELS, rotation=35, ha="right")
    ax.grid(axis="y", color="#dddddd", linewidth=0.6)
    ax.set_axisbelow(True)
    ax.legend(fontsize=8)
    if total_pages == 0:
        ax.text(
            0.5,
            0.55,
            "no samples",
            transform=ax.transAxes,
            ha="center",
            va="center",
            fontsize=12,
            color="#555555",
        )

    ax = axes[1]
    pct = [value * 100.0 / remote_total if remote_total else 0.0 for value in remote]
    bars = ax.bar(
        x,
        pct,
        color="#72B7B2",
        edgecolor="#222222",
        linewidth=0.5,
    )
    annotate_bars(ax, bars, fmt="{:.1f}%")
    ax.set_ylabel("Remote pages (%)")
    ax.set_xlabel("Latency bucket (ms)")
    ax.set_xticks(x)
    ax.set_xticklabels(BUCKET_LABELS, rotation=35, ha="right")
    ax.grid(axis="y", color="#dddddd", linewidth=0.6)
    ax.set_axisbelow(True)
    if remote_total == 0:
        ax.text(
            0.5,
            0.55,
            "no remote samples",
            transform=ax.transAxes,
            ha="center",
            va="center",
            fontsize=12,
            color="#555555",
        )

    fig.text(
        0.5,
        0.01,
        f"window_seq={data['window_seq'] or 'NA'}, total_pages={total_pages:,}, "
        f"remote_pages={remote_total:,}; demotion/migrate counters are not counted here",
        ha="center",
        fontsize=8,
        color="#333333",
    )
    fig.tight_layout(rect=(0, 0.04, 1, 0.95))
    save_figure(fig, output_base, copy_dir)
    plt.close(fig)


def plot_compare(plt, cases, output_base, copy_dir=None):
    x = list(range(len(BUCKET_LABELS)))
    width = 0.36
    fig, ax = plt.subplots(figsize=(8.2, 3.8))
    colors = {"off": "#4C78A8", "on": "#E45756"}
    for idx, case in enumerate(("off", "on")):
        if case not in cases:
            continue
        remote = cases[case]["remote_pages"]
        remote_total = sum(remote)
        pct = [value * 100.0 / remote_total if remote_total else 0.0 for value in remote]
        offset = -width / 2 if case == "off" else width / 2
        ax.bar(
            [pos + offset for pos in x],
            pct,
            width,
            label=f"migration {case}",
            color=colors[case],
            edgecolor="#222222",
            linewidth=0.5,
        )
    ax.set_title("Remote NUMA hint fault latency distribution")
    ax.set_ylabel("Remote pages (%)")
    ax.set_xlabel("Latency bucket (ms)")
    ax.set_xticks(x)
    ax.set_xticklabels(BUCKET_LABELS, rotation=35, ha="right")
    ax.grid(axis="y", color="#dddddd", linewidth=0.6)
    ax.set_axisbelow(True)
    ax.legend(fontsize=8)
    fig.tight_layout()
    save_figure(fig, output_base, copy_dir)
    plt.close(fig)


def plot_on_local_remote(plt, data, output_base, copy_dir=None):
    local = data["local_pages"]
    remote = data["remote_pages"]
    local_total = sum(local)
    remote_total = sum(remote)
    x = list(range(len(BUCKET_LABELS)))

    fig, axes = plt.subplots(1, 2, figsize=(10.5, 3.8), sharey=False)
    fig.suptitle("NUMA hint fault latency histogram: migration on")

    for ax, label, values, color, total in (
        (axes[0], "local pages", local, "#4C78A8", local_total),
        (axes[1], "remote pages", remote, "#E45756", remote_total),
    ):
        values_m = [value / 1_000_000 for value in values]
        bars = ax.bar(
            x,
            values_m,
            color=color,
            edgecolor="#222222",
            linewidth=0.5,
        )
        annotate_bars(ax, bars)
        ax.set_title(f"{label} (total={total:,})")
        ax.set_xlabel("Latency bucket (ms)")
        ax.set_ylabel("Pages (million)")
        ax.set_xticks(x)
        ax.set_xticklabels(BUCKET_LABELS, rotation=35, ha="right")
        ax.grid(axis="y", color="#dddddd", linewidth=0.6)
        ax.set_axisbelow(True)
        if total == 0:
            ax.text(
                0.5,
                0.55,
                "no samples in this run",
                transform=ax.transAxes,
                ha="center",
                va="center",
                fontsize=11,
                color="#555555",
            )

    fig.text(
        0.5,
        0.01,
        f"window_seq={data['window_seq'] or 'NA'}; local_total={local_total:,}; remote_total={remote_total:,}",
        ha="center",
        fontsize=8,
        color="#333333",
    )
    fig.tight_layout(rect=(0, 0.04, 1, 0.95))
    save_figure(fig, output_base, copy_dir)
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "run_root",
        type=Path,
        help="Guest result root containing off/on after.fault_latency_histograms",
    )
    parser.add_argument("--figure-dir", type=Path, required=True)
    parser.add_argument("--copy-dir", type=Path)
    parser.add_argument("--csv", type=Path)
    args = parser.parse_args()

    cases = load_cases(args.run_root)
    if not cases:
        raise SystemExit(f"no histogram files found under {args.run_root}")

    if args.csv:
        write_csv(cases, args.csv)

    plt = try_import_matplotlib()
    for case, data in cases.items():
        plot_case(
            plt,
            case,
            data,
            args.figure_dir / f"fault_latency_histogram_{case}",
            args.copy_dir,
        )
    plot_compare(
        plt,
        cases,
        args.figure_dir / "fault_latency_histogram_compare",
        args.copy_dir,
    )
    if "on" in cases:
        plot_on_local_remote(
            plt,
            cases["on"],
            args.figure_dir / "fault_latency_histogram_on_local_remote",
            args.copy_dir,
        )


if __name__ == "__main__":
    main()
