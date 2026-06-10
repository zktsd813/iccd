#!/usr/bin/env python3
import argparse
import csv
import re
from pathlib import Path


TARGET_RE = re.compile(
    r"target_ops=(?P<target_ops>\d+)\s+"
    r"total_ops=(?P<total_ops>\d+)\s+"
    r"elapsed_s=(?P<elapsed_s>[0-9.]+)\s+"
    r"ns_per_op=(?P<ns_per_op>[0-9.]+)\s+"
    r"ops_per_s=(?P<ops_per_s>[0-9.]+)"
)
OPS_200_RE = re.compile(
    r"ops_200s=(?P<ops_200s>\d+)\s+"
    r"total_ops=(?P<total_ops>\d+)\s+"
    r"elapsed_s=(?P<elapsed_s>[0-9.]+)"
)
STAGE_RE = re.compile(r"mm_migrate_stage:\s+(?P<body>.*)$")
KV_RE = re.compile(r"([A-Za-z0-9_]+)=([^ \n]+)")
THREAD_POLICY_RE = re.compile(r"^t(?P<threads>\d+)_(?P<policy>off|on|off_trace|on_trace)$")


VMSTAT_KEYS = [
    "numa_hint_faults",
    "numa_hint_faults_local",
    "numa_pages_migrated",
    "pgpromote_success",
    "pgdemote_direct",
    "pgdemote_kswapd",
    "pgfault",
    "pgmajfault",
]


def to_int(value, default=0):
    try:
        return int(str(value).strip().replace(",", ""))
    except (TypeError, ValueError):
        return default


def to_float(value, default=0.0):
    try:
        text = str(value).strip().replace(",", "")
        if text in {"", "<not counted>", "<not supported>"}:
            return default
        return float(text)
    except (TypeError, ValueError):
        return default


def parse_kv_body(body):
    return {key: value for key, value in KV_RE.findall(body)}


def read_text(path):
    if not path.exists():
        return ""
    return path.read_text(errors="replace")


def read_vmstat(path):
    data = {}
    for line in read_text(path).splitlines():
        parts = line.split()
        if len(parts) == 2:
            data[parts[0]] = to_int(parts[1])
    return data


def vmstat_delta(case_dir, key):
    before = read_vmstat(case_dir / "before.vmstat")
    after = read_vmstat(case_dir / "after.vmstat")
    return after.get(key, 0) - before.get(key, 0)


def read_pressure(path):
    data = {}
    for line in read_text(path).splitlines():
        parts = line.split()
        if not parts:
            continue
        label = parts[0]
        item = {}
        for field in parts[1:]:
            if "=" not in field:
                continue
            key, value = field.split("=", 1)
            item[key] = to_float(value)
        data[label] = item
    return data


def pressure_delta_us(case_dir, label):
    before = read_pressure(case_dir / "before.pressure.memory")
    after = read_pressure(case_dir / "after.pressure.memory")
    return after.get(label, {}).get("total", 0.0) - before.get(label, {}).get("total", 0.0)


def parse_time(path):
    row = {
        "user_cpu_s": 0.0,
        "system_cpu_s": 0.0,
        "elapsed_wall_time": "",
        "max_rss_kb": 0,
        "voluntary_context_switches": 0,
        "involuntary_context_switches": 0,
    }
    for line in read_text(path).splitlines():
        stripped = line.strip()
        if stripped.startswith("User time (seconds):"):
            row["user_cpu_s"] = to_float(stripped.split(":", 1)[1])
        elif stripped.startswith("System time (seconds):"):
            row["system_cpu_s"] = to_float(stripped.split(":", 1)[1])
        elif stripped.startswith("Elapsed (wall clock) time"):
            row["elapsed_wall_time"] = stripped.split(":", 1)[1].strip()
        elif stripped.startswith("Maximum resident set size"):
            row["max_rss_kb"] = to_int(stripped.split(":", 1)[1])
        elif stripped.startswith("Voluntary context switches"):
            row["voluntary_context_switches"] = to_int(stripped.split(":", 1)[1])
        elif stripped.startswith("Involuntary context switches"):
            row["involuntary_context_switches"] = to_int(stripped.split(":", 1)[1])
    return row


