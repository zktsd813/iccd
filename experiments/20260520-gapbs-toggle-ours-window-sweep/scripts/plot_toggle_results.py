#!/usr/bin/env python3
import csv
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path("/Serverless/iccd/experiments/20260520-gapbs-toggle-ours-window-sweep")
IN_CSV = ROOT / "summaries" / "gapbs_toggle_ours_window_sweep_summary.csv"
OUT = ROOT / "graphs" / "gapbs_toggle_ours_window_sweep_avg.png"
FIG = Path("/Serverless/iccd/experiments/figure/gapbs_toggle_ours_window_sweep_avg.png")

WORKLOADS = ["pr", "bc"]
CAPS = ["8g", "16g"]
WINDOWS = ["5", "10", "20"]
COLORS = {"5": "#1b9e77", "10": "#377eb8", "20": "#984ea3"}


def font(size, bold=False):
    paths = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation2/LiberationSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf",
    ]
    for path in paths:
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def text_size(draw, text, fnt):
    box = draw.textbbox((0, 0), text, font=fnt)
    return box[2] - box[0], box[3] - box[1]


def center(draw, x, y, text, fnt, fill="#111111"):
    w, h = text_size(draw, text, fnt)
    draw.text((x - w / 2, y - h / 2), text, font=fnt, fill=fill)


def main():
    rows = list(csv.DictReader(IN_CSV.open()))
    data = {(r["workload"], r["cap"], r["window_sec"]): float(r["avg_trial_s"]) for r in rows}
    off_s = {(r["workload"], r["cap"], r["window_sec"]): float(r["first_off_ms"]) / 1000.0 for r in rows}
    on_s = {(r["workload"], r["cap"], r["window_sec"]): float(r["first_on_ms"]) / 1000.0 for r in rows}

    width, height = 1900, 1120
    margin_l, margin_r, margin_t, margin_b = 145, 80, 145, 190
    gap_panel = 95
    panel_w = (width - margin_l - margin_r - gap_panel) / 2
    plot_h = height - margin_t - margin_b
    y_max = 60.0

    img = Image.new("RGB", (width, height), "white")
    draw = ImageDraw.Draw(img)
    title_f = font(44, True)
    subtitle_f = font(23)
    axis_f = font(27, True)
    tick_f = font(22)
    value_f = font(19, True)
    small_f = font(16, True)
    legend_f = font(24)

    center(draw, width / 2, 55, "GAPBS Toggle Ours Average Trial Time", title_f)
    center(draw, width / 2, 100, "migration off, then re-enable after 2 non-matching windows", subtitle_f, "#555555")

    for wi, workload in enumerate(WORKLOADS):
        x0 = margin_l + wi * (panel_w + gap_panel)
        x1 = x0 + panel_w
        y0 = margin_t + plot_h
        draw.line((x0, margin_t, x0, y0), fill="#111111", width=3)
        draw.line((x0, y0, x1, y0), fill="#111111", width=3)
        center(draw, x0 + panel_w / 2, margin_t - 42, workload.upper(), axis_f)

        for tick in range(0, 61, 10):
            y = y0 - (tick / y_max) * plot_h
            draw.line((x0, y, x1, y), fill="#dddddd", width=1)
            draw.line((x0 - 8, y, x0, y), fill="#111111", width=2)
            tw, th = text_size(draw, str(tick), tick_f)
            draw.text((x0 - tw - 18, y - th / 2), str(tick), font=tick_f, fill="#222222")

        group_w = panel_w / len(CAPS)
        bar_w = 80
        bar_gap = 10
        inner_w = len(WINDOWS) * bar_w + (len(WINDOWS) - 1) * bar_gap
        for ci, cap in enumerate(CAPS):
            gx = x0 + group_w * ci + group_w / 2
            start = gx - inner_w / 2
            for pi, win in enumerate(WINDOWS):
                val = data[(workload, cap, win)]
                bx0 = start + pi * (bar_w + bar_gap)
                bx1 = bx0 + bar_w
                by0 = y0 - (val / y_max) * plot_h
                draw.rectangle((bx0, by0, bx1, y0), fill=COLORS[win], outline="#111111", width=3)
                label = f"{val:.1f}"
                lw, lh = text_size(draw, label, value_f)
                draw.text((bx0 + bar_w / 2 - lw / 2, by0 - lh - 28), label, font=value_f, fill="#111111")
                evt = f"{off_s[(workload, cap, win)]:.0f}->{on_s[(workload, cap, win)]:.0f}s"
                ew, eh = text_size(draw, evt, small_f)
                draw.text((bx0 + bar_w / 2 - ew / 2, by0 - eh - 7), evt, font=small_f, fill="#111111")
            center(draw, gx, y0 + 43, cap.upper(), axis_f)

    center(draw, 45, margin_t + plot_h / 2, "Average Time (s)", axis_f)

    leg_y = height - 95
    legend_items = [(w, f"{w}s window") for w in WINDOWS]
    total = 0
    sizes = []
    for win, label in legend_items:
        tw, th = text_size(draw, label, legend_f)
        item_w = 34 + 12 + tw + 42
        sizes.append((win, label, tw, th, item_w))
        total += item_w
    lx = width / 2 - total / 2
    for win, label, tw, th, item_w in sizes:
        draw.rectangle((lx, leg_y - 15, lx + 30, leg_y + 15), fill=COLORS[win], outline="#111111", width=2)
        draw.text((lx + 42, leg_y - th / 2), label, font=legend_f, fill="#111111")
        lx += item_w

    OUT.parent.mkdir(parents=True, exist_ok=True)
    FIG.parent.mkdir(parents=True, exist_ok=True)
    img.save(OUT)
    img.save(FIG)
    print(OUT)
    print(FIG)


if __name__ == "__main__":
    main()
