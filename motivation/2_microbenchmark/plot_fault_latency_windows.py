#!/usr/bin/env python3
import argparse
import csv
import shutil
from pathlib import Path


BUCKET_LABELS = [
    "<=128",
    "<=256",
    "<=512",
    "<=1024",
    "<=2048",
    "<=4096",
    "<=8192",
    ">8192",
]

SERIES_KEYS = [
    "local_pages",
    "local_large_vma_pages",
    "local_small_vma_pages",
    "remote_pages",
]


SERIES_LABELS = {
    "local_pages": "local",
    "local_large_vma_pages": "local large VMA",
    "local_small_vma_pages": "local small VMA",
    "remote_pages": "remote",
}


def parse_key_values(path):
    values = {}
    if not path.exists():
        return values
    for line in path.read_text(errors="replace").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
        else:
            parts = line.split(None, 1)
            if len(parts) == 2:
                values[parts[0]] = parts[1].strip()
    return values


def parse_histogram(path):
    data = {key: [0] * len(BUCKET_LABELS) for key in SERIES_KEYS}
    data["window_seq"] = ""
    for line in path.read_text(errors="replace").splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "window_seq" and len(parts) >= 2:
            data["window_seq"] = parts[1]
        elif parts[0] in SERIES_KEYS:
            values = [int(value) for value in parts[1:]]
            data[parts[0]] = values[: len(BUCKET_LABELS)]
    return data


def load_windows(window_dir):
    rows = []
    for hist_path in sorted(window_dir.glob("window_*.fault_latency_histograms")):
        stem = hist_path.name.removesuffix(".fault_latency_histograms")
        index = int(stem.split("_", 1)[1])
        meta = parse_key_values(window_dir / f"{stem}.meta")
        data = parse_histogram(hist_path)
        rows.append(
            {
                "index": index,
                "elapsed_ms": int(meta.get("elapsed_ms", "0") or 0),
                "window_seq": data.get("window_seq", ""),
                **{key: data[key] for key in SERIES_KEYS},
            }
        )
    return rows