def parse_perf_csv(path):
    metrics = {}
    if not path.exists():
        return metrics
    with path.open(errors="replace") as f:
        for row in csv.reader(f):
            if len(row) < 3:
                continue
            value = row[0].strip()
            event = row[2].strip()
            if not event or value.startswith("#"):
                continue
            metrics[event] = to_float(value)
    return metrics


def parse_mbench_summary(path):
    text = read_text(path)
    for match in TARGET_RE.finditer(text):
        data = match.groupdict()
        return {
            "target_ops": to_int(data["target_ops"]),
            "total_ops": to_int(data["total_ops"]),
            "elapsed_s": to_float(data["elapsed_s"]),
            "ns_per_op": to_float(data["ns_per_op"]),
            "ops_per_s": to_float(data["ops_per_s"]),
            "fixed_ops": 1,
        }
    for match in OPS_200_RE.finditer(text):
        data = match.groupdict()
        elapsed_s = to_float(data["elapsed_s"])
        total_ops = to_int(data["total_ops"])
        return {
            "target_ops": 0,
            "total_ops": total_ops,
            "elapsed_s": elapsed_s,
            "ns_per_op": (elapsed_s * 1e9 / total_ops) if total_ops > 0 else 0.0,
            "ops_per_s": (total_ops / elapsed_s) if elapsed_s > 0 else 0.0,
            "fixed_ops": 0,
        }
    return {
        "target_ops": 0,
        "total_ops": 0,
        "elapsed_s": 0.0,
        "ns_per_op": 0.0,
        "ops_per_s": 0.0,
        "fixed_ops": 0,
    }


def parse_run_config(path):
    text = read_text(path)
    row = {
        "threads": 0,
        "policy": "",
        "bw_shared_window": 0,
    }
    match = re.search(r"total_threads=(\d+)", text)
    if match:
        row["threads"] = to_int(match.group(1))
    match = re.search(r"bw_shared_window=(\d+)", text)
    if match:
        row["bw_shared_window"] = to_int(match.group(1))
    return row


def infer_case_fields(case_name, row):
    match = THREAD_POLICY_RE.match(case_name)
    if match:
        row["threads"] = to_int(match.group("threads"), row.get("threads", 0))
        row["policy"] = match.group("policy")
        return
    if not row.get("policy"):
        if case_name in {"off", "on", "off_trace", "on_trace"}:
            row["policy"] = case_name
        elif case_name.endswith("_off"):
            row["policy"] = "off"
        elif case_name.endswith("_on"):
            row["policy"] = "on"


def parse_stage_events(case_dir):
    events = []
    trace_path = case_dir / "trace.txt"
    if not trace_path.exists():
        return events
    with trace_path.open(errors="replace") as f:
        for line in f:
            match = STAGE_RE.search(line)
            if not match:
                continue
            item = parse_kv_body(match.group("body"))
            item["duration_ns"] = to_int(item.get("duration_ns"))
            item["nr_pages"] = max(1, to_int(item.get("nr_pages"), 1))
            item["rc"] = to_int(item.get("rc"))
            events.append(item)
    return events


def count_trace_lines(case_dir, needle):
    trace_path = case_dir / "trace.txt"
    if not trace_path.exists():
        return 0
    count = 0
    with trace_path.open(errors="replace") as f:
        for line in f:
            if needle in line:
                count += 1
    return count


def aggregate_stage_rows(case_dirs):
    rows = {}
    for case_dir in case_dirs:
        for event in parse_stage_events(case_dir):
            key = (
                case_dir.name,
                event.get("reason", "unknown"),
                event.get("mode", "unknown"),
                event.get("stage", "unknown"),
            )
            row = rows.setdefault(
                key,
                {
                    "case": case_dir.name,
                    "reason": event.get("reason", "unknown"),
                    "mode": event.get("mode", "unknown"),
                    "stage": event.get("stage", "unknown"),
                    "count": 0,
                    "total_pages": 0,
                    "total_ns": 0,
                    "rc_nonzero": 0,
                },
            )
            row["count"] += 1
            row["total_pages"] += event["nr_pages"]
            row["total_ns"] += event["duration_ns"]
            row["rc_nonzero"] += 1 if event["rc"] != 0 else 0
    return rows


