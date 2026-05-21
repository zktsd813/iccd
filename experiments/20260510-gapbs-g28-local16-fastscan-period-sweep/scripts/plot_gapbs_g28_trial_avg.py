#!/usr/bin/env python3
import argparse
import csv
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


PALETTE = {
    250: "#6f91c2",
    500: "#e8a34a",
    1000: "#55a293",
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


def text_center(draw, xy, text, fnt, fill="#111111"):
    x, y = xy
    box = draw.textbbox((0, 0), text, font=fnt)
    draw.text((x - (box[2] - box[0]) / 2, y), text, font=fnt, fill=fill)


def parse_rows(csv_path, workload):
    rows = []
    with open(csv_path, newline="") as f:
        for row in csv.DictReader(f):
            if row["workload"].lower() != workload.lower():
                continue
            rows.append({
                "period_ms": int(row["period_ms"]),
                "trial_avg_s": float(row["trial_avg_s"]),
                "trial_median_s": float(row["trial_median_s"]),
                "trial_stdev_s": float(row["trial_stdev_s"]),
            })
    return sorted(rows, key=lambda r: r["period_ms"])


def draw_chart(rows, workload, out_path, title):
    if not rows:
        raise SystemExit(f"no rows found for workload={workload}")

    width, height = 1800, 1200
    margin_l, margin_r = 220, 120
    margin_t, margin_b = 230, 230
    plot_l, plot_t = margin_l, margin_t
    plot_r, plot_b = width - margin_r, height - margin_b
    plot_w, plot_h = plot_r - plot_l, plot_b - plot_t

    im = Image.new("RGB", (width, height), "white")
    d = ImageDraw.Draw(im)

    f_title = font(68, True)
    f_axis = font(42, True)
    f_tick = font(36)
    f_label = font(34, True)
    f_note = font(30)

    text_center(d, (width / 2, 42), title, f_title)

    max_y = max(r["trial_avg_s"] for r in rows)
    top_y = max(10, int((max_y * 1.25 + 4) // 5 * 5))
    grid_step = 10 if top_y > 25 else 5

    # Axes and grid.
    d.line((plot_l, plot_t, plot_l, plot_b), fill="#202020", width=5)
    d.line((plot_l, plot_b, plot_r, plot_b), fill="#202020", width=5)
    y = 0
    while y <= top_y:
        py = plot_b - (y / top_y) * plot_h
        if y:
            d.line((plot_l, py, plot_r, py), fill="#d7dbe0", width=3)
        label = str(y)
        box = d.textbbox((0, 0), label, font=f_tick)
        d.text((plot_l - 30 - (box[2] - box[0]), py - 20), label, font=f_tick, fill="#111111")
        y += grid_step

    axis_label = "Time (s)"
    box = d.textbbox((0, 0), axis_label, font=f_axis)
    axis_im = Image.new("RGBA", (box[2] - box[0] + 20, box[3] - box[1] + 20), (255, 255, 255, 0))
    axis_d = ImageDraw.Draw(axis_im)
    axis_d.text((10, 10), axis_label, font=f_axis, fill="#111111")
    axis_im = axis_im.rotate(90, expand=True)
    im.paste(axis_im, (55, int(plot_t + plot_h / 2 - axis_im.height / 2)), axis_im)

    # Bars.
    n = len(rows)
    gap = 120
    bar_w = min(220, (plot_w - gap * (n + 1)) / n)
    start_x = plot_l + (plot_w - (bar_w * n + gap * (n - 1))) / 2
    for i, row in enumerate(rows):
        x0 = start_x + i * (bar_w + gap)
        x1 = x0 + bar_w
        y1 = plot_b
        y0 = plot_b - (row["trial_avg_s"] / top_y) * plot_h
        color = PALETTE.get(row["period_ms"], "#777777")
        d.rectangle((x0, y0, x1, y1), fill=color, outline="#000000", width=6)

        value = f"{row['trial_avg_s']:.2f}s"
        box = d.textbbox((0, 0), value, font=f_label)
        d.text((x0 + bar_w / 2 - (box[2] - box[0]) / 2, y0 - 48), value, font=f_label, fill="#111111")

        label = f"{row['period_ms']}ms"
        box = d.textbbox((0, 0), label, font=f_axis)
        d.text((x0 + bar_w / 2 - (box[2] - box[0]) / 2, plot_b + 48), label, font=f_axis, fill="#111111")

    workload_label = workload.upper()
    text_center(d, (width / 2, plot_b + 120), workload_label, font(44, True))
    note = "GAPBS -g28, local cap 16G, scan size 256MB, fast scan on, migration on"
    text_center(d, (width / 2, height - 76), note, f_note, fill="#333333")

    out_path.parent.mkdir(parents=True, exist_ok=True)
    im.save(out_path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", required=True, type=Path)
    ap.add_argument("--workload", default="pr")
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--title", default=None)
    args = ap.parse_args()

    rows = parse_rows(args.csv, args.workload)
    title = args.title or f"{args.workload.upper()} g28 Trial Average"
    draw_chart(rows, args.workload, args.out, title)


if __name__ == "__main__":
    main()
