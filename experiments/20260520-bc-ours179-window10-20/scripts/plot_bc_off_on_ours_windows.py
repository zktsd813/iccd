#!/usr/bin/env python3
import csv
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


ROOT = Path("/Serverless/iccd/experiments/20260520-bc-ours179-window10-20")
CSV = ROOT / "summaries" / "bc_off_on_ours_window_compare.csv"
OUT = ROOT / "graphs" / "bc_off_on_ours_window_compare.png"
FIG = Path("/Serverless/iccd/experiments/figure/bc_off_on_ours_window_compare.png")

POLICIES = ["off", "on", "ours 5s", "ours 10s", "ours 20s"]
CAPS = ["8G", "16G"]
COLORS = {
    "off": "#4d4d4d",
    "on": "#d95f02",
    "ours 5s": "#1b9e77",
    "ours 10s": "#377eb8",
    "ours 20s": "#984ea3",
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


def draw_center(draw, x, y, text, fnt, fill):
    w, h = text_size(draw, text, fnt)
    draw.text((x - w / 2, y - h / 2), text, font=fnt, fill=fill)


def main():
    rows = list(csv.DictReader(CSV.open()))
    data = {(r["cap"], r["policy"]): float(r["avg_trial_s"]) for r in rows}
    stop = {
        (r["cap"], r["policy"]): float(r["stop_s"])
        for r in rows
        if r.get("stop_s")
    }
    max_v = max(data.values())

    width, height = 1800, 1120
    margin_l, margin_r = 150, 70
    margin_t, margin_b = 145, 210
    plot_w = width - margin_l - margin_r
    plot_h = height - margin_t - margin_b

    img = Image.new("RGB", (width, height), "white")
    draw = ImageDraw.Draw(img)

    title_f = font(44, True)
    axis_f = font(28, True)
    tick_f = font(24)
    label_f = font(22, True)
    legend_f = font(24)
    value_f = font(21, True)
    stop_f = font(18, True)

    draw_center(draw, width / 2, 58, "BC Average Trial Time", title_f, "#111111")
    draw_center(draw, width / 2, 103, "lower is better", font(23), "#555555")

    y_max = 60.0
    y0 = margin_t + plot_h
    x0 = margin_l
    x1 = margin_l + plot_w

    # Grid and y-axis.
    draw.line((x0, margin_t, x0, y0), fill="#111111", width=3)
    draw.line((x0, y0, x1, y0), fill="#111111", width=3)
    for tick in range(0, 61, 10):
        y = y0 - (tick / y_max) * plot_h
        draw.line((x0 - 8, y, x0, y), fill="#111111", width=2)
        draw.line((x0, y, x1, y), fill="#dddddd", width=1)
        draw.text((x0 - 18 - text_size(draw, str(tick), tick_f)[0], y - 13), str(tick), font=tick_f, fill="#222222")
    draw_center(draw, 48, margin_t + plot_h / 2, "Average Time (s)", axis_f, "#111111")

    group_w = plot_w / len(CAPS)
    bar_w = 88
    gap = 8
    group_inner_w = len(POLICIES) * bar_w + (len(POLICIES) - 1) * gap

    for gi, cap in enumerate(CAPS):
        gx = x0 + gi * group_w + group_w / 2
        start = gx - group_inner_w / 2
        for pi, policy in enumerate(POLICIES):
            val = data[(cap, policy)]
            bx0 = start + pi * (bar_w + gap)
            bx1 = bx0 + bar_w
            by1 = y0
            by0 = y0 - (val / y_max) * plot_h
            draw.rectangle((bx0, by0, bx1, by1), fill=COLORS[policy], outline="#111111", width=3)
            value = f"{val:.1f}"
            vw, vh = text_size(draw, value, value_f)
            label_y = by0 - vh - 8
            draw.text((bx0 + bar_w / 2 - vw / 2, label_y), value, font=value_f, fill="#111111")
            if (cap, policy) in stop:
                stop_label = f"off@{stop[(cap, policy)]:.0f}s"
                sw, sh = text_size(draw, stop_label, stop_f)
                draw.text((bx0 + bar_w / 2 - sw / 2, label_y + vh + 4), stop_label, font=stop_f, fill="#111111")
        draw_center(draw, gx, y0 + 48, cap, axis_f, "#111111")

    # Legend.
    leg_y = height - 105
    total_w = 0
    sizes = []
    for policy in POLICIES:
        tw, th = text_size(draw, policy, legend_f)
        item_w = 34 + 12 + tw + 34
        sizes.append((policy, tw, th, item_w))
        total_w += item_w
    lx = width / 2 - total_w / 2
    for policy, tw, th, item_w in sizes:
        draw.rectangle((lx, leg_y - 14, lx + 30, leg_y + 16), fill=COLORS[policy], outline="#111111", width=2)
        draw.text((lx + 42, leg_y - th / 2), policy, font=legend_f, fill="#111111")
        lx += item_w

    OUT.parent.mkdir(parents=True, exist_ok=True)
    FIG.parent.mkdir(parents=True, exist_ok=True)
    img.save(OUT)
    img.save(FIG)
    print(OUT)
    print(FIG)


if __name__ == "__main__":
    main()
