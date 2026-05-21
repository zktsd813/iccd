#!/usr/bin/env python3
import csv
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


ROOT = Path("/Serverless/iccd")
OUT = ROOT / "experiments/20260520-gapbs-ours-179-compare"
OFF_CSV = ROOT / "experiments/20260520-gapbs-pr-bc-cap8-16-off-nodeonly-rerun/summaries/gapbs_pr_bc_cap8_16_nodeonly_off_summary.csv"
ON_CSV = ROOT / "experiments/20260520-gapbs-on-only-reclaim-retry-verify/summaries/gapbs_on_only_reclaim_retry_summary.csv"
OURS_CSV = OUT / "summaries/gapbs_ours179_summary.csv"

FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"


def font(size, bold=False):
    return ImageFont.truetype(BOLD if bold else FONT, size)


def load_rows(path):
    with path.open() as f:
        return list(csv.DictReader(f))


def key(row):
    return (row["workload"], row["cap"])


def text_center(draw, xy, text, fnt, fill=(20, 24, 30)):
    x, y = xy
    box = draw.textbbox((0, 0), text, font=fnt)
    draw.text((x - (box[2] - box[0]) / 2, y), text, font=fnt, fill=fill)


def draw_chart(path, title, ylabel, values_by_series, labels, series, normalized=False):
    width, height = 1500, 780
    left, right, top, bottom = 130, 60, 105, 135
    plot_w = width - left - right
    plot_h = height - top - bottom

    img = Image.new("RGB", (width, height), "white")
    draw = ImageDraw.Draw(img)
    title_font = font(34, True)
    axis_font = font(22, True)
    tick_font = font(20)
    label_font = font(17, True)
    legend_font = font(20, True)

    text_center(draw, (width / 2, 28), title, title_font)
    text_center(draw, (left + plot_w / 2, height - 60), "", axis_font)

    all_values = [v for values in values_by_series for v in values]
    max_v = max(all_values)
    y_max = max_v * 1.22
    if normalized:
        y_max = max(y_max, 1.25)

    grid_steps = 5
    for i in range(grid_steps + 1):
        value = y_max * i / grid_steps
        y = top + plot_h - (value / y_max) * plot_h
        color = (210, 214, 220) if i else (20, 24, 30)
        draw.line((left, y, left + plot_w, y), fill=color, width=1)
        label = f"{value:.1f}" if not normalized else f"{value:.1f}x"
        box = draw.textbbox((0, 0), label, font=tick_font)
        draw.text((left - 18 - (box[2] - box[0]), y - 12), label, font=tick_font, fill=(42, 48, 56))

    draw.line((left, top, left, top + plot_h), fill=(20, 24, 30), width=2)
    draw.line((left, top + plot_h, left + plot_w, top + plot_h), fill=(20, 24, 30), width=2)

    if normalized:
        y1 = top + plot_h - (1.0 / y_max) * plot_h
        draw.line((left, y1, left + plot_w, y1), fill=(0, 0, 0), width=2)

    group_count = len(labels)
    group_w = plot_w / group_count
    bar_w = group_w * 0.19
    gap = group_w * 0.035
    series_count = len(series)

    for gi, label in enumerate(labels):
        cx = left + group_w * (gi + 0.5)
        for si, (name, color) in enumerate(series):
            value = values_by_series[si][gi]
            total_bars_w = series_count * bar_w + (series_count - 1) * gap
            x0 = cx - total_bars_w / 2 + si * (bar_w + gap)
            x1 = x0 + bar_w
            y0 = top + plot_h - (value / y_max) * plot_h
            y1 = top + plot_h
            draw.rectangle((x0, y0, x1, y1), fill=color, outline=(0, 0, 0), width=2)
            value_label = f"{value:.1f}" if not normalized else f"{value:.2f}x"
            text_center(draw, ((x0 + x1) / 2, y0 - 28), value_label, label_font)
        text_center(draw, (cx, top + plot_h + 22), label, tick_font)

    # y-axis label, rotated.
    label_img = Image.new("RGBA", (360, 40), (255, 255, 255, 0))
    label_draw = ImageDraw.Draw(label_img)
    label_draw.text((0, 0), ylabel, font=axis_font, fill=(20, 24, 30))
    label_img = label_img.rotate(90, expand=True)
    img.paste(label_img, (28, int(top + plot_h / 2 - label_img.height / 2)), label_img)

    legend_x = left + plot_w - 470
    legend_y = 34
    for i, (name, color) in enumerate(series):
        x = legend_x + i * 155
        draw.rectangle((x, legend_y + 6, x + 24, legend_y + 30), fill=color, outline=(0, 0, 0), width=2)
        draw.text((x + 34, legend_y + 4), name, font=legend_font, fill=(20, 24, 30))

    img.save(path)


off = {key(row): float(row["avg_trial_s"]) for row in load_rows(OFF_CSV) if row["policy"] == "off"}
on = {key(row): float(row["avg_trial_s"]) for row in load_rows(ON_CSV)}
ours = {key(row): float(row["avg_trial_s"]) for row in load_rows(OURS_CSV)}

order = [("pr", "8g"), ("pr", "16g"), ("bc", "8g"), ("bc", "16g")]
labels = ["PR 8G", "PR 16G", "BC 8G", "BC 16G"]
series = [
    ("#178 off", (138, 143, 152)),
    ("#179 on", (47, 111, 190)),
    ("#179 ours", (47, 158, 114)),
]
values = [
    [off[item] for item in order],
    [on[item] for item in order],
    [ours[item] for item in order],
]
norm_values = [
    [off[item] / off[item] for item in order],
    [on[item] / off[item] for item in order],
    [ours[item] / off[item] for item in order],
]

OUT.joinpath("summaries").mkdir(parents=True, exist_ok=True)
OUT.joinpath("graphs").mkdir(parents=True, exist_ok=True)

combined_csv = OUT / "summaries/gapbs_178off_179on_179ours.csv"
with combined_csv.open("w", newline="") as f:
    writer = csv.writer(f)
    writer.writerow(["workload", "cap", "kernel_policy", "avg_trial_s"])
    for name, data in (("#178 off", off), ("#179 on", on), ("#179 ours", ours)):
        for workload, cap in order:
            writer.writerow([workload, cap, name, data[(workload, cap)]])

png = OUT / "graphs/gapbs_178off_179on_179ours_avg_trial.png"
norm_png = OUT / "graphs/gapbs_178off_179on_179ours_normalized.png"
draw_chart(png, "GAPBS Trial Average", "Average trial time (s)", values, labels, series)
draw_chart(norm_png, "GAPBS Normalized to #178 off", "Normalized time", norm_values, labels, series, normalized=True)

print(combined_csv)
print(png)
print(norm_png)