def infer_window_label(window_dir, rows):
    monitor = parse_key_values(window_dir / "monitor.meta")
    interval = monitor.get("interval_s")
    if interval:
        return f"{interval}s"
    deltas = [
        rows[index]["elapsed_ms"] - rows[index - 1]["elapsed_ms"]
        for index in range(1, len(rows))
        if rows[index]["elapsed_ms"] > rows[index - 1]["elapsed_ms"]
    ]
    if deltas:
        median_ms = sorted(deltas)[len(deltas) // 2]
        if median_ms % 1000 == 0:
            return f"{median_ms // 1000}s"
        return f"{median_ms / 1000.0:.1f}s"
    return "window"


def choose_local_series(rows):
    large_total = sum(sum(row["local_large_vma_pages"]) for row in rows)
    if large_total:
        return "local_large_vma_pages"
    return "local_pages"


def write_csv(rows, output):
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(
            [
                "window_index",
                "elapsed_ms",
                "series",
                "bucket_ms",
                "pages",
                "series_total_pages",
                "series_percent",
            ]
        )
        for row in rows:
            for series in SERIES_KEYS:
                values = row[series]
                total = sum(values)
                for label, pages in zip(BUCKET_LABELS, values):
                    pct = pages * 100.0 / total if total else 0.0
                    writer.writerow(
                        [
                            row["index"],
                            row["elapsed_ms"],
                            series,
                            label,
                            pages,
                            total,
                            f"{pct:.6f}",
                        ]
                    )


def percentile_bucket(values, percentile):
    total = sum(values)
    if total <= 0:
        return -1, "NA"
    threshold = total * percentile / 100.0
    cumulative = 0
    for index, value in enumerate(values):
        cumulative += value
        if cumulative >= threshold:
            return index, BUCKET_LABELS[index]
    return len(values) - 1, BUCKET_LABELS[-1]


def write_percentile_csv(rows, output, local_series):
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(
            [
                "window_index",
                "elapsed_ms",
                "local_series",
                "local_total_pages",
                "local_p80_bucket_index",
                "local_p80_bucket_ms",
                "remote_series",
                "remote_total_pages",
                "remote_p20_bucket_index",
                "remote_p20_bucket_ms",
            ]
        )
        for row in rows:
            local_values = row[local_series]
            remote_values = row["remote_pages"]
            local_index, local_label = percentile_bucket(local_values, 80)
            remote_index, remote_label = percentile_bucket(remote_values, 20)
            writer.writerow(
                [
                    row["index"],
                    row["elapsed_ms"],
                    local_series,
                    sum(local_values),
                    local_index,
                    local_label,
                    "remote_pages",
                    sum(remote_values),
                    remote_index,
                    remote_label,
                ]
            )


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


def plot_heatmap(plt, rows, series, title, output_base, copy_dir=None):
    matrix = []
    ylabels = []
    for row in rows:
        values = row[series]
        total = sum(values)
        matrix.append([value * 100.0 / total if total else 0.0 for value in values])
        ylabels.append(f"{row['elapsed_ms'] / 1000.0:.0f}s")

    fig, ax = plt.subplots(figsize=(8.4, max(3.6, len(rows) * 0.28)))
    image = ax.imshow(matrix, aspect="auto", cmap="viridis", vmin=0, vmax=100)
    ax.set_title(title)
    ax.set_xlabel("Latency bucket (ms)")
    ax.set_ylabel("Window end time")
    ax.set_xticks(range(len(BUCKET_LABELS)))
    ax.set_xticklabels(BUCKET_LABELS, rotation=35, ha="right")
    ax.set_yticks(range(len(ylabels)))
    ax.set_yticklabels(ylabels)
    cbar = fig.colorbar(image, ax=ax)
    cbar.set_label("Window distribution (%)")
    fig.tight_layout()
    save_figure(fig, output_base, copy_dir)
    plt.close(fig)


def plot_gt8192(plt, rows, window_label, output_base, copy_dir=None):
    x = [row["elapsed_ms"] / 1000.0 for row in rows]
    fig, ax1 = plt.subplots(figsize=(8.2, 3.8))

    for series, label, color in (
        ("local_large_vma_pages", "local large VMA >8192ms", "#4C78A8"),
        ("local_pages", "local all >8192ms", "#72B7B2"),
        ("remote_pages", "remote >8192ms", "#E45756"),
    ):
        pct = []
        for row in rows:
            values = row[series]
            total = sum(values)
            pct.append(values[-1] * 100.0 / total if total else 0.0)
        ax1.plot(x, pct, marker="o", linewidth=1.4, markersize=3.5,
                 label=label, color=color)

    ax1.set_title(f"Fault latency tail by {window_label} window")
    ax1.set_xlabel("Window end time (s)")
    ax1.set_ylabel(">8192ms pages (%)")
    ax1.grid(axis="y", color="#dddddd", linewidth=0.6)
    ax1.set_axisbelow(True)
    ax1.legend(fontsize=8)
    fig.tight_layout()
    save_figure(fig, output_base, copy_dir)
    plt.close(fig)


def plot_counts(plt, rows, output_base, copy_dir=None):
    x = [row["elapsed_ms"] / 1000.0 for row in rows]
    fig, ax = plt.subplots(figsize=(8.2, 3.8))
    plot_series = [
        ("local_pages", "local", "#4C78A8"),
        ("remote_pages", "remote", "#E45756"),
    ]
    if sum(sum(row["local_large_vma_pages"]) for row in rows):
        plot_series.append(("local_large_vma_pages", "local large VMA", "#72B7B2"))
    if sum(sum(row["local_small_vma_pages"]) for row in rows):
        plot_series.append(("local_small_vma_pages", "local small VMA", "#F58518"))

    for series, label, color in plot_series:
        totals = [sum(row[series]) / 1_000_000.0 for row in rows]
        ax.plot(x, totals, marker="o", linewidth=1.4, markersize=3.5,
                label=label, color=color)
    ax.set_title("Fault samples by window")
    ax.set_xlabel("Window end time (s)")
    ax.set_ylabel("Pages (million)")
    ax.grid(axis="y", color="#dddddd", linewidth=0.6)
    ax.set_axisbelow(True)
    ax.legend(fontsize=8)
    fig.tight_layout()
    save_figure(fig, output_base, copy_dir)
    plt.close(fig)


def plot_histogram_facets(plt, rows, series, title, output_base, copy_dir=None):
    cols = 5
    rows_count = (len(rows) + cols - 1) // cols
    fig, axes = plt.subplots(
        rows_count,
        cols,
        figsize=(cols * 2.55, rows_count * 1.85),
        sharex=True,
        sharey=True,
    )
    axes_flat = axes.ravel() if hasattr(axes, "ravel") else [axes]
    x = list(range(len(BUCKET_LABELS)))

    for ax, row in zip(axes_flat, rows):
        values = row[series]
        total = sum(values)
        pct = [value * 100.0 / total if total else 0.0 for value in values]
        ax.bar(
            x,
            pct,
            color="#4C78A8" if series.startswith("local") else "#E45756",
            edgecolor="#222222",
            linewidth=0.35,
        )
        ax.set_ylim(0, 100)
        ax.set_title(
            f"w{row['index']:02d} {row['elapsed_ms'] / 1000.0:.0f}s\nn={total:,}",
            fontsize=7,
        )
        ax.grid(axis="y", color="#dddddd", linewidth=0.4)
        ax.set_axisbelow(True)
        ax.tick_params(axis="both", labelsize=6, length=2)

    for ax in axes_flat[len(rows):]:
        ax.axis("off")

    for ax in axes_flat[-cols:]:
        if ax.has_data():
            ax.set_xticks(x)
            ax.set_xticklabels(BUCKET_LABELS, rotation=55, ha="right", fontsize=6)

    for row_idx in range(rows_count):
        ax = axes_flat[row_idx * cols]
        if ax.has_data():
            ax.set_ylabel("%", fontsize=7)

    fig.suptitle(title, fontsize=12)
    fig.tight_layout(rect=(0, 0, 1, 0.985))
    save_figure(fig, output_base, copy_dir)
    plt.close(fig)


def plot_local_remote_histogram_facets(
    plt, rows, local_series, title, output_base, copy_dir=None
):
    cols = 4
    rows_count = (len(rows) + cols - 1) // cols
    fig, axes = plt.subplots(
        rows_count,
        cols,
        figsize=(cols * 3.15, rows_count * 2.05),
        sharex=True,
        sharey=True,
    )
    axes_flat = axes.ravel() if hasattr(axes, "ravel") else [axes]
    x = list(range(len(BUCKET_LABELS)))
    width = 0.38

    for ax, row in zip(axes_flat, rows):
        local_values = row[local_series]
        remote_values = row["remote_pages"]
        local_total = sum(local_values)
        remote_total = sum(remote_values)
        local_pct = [
            value * 100.0 / local_total if local_total else 0.0
            for value in local_values
        ]
        remote_pct = [
            value * 100.0 / remote_total if remote_total else 0.0
            for value in remote_values
        ]

        ax.bar(
            [pos - width / 2 for pos in x],
            local_pct,
            width=width,
            color="#4C78A8",
            edgecolor="#222222",
            linewidth=0.3,
            label=SERIES_LABELS[local_series],
        )
        ax.bar(
            [pos + width / 2 for pos in x],
            remote_pct,
            width=width,
            color="#E45756",
            edgecolor="#222222",
            linewidth=0.3,
            label="remote",
        )
        ax.set_ylim(0, 100)
        ax.set_title(
            f"w{row['index']:02d} {row['elapsed_ms'] / 1000.0:.0f}s\n"
            f"L={local_total:,} R={remote_total:,}",
            fontsize=7,
        )
        ax.grid(axis="y", color="#dddddd", linewidth=0.4)
        ax.set_axisbelow(True)
        ax.tick_params(axis="both", labelsize=6, length=2)

    for ax in axes_flat[len(rows):]:
        ax.axis("off")

    for ax in axes_flat[-cols:]:
        if ax.has_data():
            ax.set_xticks(x)
            ax.set_xticklabels(BUCKET_LABELS, rotation=55, ha="right", fontsize=6)

    for row_idx in range(rows_count):
        ax = axes_flat[row_idx * cols]
        if ax.has_data():
            ax.set_ylabel("%", fontsize=7)

    handles, labels = axes_flat[0].get_legend_handles_labels()
    fig.legend(
        handles,
        labels,
        loc="upper center",
        ncol=2,
        fontsize=8,
        frameon=False,
        bbox_to_anchor=(0.5, 0.995),
    )
    fig.suptitle(title, fontsize=12, y=1.0)
    fig.tight_layout(rect=(0, 0, 1, 0.985))
    save_figure(fig, output_base, copy_dir)
    plt.close(fig)


def plot_local_remote_percentile_facets(
    plt, rows, local_series, title, output_base, copy_dir=None
):
    from matplotlib.lines import Line2D
    from matplotlib.patches import Patch

    cols = 4
    rows_count = (len(rows) + cols - 1) // cols
    fig, axes = plt.subplots(
        rows_count,
        cols,
        figsize=(cols * 3.2, rows_count * 2.2),
        sharex=True,
        sharey=True,
    )
    axes_flat = axes.ravel() if hasattr(axes, "ravel") else [axes]
    x = list(range(len(BUCKET_LABELS)))
    width = 0.38

    for ax, row in zip(axes_flat, rows):
        local_values = row[local_series]
        remote_values = row["remote_pages"]
        local_total = sum(local_values)
        remote_total = sum(remote_values)
        local_pct = [
            value * 100.0 / local_total if local_total else 0.0
            for value in local_values
        ]
        remote_pct = [
            value * 100.0 / remote_total if remote_total else 0.0
            for value in remote_values
        ]
        local_p80_index, local_p80_label = percentile_bucket(local_values, 80)
        remote_p20_index, remote_p20_label = percentile_bucket(remote_values, 20)

        ax.bar(
            [pos - width / 2 for pos in x],
            local_pct,
            width=width,
            color="#4C78A8",
            edgecolor="#222222",
            linewidth=0.3,
            label=SERIES_LABELS[local_series],
        )
        ax.bar(
            [pos + width / 2 for pos in x],
            remote_pct,
            width=width,
            color="#E45756",
            edgecolor="#222222",
            linewidth=0.3,
            label="remote",
        )
        if local_p80_index >= 0:
            ax.axvline(
                local_p80_index - width / 2,
                color="#1F4E79",
                linestyle=":",
                linewidth=0.75,
                alpha=0.65,
            )
            ax.scatter(
                [local_p80_index - width / 2],
                [96],
                marker="v",
                s=22,
                color="#1F4E79",
                edgecolor="white",
                linewidth=0.35,
                zorder=5,
                label="local P80 bucket",
            )
        if remote_p20_index >= 0:
            ax.axvline(
                remote_p20_index + width / 2,
                color="#B13A3A",
                linestyle=":",
                linewidth=0.75,
                alpha=0.65,
            )
            ax.scatter(
                [remote_p20_index + width / 2],
                [88],
                marker="^",
                s=22,
                color="#B13A3A",
                edgecolor="white",
                linewidth=0.35,
                zorder=5,
                label="remote P20 bucket",
            )
        ax.set_ylim(0, 100)
        ax.set_title(
            f"w{row['index']:02d} {row['elapsed_ms'] / 1000.0:.0f}s\n"
            f"L80={local_p80_label} R20={remote_p20_label}\n"
            f"L={local_total:,} R={remote_total:,}",
            fontsize=6.5,
        )
        ax.grid(axis="y", color="#dddddd", linewidth=0.4)
        ax.set_axisbelow(True)
        ax.tick_params(axis="both", labelsize=6, length=2)

    for ax in axes_flat[len(rows):]:
        ax.axis("off")

    for ax in axes_flat[-cols:]:
        if ax.has_data():
            ax.set_xticks(x)
            ax.set_xticklabels(BUCKET_LABELS, rotation=55, ha="right", fontsize=6)

    for row_idx in range(rows_count):
        ax = axes_flat[row_idx * cols]
        if ax.has_data():
            ax.set_ylabel("%", fontsize=7)

    handles = [
        Patch(facecolor="#4C78A8", edgecolor="#222222", label=SERIES_LABELS[local_series]),
        Patch(facecolor="#E45756", edgecolor="#222222", label="remote"),
        Line2D(
            [0],
            [0],
            marker="v",
            linestyle=":",
            color="#1F4E79",
            markerfacecolor="#1F4E79",
            markeredgecolor="white",
            label="local P80 bucket",
        ),
        Line2D(
            [0],
            [0],
            marker="^",
            linestyle=":",
            color="#B13A3A",
            markerfacecolor="#B13A3A",
            markeredgecolor="white",
            label="remote P20 bucket",
        ),
    ]
    fig.legend(
        handles,
        [handle.get_label() for handle in handles],
        loc="upper center",
        ncol=4,
        fontsize=8,
        frameon=False,
        bbox_to_anchor=(0.5, 0.996),
    )
    fig.suptitle(title, fontsize=12, y=1.0)
    fig.tight_layout(rect=(0, 0, 1, 0.985))
    save_figure(fig, output_base, copy_dir)
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("window_dir", type=Path)
    parser.add_argument("--figure-dir", type=Path, required=True)
    parser.add_argument("--copy-dir", type=Path)
    parser.add_argument("--csv", type=Path)
    parser.add_argument("--percentile-csv", type=Path)
    args = parser.parse_args()

    rows = load_windows(args.window_dir)
    if not rows:
        raise SystemExit(f"no window histograms found under {args.window_dir}")
    window_label = infer_window_label(args.window_dir, rows)
    local_series = choose_local_series(rows)
    local_label = SERIES_LABELS[local_series]

    if args.csv:
        write_csv(rows, args.csv)
    if args.percentile_csv:
        write_percentile_csv(rows, args.percentile_csv, local_series)

    plt = try_import_matplotlib()
    plot_heatmap(
        plt,
        rows,
        local_series,
        f"{local_label.capitalize()} fault latency distribution by {window_label} window",
        args.figure_dir / f"fault_latency_windows_{local_series}_heatmap",
        args.copy_dir,
    )
    plot_heatmap(
        plt,
        rows,
        "remote_pages",
        f"Remote fault latency distribution by {window_label} window",
        args.figure_dir / "fault_latency_windows_remote_heatmap",
        args.copy_dir,
    )
    plot_gt8192(
        plt,
        rows,
        window_label,
        args.figure_dir / "fault_latency_windows_gt8192_timeseries",
        args.copy_dir,
    )
    plot_counts(
        plt,
        rows,
        args.figure_dir / "fault_latency_windows_sample_counts",
        args.copy_dir,
    )
    plot_histogram_facets(
        plt,
        rows,
        "local_pages",
        f"Local fault latency histograms by {window_label} window",
        args.figure_dir / "fault_latency_windows_histograms_local_all_facets",
        args.copy_dir,
    )
    if local_series != "local_pages":
        plot_histogram_facets(
            plt,
            rows,
            "local_large_vma_pages",
            f"Local large-VMA fault latency histograms by {window_label} window",
            args.figure_dir / "fault_latency_windows_histograms_local_large_facets",
            args.copy_dir,
        )
    plot_histogram_facets(
        plt,
        rows,
        "remote_pages",
        f"Remote fault latency histograms by {window_label} window",
        args.figure_dir / "fault_latency_windows_histograms_remote_facets",
        args.copy_dir,
    )
    plot_local_remote_histogram_facets(
        plt,
        rows,
        local_series,
        f"{local_label.capitalize()} vs remote fault latency histograms by {window_label} window",
        args.figure_dir / "fault_latency_windows_histograms_local_remote_facets",
        args.copy_dir,
    )
    plot_local_remote_percentile_facets(
        plt,
        rows,
        local_series,
        f"Local P80 and remote P20 bucket markers by {window_label} window",
        args.figure_dir / "fault_latency_windows_histograms_local_p80_remote_p20_facets",
        args.copy_dir,
    )


if __name__ == "__main__":
    main()