def case_summary(case_dir):
    row = {
        "case": case_dir.name,
        **parse_mbench_summary(case_dir / "stderr.txt"),
        **parse_run_config(case_dir / "stderr.txt"),
        **parse_time(case_dir / "time.txt"),
    }
    infer_case_fields(case_dir.name, row)
    perf = parse_perf_csv(case_dir / "perf.csv")
    for key, value in perf.items():
        row[f"perf_{key}"] = value
    for key in VMSTAT_KEYS:
        row[f"{key}_delta"] = vmstat_delta(case_dir, key)
    row["memory_psi_some_delta_us"] = pressure_delta_us(case_dir, "some")
    row["memory_psi_full_delta_us"] = pressure_delta_us(case_dir, "full")
    row["trace_mm_migrate_pages_events"] = count_trace_lines(case_dir, "mm_migrate_pages:")
    row["trace_tlb_flush_events"] = count_trace_lines(case_dir, "tlb_flush:")
    return row


def write_csv(rows, output):
    fields = []
    for row in rows:
        for key in row:
            if key not in fields:
                fields.append(key)
    with output.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def write_stage_csv(stage_rows, output):
    fields = [
        "case",
        "reason",
        "mode",
        "stage",
        "count",
        "total_pages",
        "total_ns",
        "total_ms",
        "avg_ns_per_page",
        "rc_nonzero",
    ]
    with output.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for row in sorted(stage_rows.values(), key=lambda r: (r["case"], r["stage"])):
            total_pages = max(1, row["total_pages"])
            writer.writerow(
                {
                    **row,
                    "total_ms": row["total_ns"] / 1_000_000.0,
                    "avg_ns_per_page": row["total_ns"] / total_pages,
                }
            )


def index_rows(rows):
    return {row["case"]: row for row in rows}


def sum_stage_seconds(stage_rows, case):
    total_ns = sum(row["total_ns"] for row in stage_rows.values() if row["case"] == case)
    return total_ns / 1_000_000_000.0


def write_summary_md(rows, stage_rows, output):
    by_case = index_rows(rows)
    off = by_case.get("off")
    on = by_case.get("on")
    on_trace = by_case.get("on_trace")
    with output.open("w") as f:
        f.write("# Fixed-Ops Microbenchmark Migration Overhead\n\n")
        f.write("Workload: `stream_read_32g_split16_4kstride`.\n\n")
        if off and on and off["elapsed_s"] > 0:
            slowdown = on["elapsed_s"] / off["elapsed_s"]
            extra = on["elapsed_s"] - off["elapsed_s"]
            f.write("## Headline\n\n")
            f.write(f"- off elapsed: `{off['elapsed_s']:.3f}s`\n")
            f.write(f"- on elapsed: `{on['elapsed_s']:.3f}s`\n")
            f.write(f"- on/off execution-time ratio: `{slowdown:.3f}x`\n")
            f.write(f"- extra wall time with migration on: `{extra:.3f}s`\n")
            f.write(
                f"- on migrated pages: `{on.get('numa_pages_migrated_delta', 0)}` "
                f"({on.get('numa_pages_migrated_delta', 0) * 4096 / (1024 ** 3):.2f} GiB)\n"
            )
            f.write(f"- on NUMA hint faults: `{on.get('numa_hint_faults_delta', 0)}`\n\n")
        f.write("## Case Metrics\n\n")
        f.write("| case | target_ops | elapsed_s | ns/op | system_cpu_s | hint_faults | migrated_GiB | psi_some_s |\n")
        f.write("|---|---:|---:|---:|---:|---:|---:|---:|\n")
        for row in rows:
            migrated_gib = row.get("numa_pages_migrated_delta", 0) * 4096 / (1024 ** 3)
            f.write(
                f"| {row['case']} | {row.get('target_ops', 0)} | "
                f"{row.get('elapsed_s', 0.0):.3f} | {row.get('ns_per_op', 0.0):.3f} | "
                f"{row.get('system_cpu_s', 0.0):.3f} | "
                f"{row.get('numa_hint_faults_delta', 0)} | {migrated_gib:.2f} | "
                f"{row.get('memory_psi_some_delta_us', 0.0) / 1_000_000.0:.3f} |\n"
            )
        if on_trace:
            f.write("\n## Attribution Notes\n\n")
            f.write(
                f"- `on_trace` traced migration stage time: "
                f"`{sum_stage_seconds(stage_rows, 'on_trace'):.6f}s`.\n"
            )
            f.write(
                "- Headline off/on bars use trace-disabled runs; trace-enabled data is only "
                "for attribution because ftrace can perturb runtime.\n"
            )
            f.write(
                "- `system_cpu_s` is CPU time across threads and is intentionally not stacked "
                "inside wall-clock execution time.\n"
            )


