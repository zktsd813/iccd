#!/usr/bin/env python3
import csv
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

FULL_ROOT = Path("/Serverless/iccd/experiments/20260520-gapbs-full-latest-policy-window-sweep")
FULL_SUMMARY = FULL_ROOT / "summaries" / "gapbs_full_latest_policy_window_sweep_summary.csv"
ROOT = Path("/Serverless/iccd/experiments/20260521-gapbs-placement-alllocal-allremote")
PLACE_SUMMARY = ROOT / "guest-results" / "gapbs-placement-alllocal-allremote" / "summary.csv"
OUT_CSV = ROOT / "summaries" / "gapbs_full_latest_with_placement.csv"
OUT_MD = ROOT / "summaries" / "gapbs_full_latest_with_placement.md"
GRAPH_DIR = ROOT / "graphs"
FIG_DIR = Path("/Serverless/iccd/experiments/figure")

WORKLOADS = ("pr", "bc")
CAPS = ("8g", "16g")
WINDOWS = ("5", "10", "20")
BAR_KEYS = ("off", "on", "oneshot", "toggle")
COLORS = {
    "off": "#4d4d4d",
    "on": "#d95f02",
    "oneshot": "#1b9e77",
    "toggle": "#377eb8",
    "all-local": "#984ea3",
    "all-remote": "#e7298a",
}
LABELS = {
    "off": "off",
    "on": "on",
    "oneshot": "one-shot",
    "toggle": "toggle",
    "all-local": "all-local",
    "all-remote": "all-remote",
}


def font(size, bold=False):
    candidates = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation2/LiberationSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf",
    ]
    for path in candidates:
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def text_size(draw, text, fnt):
    box = draw.textbbox((0, 0), text, font=fnt)
    return box[2] - box[0], box[3] - box[1]


def center(draw, x, y, text, fnt, fill="#111111"):
    w, h = text_size(draw, text, fnt)
    draw.text((x - w / 2, y - h / 2), text, font=fnt, fill=fill)


def fmt(value):
    if value in ("", None):
        return "n/a"
    return f"{float(value):.5f}"


def ms_to_s(value):
    if not value:
        return ""
    return f"{float(value) / 1000.0:.3f}"


def read_full():
    data = {}
    for row in csv.DictReader(FULL_SUMMARY.open()):
        data[(row["workload"], row["cap"], row["policy"], row["window_sec"])] = row
    return data


def read_placement():
    data = {}
    for row in csv.DictReader(PLACE_SUMMARY.open()):
        data[(row["workload"], row["placement"])] = row
    return data


def build_rows(full, placement):
    rows = []
    for workload in WORKLOADS:
        place_local = placement[(workload, "all-local")]
        place_remote = placement[(workload, "all-remote")]
        for cap in CAPS:
            off = full[(workload, cap, "off", "")]
            on = full[(workload, cap, "on", "")]
            for window in WINDOWS:
                one = full[(workload, cap, "oneshot", window)]
                tog = full[(workload, cap, "toggle", window)]
                rows.append({
                    "workload": workload,
                    "cap": cap,
                    "window_sec": window,
                    "off_avg_s": off["avg_trial_s"],
                    "on_avg_s": on["avg_trial_s"],
                    "oneshot_avg_s": one["avg_trial_s"],
                    "oneshot_off_s": ms_to_s(one["first_off_ms"]),
                    "toggle_avg_s": tog["avg_trial_s"],
                    "toggle_off_s": ms_to_s(tog["first_off_ms"]),
                    "toggle_on_s": ms_to_s(tog["first_on_ms"]),
                    "all_local_avg_s": place_local["avg_trial_s"],
                    "all_remote_avg_s": place_remote["avg_trial_s"],
                })
    return rows


