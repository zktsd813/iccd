#!/usr/bin/env python3
import argparse
import csv
import re
from pathlib import Path


MODE_ORDER = {"all_slow": 0, "half_local": 1}
MODE_LABELS = {
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


def to_int(value, default=0):
    try:
        text = str(value).strip().replace(",", "")
        if text == "":
            return default
        return int(float(text))
    except (TypeError, ValueError):
        return default


def mem_to_gib(value, default=0):
    text = str(value).strip()
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)G", text)
    if match:
        return float(match.group(1))
    match = re.fullmatch(r"([0-9]+)", text)
    if match:
        return float(match.group(1))
    return float(default)


def read_kv(path):
    data = {}
    if not path.exists():
        return data
    for line in path.read_text(errors="replace").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip()
    return data


def local_mem_gib_from_label(label):
    match = re.search(r"local-(\d+)G", label)
    if not match:
        return 0
    return int(match.group(1))


def load_summary(path):
    if not path.exists():
        return {}
    with path.open(newline="", errors="replace") as f:
        rows = list(csv.DictReader(f))
    by_policy = {}
    for row in rows:
        policy = row.get("policy") or row.get("case")
        if policy in {"off", "on"}:
            by_policy[policy] = row
    return by_policy


def pages_to_gib(value):
    return to_int(value) * 4096 / (1024 ** 3)


def make_row(mode, local_dir):
    by_policy = load_summary(local_dir / "summaries" / "summary.csv")
    off = by_policy.get("off")
    on = by_policy.get("on")
    if not off or not on:
        return None

    meta = read_kv(local_dir / "interleave.meta")
    local_gib = local_mem_gib_from_label(local_dir.name)
    if "local_mem" in meta:
        local_gib = int(mem_to_gib(meta["local_mem"], local_gib))

    initial_local_gib = mem_to_gib(meta.get("initial_local_hotset", "0G"))
    initial_slow_gib = mem_to_gib(meta.get("initial_slow_hotset", "32G"))
    off_elapsed = to_float(off.get("elapsed_s"))
    on_elapsed = to_float(on.get("elapsed_s"))
    off_mops = to_float(off.get("ops_per_s")) / 1_000_000.0
    on_mops = to_float(on.get("ops_per_s")) / 1_000_000.0
    demoted_pages = (
        to_int(on.get("pgdemote_direct_delta"))
        + to_int(on.get("pgdemote_kswapd_delta"))
    )

    return {
        "mode": mode,
        "mode_label": MODE_LABELS.get(mode, mode),
        "local_mem_gib": local_gib,
        "case_dir": f"{mode}/{local_dir.name}",
        "placement_mode": meta.get("placement_mode", ""),
        "window_split_local_gib": mem_to_gib(meta.get("window_split_local", "0G")),
        "initial_local_hotset_gib": initial_local_gib,
        "initial_slow_hotset_gib": initial_slow_gib,
        "initial_local_hotset_pct": initial_local_gib / 32.0 * 100.0,
        "target_ops": to_int(on.get("target_ops")),
        "off_elapsed_s": off_elapsed,
        "on_elapsed_s": on_elapsed,
        "time_ratio_on_off": on_elapsed / off_elapsed if off_elapsed > 0 else 0.0,
        "off_mops": off_mops,
        "on_mops": on_mops,
        "throughput_ratio_on_off": on_mops / off_mops if off_mops > 0 else 0.0,
        "on_user_cpu_s": to_float(on.get("user_cpu_s")),
        "on_system_cpu_s": to_float(on.get("system_cpu_s")),
        "on_numa_hint_faults": to_int(on.get("numa_hint_faults_delta")),
        "on_numa_hint_faults_local": to_int(on.get("numa_hint_faults_local_delta")),
        "on_numa_pages_migrated": to_int(on.get("numa_pages_migrated_delta")),
        "on_migrated_gib": pages_to_gib(on.get("numa_pages_migrated_delta")),
        "on_pgpromote_success": to_int(on.get("pgpromote_success_delta")),
        "on_pgdemote_direct": to_int(on.get("pgdemote_direct_delta")),
        "on_pgdemote_kswapd": to_int(on.get("pgdemote_kswapd_delta")),
        "on_pgdemote_total": demoted_pages,
        "on_demoted_gib": demoted_pages * 4096 / (1024 ** 3),
        "on_pgfault": to_int(on.get("pgfault_delta")),
        "on_pgmajfault": to_int(on.get("pgmajfault_delta")),
        "on_memory_psi_some_s": to_float(on.get("memory_psi_some_delta_us")) / 1_000_000.0,
        "on_memory_psi_full_s": to_float(on.get("memory_psi_full_delta_us")) / 1_000_000.0,
    }