def load_stdout_samples(case_dir):
    path = case_dir / "stdout.txt"
    samples = []
    if not path.exists():
        return samples
    with path.open(errors="replace") as f:
        reader = csv.DictReader(f)
        for row in reader:
            if "time_ms" not in row:
                return []
            samples.append(
                {
                    "time_ms": to_float(row.get("time_ms")),
                    "ops_total": to_float(row.get("ops_total")),
                    "ops_delta": to_float(row.get("ops_delta")),
                    "bytes_total": to_float(row.get("bytes_total")),
                    "bytes_delta": to_float(row.get("bytes_delta")),
                }
            )
    return samples


def load_monitor_samples(case_dir):
    path = case_dir / "monitor.csv"
    samples = []
    if not path.exists():
        return samples
    with path.open(errors="replace") as f:
        for row in csv.DictReader(f):
            item = {key: to_float(value) for key, value in row.items()}
            samples.append(item)
    return samples


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


def plot_execution_time(rows, figure_dir):
    plt = try_import_matplotlib()
    if plt is None:
        return
    by_case = index_rows(rows)
    labels = [case for case in ["off", "on", "on_trace", "off_trace"] if case in by_case]
    if not labels:
        return
    values = [by_case[label].get("elapsed_s", 0.0) for label in labels]
    fig, ax = plt.subplots(figsize=(6.2, 3.4))
    colors = ["#4C78A8", "#F58518", "#E45756", "#72B7B2"][: len(labels)]
    bars = ax.bar(labels, values, color=colors, edgecolor="#222222", linewidth=0.6)
    ax.set_ylabel("Execution time for fixed ops (s)")
    ax.set_title("Fixed-ops unfriendly microbenchmark")
    ax.grid(axis="y", color="#dddddd", linewidth=0.6)
    ax.set_axisbelow(True)
    for bar, value in zip(bars, values):
        ax.text(bar.get_x() + bar.get_width() / 2.0, value, f"{value:.2f}s",
                ha="center", va="bottom", fontsize=9)
    if "off" in by_case and "on" in by_case and by_case["off"].get("elapsed_s", 0.0) > 0:
        slowdown = by_case["on"]["elapsed_s"] / by_case["off"]["elapsed_s"]
        ax.text(0.5, 0.94, f"on/off = {slowdown:.3f}x",
                transform=ax.transAxes, ha="center", va="top", fontsize=10)
    fig.tight_layout()
    save_figure(fig, figure_dir / "fixed_ops_execution_time")
    plt.close(fig)


