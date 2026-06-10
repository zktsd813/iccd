#!/usr/bin/env python3
import argparse
import csv
import re
from pathlib import Path


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


def make_row(local_dir):
    by_policy = load_summary(local_dir / "summaries" / "summary.csv")
    off = by_policy.get("off")
    on = by_policy.get("on")
    if not off or not on:
        return None

    meta = read_kv(local_dir / "local_mem.meta")
    local_gib = local_mem_gib_from_label(local_dir.name)
    if "local_mem" in meta:
        local_gib = to_int(str(meta["local_mem"]).rstrip("G"), local_gib)

    off_elapsed = to_float(off.get("elapsed_s"))
    on_elapsed = to_float(on.get("elapsed_s"))
    off_mops = to_float(off.get("ops_per_s")) / 1_000_000.0
    on_mops = to_float(on.get("ops_per_s")) / 1_000_000.0
    demoted_pages = (
        to_int(on.get("pgdemote_direct_delta"))
        + to_int(on.get("pgdemote_kswapd_delta"))
    )

    return {
        "local_mem_gib": local_gib,
        "case_dir": local_dir.name,
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


def write_csv(rows, output):
    fields = [
        "local_mem_gib",
        "case_dir",
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
        f.write("# Shared 32-thread local memory sweep 결과 요약\n\n")
        target_ops = rows[0]["target_ops"] if rows else 0
        f.write("설정: hotset 32G, shared-window, 32 threads, fixed target ops.\n")
        if target_ops:
            f.write(f"공통 target ops: `{target_ops}`.\n")
        f.write("32G point는 remote split이 없으므로 `bind:0` placement를 사용한다.\n\n")
        f.write("| local GiB | off elapsed (s) | on elapsed (s) | time ratio | off Mops/s | on Mops/s | migrated GiB | demoted GiB | hint faults | system CPU (s) |\n")
        f.write("|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n")
        for row in rows:
            f.write(
                f"| {row['local_mem_gib']} | "
                f"{row['off_elapsed_s']:.3f} | {row['on_elapsed_s']:.3f} | "
                f"{row['time_ratio_on_off']:.3f}x | "
                f"{row['off_mops']:.1f} | {row['on_mops']:.1f} | "
                f"{row['on_migrated_gib']:.2f} | {row['on_demoted_gib']:.2f} | "
                f"{row['on_numa_hint_faults']} | {row['on_system_cpu_s']:.2f} |\n"
            )
        if rows:
            worst = max(rows, key=lambda r: r["time_ratio_on_off"])
            best = max(rows, key=lambda r: r["on_mops"])
            f.write("\n## 해석 포인트\n\n")
            f.write(
                f"- 가장 큰 on/off time ratio는 local {worst['local_mem_gib']}G의 "
                f"`{worst['time_ratio_on_off']:.3f}x`이다.\n"
            )
            f.write(
                f"- migration on 처리량이 가장 높은 조건은 local {best['local_mem_gib']}G의 "
                f"`{best['on_mops']:.1f} Mops/s`이다.\n"
            )
            f.write("- scan period/scan size 계열 knob은 쓰지 않고 kernel 기본값을 기록만 한다.\n")
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


def write_figures(rows, figure_dir):
    plt = try_import_matplotlib()
    if plt is None or not rows:
        return

    xs = [row["local_mem_gib"] for row in rows]
    pos = list(range(len(xs)))
    width = 0.36

    fig, ax = plt.subplots(figsize=(7.4, 3.8))
    off_values = [row["off_elapsed_s"] for row in rows]
    on_values = [row["on_elapsed_s"] for row in rows]
    ax.bar([x - width / 2 for x in pos], off_values, width, label="off",
           color="#4C78A8", edgecolor="#222222", linewidth=0.6)
    ax.bar([x + width / 2 for x in pos], on_values, width, label="on",
           color="#F58518", edgecolor="#222222", linewidth=0.6)
    ax.set_xticks(pos)
    ax.set_xticklabels([str(x) for x in xs])
    ax.set_xlabel("Local memory size (GiB)")
    ax.set_ylabel("Execution time for fixed ops (s)")
    ax.set_title("Shared 32-thread local memory sweep")
    ax.grid(axis="y", color="#dddddd", linewidth=0.6)
    ax.set_axisbelow(True)
    ax.legend()
    fig.tight_layout()
    save_figure(fig, figure_dir / "localmem_execution_time")
    plt.close(fig)

    fig, ax1 = plt.subplots(figsize=(7.4, 3.8))
    ratios = [row["time_ratio_on_off"] for row in rows]
    ax1.plot(xs, ratios, marker="o", color="#E45756", linewidth=2.0,
             label="time ratio on/off")
    ax1.set_xlabel("Local memory size (GiB)")
    ax1.set_ylabel("Execution time ratio")
    ax1.grid(axis="y", color="#dddddd", linewidth=0.6)
    ax1.set_axisbelow(True)
    for x, ratio in zip(xs, ratios):
        ax1.text(x, ratio, f"{ratio:.3f}x", ha="center", va="bottom", fontsize=8)
    ax2 = ax1.twinx()
    ax2.bar(xs, [row["on_migrated_gib"] for row in rows], width=2.0,
            color="#72B7B2", alpha=0.30, label="migrated GiB")
    ax2.set_ylabel("Migrated GiB")
    ax1.set_title("Migration impact by local memory size")
    lines1, labels1 = ax1.get_legend_handles_labels()
    lines2, labels2 = ax2.get_legend_handles_labels()
    ax1.legend(lines1 + lines2, labels1 + labels2, loc="best")
    fig.tight_layout()
    save_figure(fig, figure_dir / "localmem_ratio_migration")
    plt.close(fig)

    fig, ax1 = plt.subplots(figsize=(7.4, 3.8))
    ax1.plot(xs, [row["on_system_cpu_s"] for row in rows], marker="o",
             color="#54A24B", linewidth=2.0, label="system CPU s")
    ax1.set_xlabel("Local memory size (GiB)")
    ax1.set_ylabel("System CPU time (s)")
    ax1.grid(axis="y", color="#dddddd", linewidth=0.6)
    ax1.set_axisbelow(True)
    ax2 = ax1.twinx()
    ax2.bar(xs, [row["on_numa_hint_faults"] / 1_000_000.0 for row in rows],
            width=2.0, color="#B279A2", alpha=0.30, label="hint faults (M)")
    ax2.set_ylabel("NUMA hint faults (M)")
    ax1.set_title("Kernel activity by local memory size")
    lines1, labels1 = ax1.get_legend_handles_labels()
    lines2, labels2 = ax2.get_legend_handles_labels()
    ax1.legend(lines1 + lines2, labels1 + labels2, loc="best")
    fig.tight_layout()
    save_figure(fig, figure_dir / "localmem_kernel_activity")
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
    for local_dir in sorted(exp_root.glob("local-*G")):
        if not local_dir.is_dir():
            continue
        row = make_row(local_dir)
        if row is not None:
            rows.append(row)
    rows.sort(key=lambda row: row["local_mem_gib"])

    write_csv(rows, summary_dir / "local_mem_sweep.csv")
    write_summary_ko(rows, summary_dir / "summary_ko.md")
    write_figures(rows, figure_dir)


if __name__ == "__main__":
    main()