def write_tables(rows, placement):
    OUT_CSV.parent.mkdir(parents=True, exist_ok=True)
    fields = [
        "workload", "cap", "window_sec", "off_avg_s", "on_avg_s",
        "oneshot_avg_s", "oneshot_off_s", "toggle_avg_s",
        "toggle_off_s", "toggle_on_s", "all_local_avg_s",
        "all_remote_avg_s",
    ]
    with OUT_CSV.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)

    lines = [
        "# GAPBS latest-kernel comparison with placement baselines",
        "",
        "Values are GAPBS `Average Time` in seconds; lower is better.",
        "",
        "- Kernel: `Linux kernel 6.18.0modified #179 SMP PREEMPT_DYNAMIC Wed May 20 03:30:57 UTC 2026`.",
        "- Graph input: `/root/gapbs_graphs/kron_g28.sg`, loaded with `-f`.",
        "- Placement baseline: migration/local-fault/demotion off, no cgroup node capacity, cgroup `cpuset.mems=0` for all-local and `cpuset.mems=1` for all-remote.",
        "- Canonical VM: node0 32G local DRAM, node1 64G remote CXL, 32 vCPUs pinned to node0.",
        "",
        "## Placement baselines",
        "",
        "| workload | all-local | all-remote | local/remote |",
        "| --- | ---: | ---: | ---: |",
    ]
    for workload in WORKLOADS:
        local = float(placement[(workload, "all-local")]["avg_trial_s"])
        remote = float(placement[(workload, "all-remote")]["avg_trial_s"])
        lines.append(f"| {workload} | {local:.5f} | {remote:.5f} | {local / remote:.3f}x |")
    lines += ["", "## Full comparison", ""]
    for workload in WORKLOADS:
        lines += [
            f"### {workload.upper()}",
            "",
            "| cap | window | off | on | one-shot | toggle | all-local | all-remote |",
            "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        ]
        for row in [r for r in rows if r["workload"] == workload]:
            lines.append(
                f"| {row['cap']} | {row['window_sec']} | {fmt(row['off_avg_s'])} | {fmt(row['on_avg_s'])} | "
                f"{fmt(row['oneshot_avg_s'])} | {fmt(row['toggle_avg_s'])} | "
                f"{fmt(row['all_local_avg_s'])} | {fmt(row['all_remote_avg_s'])} |"
            )
        lines.append("")
    OUT_MD.write_text("\n".join(lines), encoding="ascii")


def dashed_line(draw, xy, fill, width=4, dash=18, gap=12):
    x0, y0, x1, y1 = xy
    x = x0
    while x < x1:
        draw.line((x, y0, min(x + dash, x1), y1), fill=fill, width=width)
        x += dash + gap


def plot_workload(workload, rows, placement):
    subset = [r for r in rows if r["workload"] == workload]
    place_vals = [
        float(placement[(workload, "all-local")]["avg_trial_s"]),
        float(placement[(workload, "all-remote")]["avg_trial_s"]),
    ]
    y_max = max(
        max(max(float(r[f"{key}_avg_s"]) for key in BAR_KEYS) for r in subset),
        max(place_vals),
    )
    y_max = max(60.0, ((int(y_max / 10) + 1) * 10.0))

    width, height = 2200, 1320
    margin_l, margin_r, margin_t, margin_b = 145, 165, 150, 230
    gap_panel = 95
    panel_w = (width - margin_l - margin_r - gap_panel) / 2
    plot_h = height - margin_t - margin_b

    img = Image.new("RGB", (width, height), "white")
    draw = ImageDraw.Draw(img)
    title_f = font(46, True)
    subtitle_f = font(24)
    axis_f = font(28, True)
    tick_f = font(23)
    value_f = font(18, True)
    small_f = font(16, True)
    legend_f = font(24)

    center(draw, width / 2, 55, f"{workload.upper()} Latest Kernel Policy/Window + Placement", title_f)
    center(draw, width / 2, 104, "Average Time (s), lower is better", subtitle_f, "#555555")

    for ci, cap in enumerate(CAPS):
        x0 = margin_l + ci * (panel_w + gap_panel)
        x1 = x0 + panel_w
        y0 = margin_t + plot_h
        draw.line((x0, margin_t, x0, y0), fill="#111111", width=3)
        draw.line((x0, y0, x1, y0), fill="#111111", width=3)
        center(draw, x0 + panel_w / 2, margin_t - 43, cap.upper(), axis_f)

        for tick in range(0, int(y_max) + 1, 10):
            y = y0 - (tick / y_max) * plot_h
            draw.line((x0, y, x1, y), fill="#dddddd", width=1)
            draw.line((x0 - 8, y, x0, y), fill="#111111", width=2)
            tw, th = text_size(draw, str(tick), tick_f)
            draw.text((x0 - tw - 18, y - th / 2), str(tick), font=tick_f, fill="#222222")

        for pkey in ("all-local", "all-remote"):
            val = float(placement[(workload, pkey)]["avg_trial_s"])
            y = y0 - (val / y_max) * plot_h
            dashed_line(draw, (x0, y, x1, y), COLORS[pkey], width=5)
            if ci == len(CAPS) - 1:
                label = f"{LABELS[pkey]} {val:.1f}s"
                draw.text((x1 + 10, y - 15), label, font=small_f, fill=COLORS[pkey])

        cap_rows = [r for r in subset if r["cap"] == cap]
        group_w = panel_w / len(WINDOWS)
        bar_w = 56
        bar_gap = 8
        inner_w = len(BAR_KEYS) * bar_w + (len(BAR_KEYS) - 1) * bar_gap
        for wi, window in enumerate(WINDOWS):
            row = next(r for r in cap_rows if r["window_sec"] == window)
            gx = x0 + group_w * wi + group_w / 2
            start = gx - inner_w / 2
            for bi, key in enumerate(BAR_KEYS):
                val = float(row[f"{key}_avg_s"])
                bx0 = start + bi * (bar_w + bar_gap)
                bx1 = bx0 + bar_w
                by0 = y0 - (val / y_max) * plot_h
                draw.rectangle((bx0, by0, bx1, y0), fill=COLORS[key], outline="#111111", width=2)
                label = f"{val:.1f}"
                lw, lh = text_size(draw, label, value_f)
                draw.text((bx0 + bar_w / 2 - lw / 2, by0 - lh - 7), label, font=value_f, fill="#111111")
                if key == "oneshot":
                    event = f"off@{float(row['oneshot_off_s']):.0f}s"
                elif key == "toggle":
                    event = f"{float(row['toggle_off_s']):.0f}->{float(row['toggle_on_s']):.0f}s"
                else:
                    event = ""
                if event:
                    ew, eh = text_size(draw, event, small_f)
                    draw.text((bx0 + bar_w / 2 - ew / 2, by0 - lh - eh - 10), event, font=small_f, fill="#111111")
            center(draw, gx, y0 + 44, f"{window}s", axis_f)

    leg_y = height - 110
    legend_items = BAR_KEYS + ("all-local", "all-remote")
    widths = []
    for key in legend_items:
        tw, _ = text_size(draw, LABELS[key], legend_f)
        widths.append(38 + 12 + tw + 36)
    lx = width / 2 - sum(widths) / 2
    for key, item_w in zip(legend_items, widths):
        if key in BAR_KEYS:
            draw.rectangle((lx, leg_y - 16, lx + 32, leg_y + 16), fill=COLORS[key], outline="#111111", width=2)
        else:
            dashed_line(draw, (lx, leg_y, lx + 32, leg_y), COLORS[key], width=5, dash=12, gap=7)
        tw, th = text_size(draw, LABELS[key], legend_f)
        draw.text((lx + 44, leg_y - th / 2), LABELS[key], font=legend_f, fill="#111111")
        lx += item_w

    GRAPH_DIR.mkdir(parents=True, exist_ok=True)
    FIG_DIR.mkdir(parents=True, exist_ok=True)
    out = GRAPH_DIR / f"gapbs_full_latest_{workload}_policy_window_with_placement.png"
    fig = FIG_DIR / out.name
    img.save(out)
    img.save(fig)
    print(out)
    print(fig)


def main():
    full = read_full()
    placement = read_placement()
    rows = build_rows(full, placement)
    write_tables(rows, placement)
    for workload in WORKLOADS:
        plot_workload(workload, rows, placement)
    print(OUT_CSV)
    print(OUT_MD)


if __name__ == "__main__":
    main()