def plot_side_metrics(rows, stage_rows, figure_dir):
    plt = try_import_matplotlib()
    if plt is None:
        return
    by_case = index_rows(rows)
    off = by_case.get("off")
    on = by_case.get("on")
    metrics = []
    if off and on:
        metrics.append(("extra wall", max(0.0, on["elapsed_s"] - off["elapsed_s"])))
        metrics.append(("on system CPU", on.get("system_cpu_s", 0.0)))
        metrics.append(("on PSI some", on.get("memory_psi_some_delta_us", 0.0) / 1_000_000.0))
    if "on_trace" in by_case:
        metrics.append(("trace migration", sum_stage_seconds(stage_rows, "on_trace")))
        metrics.append(("trace system CPU", by_case["on_trace"].get("system_cpu_s", 0.0)))
    if not metrics:
        return
    labels = [item[0] for item in metrics]
    values = [item[1] for item in metrics]
    fig, ax = plt.subplots(figsize=(7.0, 3.6))
    bars = ax.bar(labels, values, color="#54A24B", edgecolor="#222222", linewidth=0.6)
    ax.set_ylabel("Seconds")
    ax.set_title("Migration overhead side metrics")
    ax.grid(axis="y", color="#dddddd", linewidth=0.6)
    ax.set_axisbelow(True)
    ax.tick_params(axis="x", rotation=20)
    for bar, value in zip(bars, values):
        ax.text(bar.get_x() + bar.get_width() / 2.0, value, f"{value:.3f}",
                ha="center", va="bottom", fontsize=8)
    fig.tight_layout()
    save_figure(fig, figure_dir / "migration_overhead_side_metrics")
    plt.close(fig)


def plot_timeline(outroot, figure_dir):
    plt = try_import_matplotlib()
    if plt is None:
        return
    case_dir = outroot / "on"
    if not case_dir.exists():
        case_dir = outroot / "on_trace"
    stdout_samples = load_stdout_samples(case_dir)
    monitor_samples = load_monitor_samples(case_dir)
    if not stdout_samples and not monitor_samples:
        return
    fig, ax1 = plt.subplots(figsize=(7.2, 3.6))
    if stdout_samples:
        xs = [row["time_ms"] / 1000.0 for row in stdout_samples]
        rates = []
        prev_t = None
        for row in stdout_samples:
            t = row["time_ms"] / 1000.0
            dt = max(1e-9, t - prev_t) if prev_t is not None else 1.0
            rates.append(row["ops_delta"] / dt / 1_000_000.0)
            prev_t = t
        ax1.plot(xs, rates, color="#4C78A8", label="Mops/s")
        ax1.set_ylabel("Mops/s")
    ax2 = ax1.twinx()
    if monitor_samples:
        xs2 = [row["time_ms"] / 1000.0 for row in monitor_samples]
        base_migrated = monitor_samples[0].get("numa_pages_migrated", 0.0)
        migrated_gib = [
            (row.get("numa_pages_migrated", 0.0) - base_migrated) * 4096 / (1024 ** 3)
            for row in monitor_samples
        ]
        ax2.plot(xs2, migrated_gib, color="#F58518", label="migrated GiB")
        ax2.set_ylabel("Migrated GiB")
    ax1.set_xlabel("Measured time (s)")
    ax1.set_title(f"Runtime timeline: {case_dir.name}")
    ax1.grid(axis="y", color="#dddddd", linewidth=0.6)
    lines, labels = ax1.get_legend_handles_labels()
    lines2, labels2 = ax2.get_legend_handles_labels()
    ax1.legend(lines + lines2, labels + labels2, loc="best")
    fig.tight_layout()
    save_figure(fig, figure_dir / "migration_activity_timeline")
    plt.close(fig)


