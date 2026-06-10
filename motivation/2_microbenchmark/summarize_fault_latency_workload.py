#!/usr/bin/env python3
import argparse
import csv
import re
from pathlib import Path


BUCKET_LABELS = [
    "<=128",
    "<=256",
    "<=512",
    "<=1024",
    "<=2048",
    "<=4096",
    "<=8192",
    ">8192",
]

SERIES_KEYS = [
    "local_pages",
    "local_large_vma_pages",
    "local_small_vma_pages",
    "remote_pages",
]


SERIES_LABELS = {
    "local_pages": "local",
    "local_large_vma_pages": "local large-VMA",
    "local_small_vma_pages": "local small-VMA",
    "remote_pages": "remote",
}

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


def read_text(path):
    if not path.exists():
        return ""
    return path.read_text(errors="replace")


def to_int(value, default=0):
    try:
        return int(str(value).strip().replace(",", ""))
    except (TypeError, ValueError):
        return default


def to_float(value, default=0.0):
    try:
        return float(str(value).strip().replace(",", ""))
    except (TypeError, ValueError):
        return default


def parse_key_values(path):
    values = {}
    for line in read_text(path).splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    return values


def parse_vmstat(path):
    values = {}
    for line in read_text(path).splitlines():
        parts = line.split()
        if len(parts) == 2:
            values[parts[0]] = to_int(parts[1])
    return values


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
            if "):" in stripped:
                row["elapsed_wall_time"] = stripped.rsplit("):", 1)[1].strip()
            else:
                row["elapsed_wall_time"] = stripped.split(":", 1)[1].strip()
        elif stripped.startswith("Maximum resident set size"):
            row["max_rss_kb"] = to_int(stripped.split(":", 1)[1])
        elif stripped.startswith("Voluntary context switches"):
            row["voluntary_context_switches"] = to_int(stripped.split(":", 1)[1])
        elif stripped.startswith("Involuntary context switches"):
            row["involuntary_context_switches"] = to_int(stripped.split(":", 1)[1])
    return row


def parse_gapbs_stdout(path):
    text = read_text(path)
    row = {
        "read_time_s": "",
        "generate_time_s": "",
        "build_time_s": "",
        "trial_time_s": "",
        "average_time_s": "",
        "graph_nodes": "",
        "graph_edges": "",
        "graph_degree": "",
    }
    patterns = {
        "read_time_s": r"Read Time:\s+([0-9.]+)",
        "generate_time_s": r"Generate Time:\s+([0-9.]+)",
        "build_time_s": r"Build Time:\s+([0-9.]+)",
        "trial_time_s": r"Trial Time:\s+([0-9.]+)",
        "average_time_s": r"Average Time:\s+([0-9.]+)",
    }
    for key, pattern in patterns.items():
        match = re.search(pattern, text)
        if match:
            row[key] = match.group(1)
    match = re.search(
        r"Graph has\s+([0-9]+)\s+nodes and\s+([0-9]+)\s+undirected edges for degree:\s+([0-9]+)",
        text,
    )
    if match:
        row["graph_nodes"] = match.group(1)
        row["graph_edges"] = match.group(2)
        row["graph_degree"] = match.group(3)
    return row


def parse_histogram(path):
    data = {key: [0] * len(BUCKET_LABELS) for key in SERIES_KEYS}
    for line in read_text(path).splitlines():
        parts = line.split()
        if not parts or parts[0] not in SERIES_KEYS:
            continue
        values = [to_int(value) for value in parts[1:]]
        data[parts[0]] = values[: len(BUCKET_LABELS)]
    return data


def load_windows(window_dir):
    rows = []
    for hist_path in sorted(window_dir.glob("window_*.fault_latency_histograms")):
        stem = hist_path.name.removesuffix(".fault_latency_histograms")
        index = int(stem.split("_", 1)[1])
        meta = parse_key_values(window_dir / f"{stem}.meta")
        rows.append(
            {
                "index": index,
                "elapsed_ms": to_int(meta.get("elapsed_ms")),
                "data": parse_histogram(hist_path),
            }
        )
    return rows


def aggregate_windows(rows):
    totals = {key: [0] * len(BUCKET_LABELS) for key in SERIES_KEYS}
    for row in rows:
        for key in SERIES_KEYS:
            totals[key] = [
                current + value
                for current, value in zip(totals[key], row["data"][key])
            ]
    return totals


