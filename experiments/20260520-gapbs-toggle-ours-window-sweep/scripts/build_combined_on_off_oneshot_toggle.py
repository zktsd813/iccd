#!/usr/bin/env python3
import csv
from pathlib import Path

ROOT = Path("/Serverless/iccd/experiments/20260520-gapbs-toggle-ours-window-sweep")
OUT_CSV = ROOT / "summaries" / "gapbs_on_off_oneshot_toggle_compare.csv"
OUT_MD = ROOT / "summaries" / "gapbs_on_off_oneshot_toggle_compare.md"

BASE = Path("/Serverless/iccd/experiments/20260520-gapbs-ours-179-compare/summaries/gapbs_178off_179on_179ours.csv")
ONESHOT5 = Path("/Serverless/iccd/experiments/20260520-gapbs-ours-179-compare/summaries/gapbs_ours179_summary.csv")
BC_ONESHOT = Path("/Serverless/iccd/experiments/20260520-bc-ours179-window10-20/summaries/bc_ours179_window5_10_20_compare.csv")
TOGGLE = ROOT / "summaries" / "gapbs_toggle_ours_window_sweep_summary.csv"


def read_rows(path):
    with path.open(newline="") as handle:
        return list(csv.DictReader(handle))


def fmt(value):
    if value is None or value == "":
        return "n/a"
    return f"{float(value):.5f}"


def ms_to_s(value):
    if value is None or value == "":
        return ""
    return f"{float(value) / 1000.0:.3f}"


def main():
    off_on = {}
    for row in read_rows(BASE):
        policy = row["kernel_policy"]
        if policy == "#178 off":
            off_on[(row["workload"], row["cap"], "off")] = row["avg_trial_s"]
        elif policy == "#179 on":
            off_on[(row["workload"], row["cap"], "on")] = row["avg_trial_s"]

    oneshot = {}
    oneshot_stop = {}
    for row in read_rows(ONESHOT5):
        oneshot[(row["workload"], row["cap"], "5")] = row["avg_trial_s"]
        oneshot_stop[(row["workload"], row["cap"], "5")] = ms_to_s(row.get("stop_ms", ""))
    for row in read_rows(BC_ONESHOT):
        if row["workload"] != "bc":
            continue
        oneshot[(row["workload"], row["cap"], row["window_sec"])] = row["avg_trial_s"]
        oneshot_stop[(row["workload"], row["cap"], row["window_sec"])] = ms_to_s(row.get("stop_ms", ""))

    toggle = {}
    toggle_off = {}
    toggle_on = {}
    for row in read_rows(TOGGLE):
        key = (row["workload"], row["cap"], row["window_sec"])
        toggle[key] = row["avg_trial_s"]
        toggle_off[key] = ms_to_s(row.get("first_off_ms", ""))
        toggle_on[key] = ms_to_s(row.get("first_on_ms", ""))

    rows = []
    for workload in ("pr", "bc"):
        for cap in ("8g", "16g"):
            for window in ("5", "10", "20"):
                key = (workload, cap, window)
                rows.append({
                    "workload": workload,
                    "cap": cap,
                    "window_sec": window,
                    "off_avg_s": off_on.get((workload, cap, "off"), ""),
                    "on_avg_s": off_on.get((workload, cap, "on"), ""),
                    "oneshot_avg_s": oneshot.get(key, ""),
                    "oneshot_off_s": oneshot_stop.get(key, ""),
                    "toggle_avg_s": toggle.get(key, ""),
                    "toggle_off_s": toggle_off.get(key, ""),
                    "toggle_on_s": toggle_on.get(key, ""),
                })

    OUT_CSV.parent.mkdir(parents=True, exist_ok=True)
    fields = [
        "workload", "cap", "window_sec", "off_avg_s", "on_avg_s",
        "oneshot_avg_s", "oneshot_off_s", "toggle_avg_s",
        "toggle_off_s", "toggle_on_s",
    ]
    with OUT_CSV.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)

    lines = [
        "# GAPBS on/off vs one-shot ours vs toggle ours",
        "",
        "Values are GAPBS `Average Time` in seconds, lower is better.",
        "",
        "- `off`: #178 node-capacity off baseline used in the previous comparison.",
        "- `on`: #179 migration-on baseline.",
        "- `one-shot`: #179 one-shot local-util `ours`; PR has #179 5s only, BC has #179 5/10/20.",
        "- `toggle`: #179 controller that re-enables migration after 2 non-matching windows.",
        "",
    ]
    for workload in ("pr", "bc"):
        lines += [
            f"## {workload.upper()}",
            "",
            "| cap | window | off | on | one-shot | one-shot off s | toggle | toggle off->on s |",
            "| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
        ]
        for row in [r for r in rows if r["workload"] == workload]:
            transition = ""
            if row["toggle_off_s"] or row["toggle_on_s"]:
                transition = f"{row['toggle_off_s']} -> {row['toggle_on_s']}"
            lines.append(
                f"| {row['cap']} | {row['window_sec']} | {fmt(row['off_avg_s'])} | "
                f"{fmt(row['on_avg_s'])} | {fmt(row['oneshot_avg_s'])} | "
                f"{row['oneshot_off_s'] or 'n/a'} | {fmt(row['toggle_avg_s'])} | "
                f"{transition or 'n/a'} |"
            )
        lines.append("")

    OUT_MD.write_text("\n".join(lines), encoding="ascii")
    print(OUT_CSV)
    print(OUT_MD)


if __name__ == "__main__":
    main()