def plot_thread_sweep(rows, figure_dir):
    plt = try_import_matplotlib()
    if plt is None:
        return

    grouped = {}
    for row in rows:
        threads = to_int(row.get("threads"))
        policy = row.get("policy", "")
        if threads <= 0 or policy not in {"off", "on"}:
            continue
        grouped.setdefault(threads, {})[policy] = row

    thread_counts = sorted(
        threads for threads, policies in grouped.items()
        if "off" in policies and "on" in policies
    )
    if len(thread_counts) < 2:
        return

    off_values = [grouped[t]["off"].get("elapsed_s", 0.0) for t in thread_counts]
    on_values = [grouped[t]["on"].get("elapsed_s", 0.0) for t in thread_counts]
    x_positions = list(range(len(thread_counts)))
    width = 0.36

    fig, ax = plt.subplots(figsize=(7.2, 3.8))
    off_bars = ax.bar([x - width / 2 for x in x_positions], off_values, width,
                      color="#4C78A8", edgecolor="#222222", linewidth=0.6,
                      label="off")
    on_bars = ax.bar([x + width / 2 for x in x_positions], on_values, width,
                     color="#F58518", edgecolor="#222222", linewidth=0.6,
                     label="on")
    ax.set_xticks(x_positions)
    ax.set_xticklabels([str(t) for t in thread_counts])
    ax.set_xlabel("Threads")
    ax.set_ylabel("Execution time for fixed ops (s)")
    ax.set_title("Shared-window fixed-ops sweep")
    ax.grid(axis="y", color="#dddddd", linewidth=0.6)
    ax.set_axisbelow(True)
    ax.legend()
    for bars in (off_bars, on_bars):
        for bar in bars:
            value = bar.get_height()
            ax.text(bar.get_x() + bar.get_width() / 2.0, value, f"{value:.1f}",
                    ha="center", va="bottom", fontsize=8)
    fig.tight_layout()
    save_figure(fig, figure_dir / "shared_window_thread_sweep_execution_time")
    plt.close(fig)

    ratios = []
    migrated = []
    for threads in thread_counts:
        off = grouped[threads]["off"]
        on = grouped[threads]["on"]
        off_ops = off.get("ops_per_s", 0.0)
        on_ops = on.get("ops_per_s", 0.0)
        ratios.append(on_ops / off_ops if off_ops > 0 else 0.0)
        migrated.append(on.get("numa_pages_migrated_delta", 0) * 4096 / (1024 ** 3))

    fig, ax1 = plt.subplots(figsize=(7.2, 3.8))
    ax1.plot(thread_counts, ratios, marker="o", color="#E45756", linewidth=2.0,
             label="on/off throughput")
    ax1.set_xscale("log", base=2)
    ax1.set_xticks(thread_counts)
    ax1.set_xticklabels([str(t) for t in thread_counts])
    ax1.set_xlabel("Threads")
    ax1.set_ylabel("Throughput ratio (on/off)")
    ax1.set_ylim(0, max(1.05, max(ratios) * 1.2))
    ax1.grid(axis="y", color="#dddddd", linewidth=0.6)
    ax1.set_axisbelow(True)
    for x, ratio in zip(thread_counts, ratios):
        ax1.text(x, ratio, f"{ratio:.3f}x", ha="center", va="bottom", fontsize=8)

    ax2 = ax1.twinx()
    ax2.bar(thread_counts, migrated, width=[max(0.25, t * 0.16) for t in thread_counts],
            color="#72B7B2", alpha=0.28, label="migrated GiB")
    ax2.set_ylabel("Migrated GiB")
    ax1.set_title("Shared-window migration impact by thread count")
    lines1, labels1 = ax1.get_legend_handles_labels()
    lines2, labels2 = ax2.get_legend_handles_labels()
    ax1.legend(lines1 + lines2, labels1 + labels2, loc="best")
    fig.tight_layout()
    save_figure(fig, figure_dir / "shared_window_thread_sweep_ratio")
    plt.close(fig)


def write_figures(outroot, rows, stage_rows, figure_dir):
    figure_dir.mkdir(parents=True, exist_ok=True)
    plot_execution_time(rows, figure_dir)
    plot_side_metrics(rows, stage_rows, figure_dir)
    plot_timeline(outroot, figure_dir)
    plot_thread_sweep(rows, figure_dir)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("outroot", type=Path)
    parser.add_argument("--summary-dir", type=Path)
    parser.add_argument("--figure-dir", type=Path)
    args = parser.parse_args()

    outroot = args.outroot
    summary_dir = args.summary_dir or outroot / "summaries"
    figure_dir = args.figure_dir or outroot / "figure"
    summary_dir.mkdir(parents=True, exist_ok=True)
    figure_dir.mkdir(parents=True, exist_ok=True)

    case_dirs = [
        path for path in sorted(outroot.iterdir())
        if path.is_dir() and (path / "stderr.txt").exists()
    ]
    rows = [case_summary(path) for path in case_dirs]
    stage_rows = aggregate_stage_rows(case_dirs)
    write_csv(rows, summary_dir / "summary.csv")
    write_stage_csv(stage_rows, summary_dir / "migration_stages.csv")
    write_summary_md(rows, stage_rows, summary_dir / "summary.md")
    write_figures(outroot, rows, stage_rows, figure_dir)


if __name__ == "__main__":
    main()