def choose_local_series(totals):
    if sum(totals.get("local_large_vma_pages", [])):
        return "local_large_vma_pages"
    return "local_pages"


def write_totals_csv(totals, output):
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["series", *BUCKET_LABELS, "total_pages", "gt8192_percent"])
        for series, values in totals.items():
            total = sum(values)
            tail_pct = values[-1] * 100.0 / total if total else 0.0
            writer.writerow([series, *values, total, f"{tail_pct:.6f}"])


def write_tail_csv(rows, output):
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(
            [
                "window_index",
                "elapsed_s",
                "series",
                "total_pages",
                "gt8192_pages",
                "gt8192_percent",
            ]
        )
        for row in rows:
            for series in SERIES_KEYS:
                values = row["data"][series]
                total = sum(values)
                tail_pct = values[-1] * 100.0 / total if total else 0.0
                writer.writerow(
                    [
                        row["index"],
                        f"{row['elapsed_ms'] / 1000.0:.3f}",
                        series,
                        total,
                        values[-1],
                        f"{tail_pct:.6f}",
                    ]
                )


def vmstat_deltas(case_dir):
    before = parse_vmstat(case_dir / "before.vmstat")
    after = parse_vmstat(case_dir / "after.vmstat")
    return {key: after.get(key, 0) - before.get(key, 0) for key in VMSTAT_KEYS}


def max_tail_window(rows, series):
    best = None
    for row in rows:
        values = row["data"][series]
        total = sum(values)
        pct = values[-1] * 100.0 / total if total else 0.0
        item = (pct, row["index"], row["elapsed_ms"], total, values[-1])
        if best is None or item > best:
            best = item
    return best or (0.0, 0, 0, 0, 0)


def format_hist_line(series, values):
    total = sum(values)
    tail_pct = values[-1] * 100.0 / total if total else 0.0
    return (
        f"- `{series}`: total `{total:,}` pages, "
        f"`>8192ms` `{values[-1]:,}` pages ({tail_pct:.4f}%)"
    )