def row_sort_key(row):
    return (MODE_ORDER.get(row["mode"], 99), row["local_mem_gib"])


def write_csv(rows, output):
    fields = [
        "mode",
        "mode_label",
        "local_mem_gib",
        "case_dir",
        "placement_mode",
        "window_split_local_gib",
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
        "on_numa_hint_faults_local",
        "on_numa_pages_migrated",
        "on_migrated_gib",
        "on_pgpromote_success",
        "on_pgdemote_direct",
        "on_pgdemote_kswapd",
        "on_pgdemote_total",
        "on_demoted_gib",
        "on_pgfault",
        "on_pgmajfault",
        "on_memory_psi_some_s",
        "on_memory_psi_full_s",
    ]
    with output.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def write_summary_ko(rows, output):
    with output.open("w") as f:
        f.write("# Interleave initial placement sweep 결과 요약\n\n")
        target_ops = rows[0]["target_ops"] if rows else 0
        f.write("설정: hotset/window 32G, shared-window, 32 threads, fixed target ops.\n")
        if target_ops:
            f.write(f"공통 target ops: `{target_ops}`.\n")
        f.write("`all_slow`는 32G 전체를 node1 slow에 first-touch하고 시작한다.\n")
        f.write("`half_local`은 local memory size의 절반만 node0 local에 first-touch하고 시작한다.\n")
        f.write("Linux MPOL_INTERLEAVE 정책은 사용하지 않는다.\n\n")
        f.write("| mode | local GiB | initial local GiB | off elapsed (s) | on elapsed (s) | time ratio | off Mops/s | on Mops/s | migrated GiB | demoted GiB | hint faults | system CPU (s) |\n")
        f.write("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n")
        for row in rows:
            f.write(
                f"| {row['mode']} | {row['local_mem_gib']} | "
                f"{row['initial_local_hotset_gib']:.1f} | "
                f"{row['off_elapsed_s']:.3f} | {row['on_elapsed_s']:.3f} | "
                f"{row['time_ratio_on_off']:.3f}x | "
                f"{row['off_mops']:.1f} | {row['on_mops']:.1f} | "
                f"{row['on_migrated_gib']:.2f} | {row['on_demoted_gib']:.2f} | "
                f"{row['on_numa_hint_faults']} | {row['on_system_cpu_s']:.2f} |\n"
            )
        if rows:
            worst = max(rows, key=lambda r: r["time_ratio_on_off"])
            most_migrated = max(rows, key=lambda r: r["on_migrated_gib"])
            f.write("\n## 해석 포인트\n\n")
            f.write(
                f"- 가장 큰 on/off time ratio는 `{worst['mode']}` local "
                f"{worst['local_mem_gib']}G의 `{worst['time_ratio_on_off']:.3f}x`이다.\n"
            )
            f.write(
                f"- migration on에서 가장 많이 migrate된 조건은 `{most_migrated['mode']}` "
                f"local {most_migrated['local_mem_gib']}G의 "
                f"`{most_migrated['on_migrated_gib']:.2f} GiB`이다.\n"
            )
            f.write("- migration stat은 vmstat delta 기준이며 demotion은 `pgdemote_direct + pgdemote_kswapd`이다.\n")


def try_import_matplotlib():
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt

        return plt
    except Exception:
        return None


def save_figure(fig, output_base):
    fig.savefig(output_base.with_suffix(".svg"), bbox_inches="tight")
    fig.savefig(output_base.with_suffix(".pdf"), bbox_inches="tight")


def group_by_mode(rows):
    grouped = {}
    for row in rows:
        grouped.setdefault(row["mode"], []).append(row)
    for mode_rows in grouped.values():
        mode_rows.sort(key=lambda row: row["local_mem_gib"])
    return grouped


