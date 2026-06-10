#!/usr/bin/env python3
"""Build the two-panel design histogram figure from selected SVG panels."""

from __future__ import annotations

import csv
import html
import re
import shutil
from dataclasses import dataclass
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
from matplotlib.patches import Patch


REPO_ROOT = Path(__file__).resolve().parents[2]
OUTPUT_DIR = Path(__file__).resolve().parent
SOURCE_DIR = OUTPUT_DIR / "source"
FIGURE_DIR = REPO_ROOT / "experiments" / "figure"

BUCKET_LABELS = ["<=128", "<=256", "<=512", "<=1024", "<=2048", "<=4096", "<=8192", ">8192"]
LOCAL_COLOR = "#4C78A8"
REMOTE_COLOR = "#E45756"
LOCAL_P_COLOR = "#1F4E79"
REMOTE_P_COLOR = "#B13A3A"
WIDTH = 0.38
NUMBER_RE = re.compile(r"[-+]?\d*\.?\d+(?:[eE][-+]?\d+)?")


@dataclass(frozen=True)
class PanelSpec:
    panel: str
    workload: str
    window: int
    source_svg: Path


@dataclass
class ExtractedPanel:
    spec: PanelSpec
    elapsed_s: float
    local_p80: str
    remote_p20: str
    local_total: int
    remote_total: int
    local_pct: list[float]
    remote_pct: list[float]


PANELS = [
    PanelSpec(
        panel="a",
        workload="GAPBS BC",
        window=32,
        source_svg=REPO_ROOT
        / "motivation/2_microbenchmark/figure/"
        / "gapbs_bc_g29_lfrate_01_i4_local48_remote128_10s_fault_latency_windows_histograms_local_p80_remote_p20_facets.svg",
    ),
    PanelSpec(
        panel="b",
        workload="BTree",
        window=130,
        source_svg=REPO_ROOT
        / "motivation/2_microbenchmark/figure/"
        / "btree_local16_10s_fault_latency_windows_histograms_local_p80_remote_p20_facets.svg",
    ),
]


def parse_path_numbers(path_d: str) -> list[float]:
    return [float(match.group(0)) for match in NUMBER_RE.finditer(path_d)]


def coordinates(path_d: str) -> list[tuple[float, float]]:
    nums = parse_path_numbers(path_d)
    if len(nums) % 2:
        raise ValueError(f"Odd coordinate count in SVG path: {path_d[:80]}")
    return list(zip(nums[0::2], nums[1::2]))


def iter_paths(svg_block: str):
    for match in re.finditer(r"<path\s+d=\"(?P<d>.*?)\"(?P<attrs>[^>]*)>", svg_block, re.S):
        attrs = match.group("attrs")
        style_match = re.search(r"style=\"(?P<style>[^\"]*)\"", attrs)
        style = style_match.group("style") if style_match else ""
        yield match.group("d"), attrs, style


def style_has_fill(style: str, color: str) -> bool:
    return f"fill:{color.lower()}" in style.lower().replace(" ", "")


def extract_axes_block(source_svg: Path, window: int) -> str:
    lines = source_svg.read_text().splitlines()
    target = f"<!-- w{window} "
    try:
        marker_idx = next(i for i, line in enumerate(lines) if target in line)
    except StopIteration as exc:
        raise ValueError(f"Could not find window {window} in {source_svg}") from exc

    start = None
    for i in range(marker_idx, -1, -1):
        if '<g id="axes_' in lines[i]:
            start = i
            break
    if start is None:
        raise ValueError(f"Could not find axes group for window {window} in {source_svg}")

    end = len(lines)
    for i in range(start + 1, len(lines)):
        if '<g id="axes_' in lines[i]:
            end = i
            break
    return "\n".join(lines[start:end])


def extract_metadata(block: str) -> tuple[float, str, str, int, int]:
    elapsed_match = re.search(r"<!--\s*w\d+\s+([0-9.]+)s\s*-->", block)
    percentile_match = re.search(r"<!--\s*L80=([^\s]+)\s+R20=([^\s]+)\s*-->", block)
    total_match = re.search(r"<!--\s*L=([0-9,]+)\s+R=([0-9,]+)\s*-->", block)
    if not elapsed_match or not percentile_match or not total_match:
        raise ValueError("Missing window metadata in SVG axes block")

    elapsed_s = float(elapsed_match.group(1))
    local_p80 = html.unescape(percentile_match.group(1))
    remote_p20 = html.unescape(percentile_match.group(2))
    local_total = int(total_match.group(1).replace(",", ""))
    remote_total = int(total_match.group(2).replace(",", ""))
    return elapsed_s, local_p80, remote_p20, local_total, remote_total