def write_summary(case_dir, experiment_root, summary_dir, title, summary_basename):
    summary_dir.mkdir(parents=True, exist_ok=True)
    host_meta = parse_key_values(experiment_root / "host.meta")
    exp_meta = parse_key_values(case_dir.parent / "experiment.meta")
    before_meta = parse_key_values(case_dir / "before.meta")
    time_row = parse_time(case_dir / "time.txt")
    gapbs_row = parse_gapbs_stdout(case_dir / "stdout.txt")
    deltas = vmstat_deltas(case_dir)
    rows = load_windows(case_dir / "fault_latency_windows")
    totals = aggregate_windows(rows)

    write_totals_csv(totals, summary_dir / f"{summary_basename}_histogram_totals.csv")
    write_tail_csv(rows, summary_dir / f"{summary_basename}_window_tail.csv")

    local_series = choose_local_series(totals)
    local_best = max_tail_window(rows, local_series)
    remote_best = max_tail_window(rows, "remote_pages")
    demoted = deltas["pgdemote_direct"] + deltas["pgdemote_kswapd"]
    stdout_tail = "\n".join(read_text(case_dir / "stdout.txt").splitlines()[-20:])

    lines = [
        f"# {title}",
        "",
        "## 설정",
        "",
        f"- kernel: `{host_meta.get('kernel', 'NA')}`",
        f"- VM memory: fast/local `{host_meta.get('fast_mem', 'NA')}`, slow `{host_meta.get('slow_mem', 'NA')}`, slow mode `{host_meta.get('slow_memory_mode', 'NA')}`",
        f"- host backing: fast node `{host_meta.get('fast_host_node', 'NA')}`, slow node `{host_meta.get('slow_host_node', 'NA')}`",
        f"- CPU placement: host CPUs `{host_meta.get('host_cpus', 'NA')}`, guest CPUs `{host_meta.get('guest_cpus', 'NA')}`, workload `numactl --cpunodebind={exp_meta.get('cpu_node', 'NA')}`",
        f"- NUMA balancing: `{before_meta.get('numa_balancing', 'NA')}`, MGLRU `{before_meta.get('lru_gen_enabled', 'NA')}`, demotion `{before_meta.get('demotion_enabled', 'NA')}`",
        f"- scan: size `{before_meta.get('scan_size_mb', 'NA')}` MB, period-min `{before_meta.get('scan_period_min_ms', 'NA')}` ms",
        f"- local fault sample rate: `{before_meta.get('local_fault_rate', 'NA')}`, histogram window `{exp_meta.get('fault_latency_window_seconds', 'NA')}` s",
        "",
        "## 워크로드",
        "",
        f"- label: `{exp_meta.get('workload_label', host_meta.get('workload_label', 'NA'))}`",
        f"- command: `{exp_meta.get('workload_command', host_meta.get('workload_command', 'NA'))}`",
        f"- OpenMP threads: `{exp_meta.get('omp_threads', 'NA')}`",
        f"- graph: nodes `{gapbs_row.get('graph_nodes') or 'NA'}`, undirected edges `{gapbs_row.get('graph_edges') or 'NA'}`, degree `{gapbs_row.get('graph_degree') or 'NA'}`",
        f"- GAPBS times: read `{gapbs_row.get('read_time_s') or 'NA'}` s, generate `{gapbs_row.get('generate_time_s') or 'NA'}` s, build `{gapbs_row.get('build_time_s') or 'NA'}` s, trial `{gapbs_row.get('trial_time_s') or 'NA'}` s, average `{gapbs_row.get('average_time_s') or 'NA'}` s",
        "",
        "## 결과",
        "",
        f"- wall time: `{time_row['elapsed_wall_time']}`",
        f"- user/system CPU time: `{time_row['user_cpu_s']:.2f}` s / `{time_row['system_cpu_s']:.2f}` s",
        f"- max RSS: `{time_row['max_rss_kb'] / 1024 / 1024:.2f}` GiB",
        f"- context switches: voluntary `{time_row['voluntary_context_switches']:,}`, involuntary `{time_row['involuntary_context_switches']:,}`",
        f"- NUMA hint faults: `{deltas['numa_hint_faults']:,}` total, `{deltas['numa_hint_faults_local']:,}` local",
        f"- migrated/promoted pages: `numa_pages_migrated={deltas['numa_pages_migrated']:,}`, `pgpromote_success={deltas['pgpromote_success']:,}`",
        f"- demoted pages: `{demoted:,}` (`pgdemote_direct={deltas['pgdemote_direct']:,}`, `pgdemote_kswapd={deltas['pgdemote_kswapd']:,}`)",
        f"- recorded windows: `{len(rows)}`",
        "",
        "## Histogram aggregate",
        "",
        *[format_hist_line(series, totals[series]) for series in SERIES_KEYS],
        "",
        "## Tail windows",
        "",
        f"- {SERIES_LABELS[local_series]} max `>8192ms`: window `{local_best[1]}`, end `{local_best[2] / 1000.0:.1f}` s, `{local_best[4]:,}/{local_best[3]:,}` pages ({local_best[0]:.4f}%)",
        f"- remote max `>8192ms`: window `{remote_best[1]}`, end `{remote_best[2] / 1000.0:.1f}` s, `{remote_best[4]:,}/{remote_best[3]:,}` pages ({remote_best[0]:.4f}%)",
        "",
        "## Stdout tail",
        "",
        "```text",
        stdout_tail,
        "```",
        "",
        "## Artifacts",
        "",
        f"- raw case dir: `{case_dir}`",
        f"- window CSV: `{summary_dir / f'{summary_basename}_windows.csv'}`",
        f"- percentile CSV: `{summary_dir / f'{summary_basename}_window_percentile_buckets.csv'}`",
        f"- aggregate CSV: `{summary_dir / f'{summary_basename}_histogram_totals.csv'}`",
        f"- tail CSV: `{summary_dir / f'{summary_basename}_window_tail.csv'}`",
    ]
    output = summary_dir / f"{summary_basename}_summary_ko.md"
    output.write_text("\n".join(lines) + "\n")
    return output


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("case_dir", type=Path)
    parser.add_argument("--experiment-root", type=Path, required=True)
    parser.add_argument("--summary-dir", type=Path, required=True)
    parser.add_argument("--summary-basename", default="fault_latency_workload")
    parser.add_argument("--title", default="Fault latency workload summary")
    args = parser.parse_args()

    if not args.case_dir.exists():
        raise SystemExit(f"missing case directory: {args.case_dir}")
    summary = write_summary(
        args.case_dir,
        args.experiment_root,
        args.summary_dir,
        args.title,
        args.summary_basename,
    )
    print(summary)


if __name__ == "__main__":
    main()