def write_figures(rows, figure_dir):
    plt = try_import_matplotlib()
    if plt is None or not rows:
        return

    grouped = group_by_mode(rows)
    colors = {
        "all_slow": "#4C78A8",
        "half_local": "#F58518",
    }

    fig, ax = plt.subplots(figsize=(7.4, 3.8))
    for mode, mode_rows in grouped.items():
        xs = [row["local_mem_gib"] for row in mode_rows]
        label = MODE_LABELS.get(mode, mode)
        ax.plot(xs, [row["off_elapsed_s"] for row in mode_rows],
                marker="o", linestyle="--", color=colors.get(mode),
                label=f"{label} off")
        ax.plot(xs, [row["on_elapsed_s"] for row in mode_rows],
                marker="o", linestyle="-", color=colors.get(mode),
                label=f"{label} on")
    ax.set_xlabel("Local memory size (GiB)")
    ax.set_ylabel("Execution time for fixed ops (s)")
    ax.set_title("Initial hotset placement execution time")
    ax.grid(axis="y", color="#dddddd", linewidth=0.6)
    ax.set_axisbelow(True)
    ax.legend()
    fig.tight_layout()
    save_figure(fig, figure_dir / "interleave_execution_time")
    plt.close(fig)

    fig, ax = plt.subplots(figsize=(7.4, 3.8))
    for mode, mode_rows in grouped.items():
        xs = [row["local_mem_gib"] for row in mode_rows]
        ratios = [row["time_ratio_on_off"] for row in mode_rows]
        ax.plot(xs, ratios, marker="o", linewidth=2.0,
                color=colors.get(mode), label=MODE_LABELS.get(mode, mode))
        for x, ratio in zip(xs, ratios):
            ax.text(x, ratio, f"{ratio:.2f}x", ha="center", va="bottom", fontsize=8)
    ax.set_xlabel("Local memory size (GiB)")
    ax.set_ylabel("Execution time ratio (on/off)")
    ax.set_title("Migration slowdown by initial hotset placement")
    ax.grid(axis="y", color="#dddddd", linewidth=0.6)
    ax.set_axisbelow(True)
    ax.legend()
    fig.tight_layout()
    save_figure(fig, figure_dir / "interleave_slowdown_ratio")
    plt.close(fig)

    fig, axes = plt.subplots(2, 2, figsize=(8.6, 5.6), sharex=True)
    axes = axes.flatten()
    metrics = [
        ("on_migrated_gib", "Migrated GiB"),
        ("on_demoted_gib", "Demoted GiB"),
        ("on_numa_hint_faults", "NUMA hint faults"),
        ("on_system_cpu_s", "System CPU time (s)"),
    ]
    for ax, (field, ylabel) in zip(axes, metrics):
        for mode, mode_rows in grouped.items():
            xs = [row["local_mem_gib"] for row in mode_rows]
            values = [row[field] for row in mode_rows]
            if field == "on_numa_hint_faults":
                values = [value / 1_000_000.0 for value in values]
                ylabel = "NUMA hint faults (M)"
            ax.plot(xs, values, marker="o", linewidth=2.0,
                    color=colors.get(mode), label=MODE_LABELS.get(mode, mode))
        ax.set_ylabel(ylabel)
        ax.grid(axis="y", color="#dddddd", linewidth=0.6)
        ax.set_axisbelow(True)
    for ax in axes[-2:]:
        ax.set_xlabel("Local memory size (GiB)")
    axes[0].legend()
    fig.suptitle("Migration activity by initial hotset placement")
    fig.tight_layout()
    save_figure(fig, figure_dir / "interleave_migration_activity")
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("exp_root", type=Path)
    parser.add_argument("--summary-dir", type=Path)
    parser.add_argument("--figure-dir", type=Path)
    args = parser.parse_args()

    exp_root = args.exp_root
    summary_dir = args.summary_dir or exp_root / "summaries"
    figure_dir = args.figure_dir or exp_root / "figures"
    summary_dir.mkdir(parents=True, exist_ok=True)
    figure_dir.mkdir(parents=True, exist_ok=True)

    rows = []
    for mode_dir in sorted(exp_root.iterdir() if exp_root.exists() else []):
        if not mode_dir.is_dir():
            continue
        mode = mode_dir.name
        for local_dir in sorted(mode_dir.glob("local-*G")):
            if not local_dir.is_dir():
                continue
            row = make_row(mode, local_dir)
            if row is not None:
                rows.append(row)
    rows.sort(key=row_sort_key)

    write_csv(rows, summary_dir / "interleave_sweep.csv")
    write_summary_ko(rows, summary_dir / "summary_ko.md")
    write_figures(rows, figure_dir)


if __name__ == "__main__":
    main()