def extract_axis_bounds(block: str) -> tuple[float, float, float, float]:
    for path_d, _attrs, style in iter_paths(block):
        if style_has_fill(style, "#ffffff"):
            coords = coordinates(path_d)
            xs = [x for x, _y in coords]
            ys = [y for _x, y in coords]
            return min(xs), max(xs), min(ys), max(ys)
    raise ValueError("Could not find SVG axes background patch")


def extract_bar_percentages(block: str, color: str, bounds: tuple[float, float, float, float]) -> list[float]:
    left, right, top, bottom = bounds
    axis_height = bottom - top
    if axis_height <= 0:
        raise ValueError(f"Invalid axis height: top={top} bottom={bottom}")

    bars: list[tuple[float, float]] = []
    for path_d, _attrs, style in iter_paths(block):
        if not style_has_fill(style, color):
            continue
        coords = coordinates(path_d)
        xs = [x for x, _y in coords]
        ys = [y for _x, y in coords]
        x_min, x_max = min(xs), max(xs)
        y_min, y_max = min(ys), max(ys)
        if x_min < left - 1e-6 or x_max > right + 1e-6:
            continue
        if y_min < top - 1e-6 or y_max > bottom + 1e-6:
            continue
        x_center = (x_min + x_max) / 2.0
        percent = max(0.0, min(100.0, (bottom - y_min) * 100.0 / axis_height))
        bars.append((x_center, percent))

    bars.sort(key=lambda item: item[0])
    if len(bars) < len(BUCKET_LABELS):
        raise ValueError(f"Expected at least {len(BUCKET_LABELS)} {color} bars, found {len(bars)}")
    return [percent for _x, percent in bars[: len(BUCKET_LABELS)]]


def extract_panel(spec: PanelSpec) -> ExtractedPanel:
    block = extract_axes_block(spec.source_svg, spec.window)
    elapsed_s, local_p80, remote_p20, local_total, remote_total = extract_metadata(block)
    bounds = extract_axis_bounds(block)
    local_pct = extract_bar_percentages(block, LOCAL_COLOR, bounds)
    remote_pct = extract_bar_percentages(block, REMOTE_COLOR, bounds)
    return ExtractedPanel(
        spec=spec,
        elapsed_s=elapsed_s,
        local_p80=local_p80,
        remote_p20=remote_p20,
        local_total=local_total,
        remote_total=remote_total,
        local_pct=local_pct,
        remote_pct=remote_pct,
    )


def marker_index(label: str) -> int:
    return BUCKET_LABELS.index(label) if label in BUCKET_LABELS else -1


def write_csv(panels: list[ExtractedPanel], csv_path: Path) -> None:
    with csv_path.open("w", newline="") as file:
        writer = csv.DictWriter(
            file,
            fieldnames=[
                "panel",
                "workload",
                "window",
                "elapsed_s",
                "series",
                "bucket",
                "percent",
                "total_samples",
                "estimated_samples_from_svg_percent",
                "source_svg",
            ],
        )
        writer.writeheader()
        for panel in panels:
            for series, percentages, total in [
                ("local", panel.local_pct, panel.local_total),
                ("remote", panel.remote_pct, panel.remote_total),
            ]:
                for bucket, percent in zip(BUCKET_LABELS, percentages):
                    writer.writerow(
                        {
                            "panel": panel.spec.panel,
                            "workload": panel.spec.workload,
                            "window": panel.spec.window,
                            "elapsed_s": panel.elapsed_s,
                            "series": series,
                            "bucket": bucket,
                            "percent": f"{percent:.6f}",
                            "total_samples": total,
                            "estimated_samples_from_svg_percent": round(total * percent / 100.0),
                            "source_svg": panel.spec.source_svg.relative_to(REPO_ROOT),
                        }
                    )


def plot_figure(panels: list[ExtractedPanel], output_base: Path) -> None:
    fig, axes = plt.subplots(1, 2, figsize=(8.4, 3.15), sharey=True)
    x = list(range(len(BUCKET_LABELS)))

    for ax, panel in zip(axes, panels):
        ax.bar(
            [pos - WIDTH / 2 for pos in x],
            panel.local_pct,
            width=WIDTH,
            color=LOCAL_COLOR,
            edgecolor="#222222",
            linewidth=0.35,
        )
        ax.bar(
            [pos + WIDTH / 2 for pos in x],
            panel.remote_pct,
            width=WIDTH,
            color=REMOTE_COLOR,
            edgecolor="#222222",
            linewidth=0.35,
        )

        local_idx = marker_index(panel.local_p80)
        remote_idx = marker_index(panel.remote_p20)
        if local_idx >= 0:
            local_x = local_idx - WIDTH / 2
            ax.axvline(local_x, color=LOCAL_P_COLOR, linestyle=":", linewidth=1.15, alpha=0.8)
            ax.scatter(
                [local_x],
                [96],
                marker="v",
                s=42,
                color=LOCAL_P_COLOR,
                edgecolor="white",
                linewidth=0.45,
                zorder=5,
            )
            ax.annotate(
                f"P80 {panel.local_p80}",
                xy=(local_x, 96),
                xytext=(4, -4),
                textcoords="offset points",
                color=LOCAL_P_COLOR,
                fontsize=8,
                ha="left",
                va="top",
            )
        if remote_idx >= 0:
            remote_x = remote_idx + WIDTH / 2
            ax.axvline(remote_x, color=REMOTE_P_COLOR, linestyle=":", linewidth=1.15, alpha=0.8)
            ax.scatter(
                [remote_x],
                [86],
                marker="^",
                s=42,
                color=REMOTE_P_COLOR,
                edgecolor="white",
                linewidth=0.45,
                zorder=5,
            )
            ax.annotate(
                f"P20 {panel.remote_p20}",
                xy=(remote_x, 86),
                xytext=(4, 4),
                textcoords="offset points",
                color=REMOTE_P_COLOR,
                fontsize=8,
                ha="left",
                va="bottom",
            )

        ax.set_title(
            f"({panel.spec.panel}) {panel.spec.workload}, window {panel.spec.window} ({panel.elapsed_s:.0f}s)\n"
            f"Local n={panel.local_total:,} / Remote n={panel.remote_total:,}",
            fontsize=9.5,
            pad=7,
        )
        ax.set_ylim(0, 100)
        ax.set_yticks([0, 20, 40, 60, 80, 100])
        ax.set_xticks(x)
        ax.set_xticklabels(BUCKET_LABELS, rotation=35, ha="right")
        ax.set_xlabel("Latency bucket (ms)")
        ax.grid(axis="y", color="#d9d9d9", linewidth=0.6)
        ax.set_axisbelow(True)
        ax.tick_params(axis="both", labelsize=8)

    axes[0].set_ylabel("Fault samples (%)")

    handles = [
        Patch(facecolor=LOCAL_COLOR, edgecolor="#222222", label="Local samples"),
        Patch(facecolor=REMOTE_COLOR, edgecolor="#222222", label="Remote samples"),
        Line2D(
            [0],
            [0],
            marker="v",
            linestyle=":",
            color=LOCAL_P_COLOR,
            markerfacecolor=LOCAL_P_COLOR,
            markeredgecolor="white",
            label="Local P80 bucket",
        ),
        Line2D(
            [0],
            [0],
            marker="^",
            linestyle=":",
            color=REMOTE_P_COLOR,
            markerfacecolor=REMOTE_P_COLOR,
            markeredgecolor="white",
            label="Remote P20 bucket",
        ),
    ]
    fig.legend(
        handles=handles,
        loc="upper center",
        bbox_to_anchor=(0.5, 1.02),
        ncol=4,
        frameon=False,
        fontsize=8.2,
    )
    fig.tight_layout(rect=(0, 0, 1, 0.92), w_pad=1.4)

    for suffix in [".pdf", ".svg", ".png"]:
        fig.savefig(output_base.with_suffix(suffix), bbox_inches="tight")
    plt.close(fig)


def copy_sources() -> None:
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    for spec in PANELS:
        for suffix in [".svg", ".pdf"]:
            source = spec.source_svg.with_suffix(suffix)
            if source.exists():
                shutil.copy2(source, SOURCE_DIR / source.name)


def copy_to_latest(output_base: Path) -> None:
    FIGURE_DIR.mkdir(parents=True, exist_ok=True)
    for suffix in [".pdf", ".svg", ".png"]:
        shutil.copy2(output_base.with_suffix(suffix), FIGURE_DIR / f"submission_design_histogram{suffix}")


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    for spec in PANELS:
        if not spec.source_svg.exists():
            raise FileNotFoundError(spec.source_svg)

    panels = [extract_panel(spec) for spec in PANELS]
    write_csv(panels, OUTPUT_DIR / "selected_histogram_data.csv")
    plot_figure(panels, OUTPUT_DIR / "design_histogram")
    copy_sources()
    copy_to_latest(OUTPUT_DIR / "design_histogram")


if __name__ == "__main__":
    main()
