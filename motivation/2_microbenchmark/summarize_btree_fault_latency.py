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


def parse_btree_stdout(path):
    text = read_text(path)
    row = {
        "elements_m": "",
        "lookups_m": "",
        "allocator_mb": "",
        "lookup_seconds": "",
    }
    patterns = {
        "elements_m": r"BTree Elements:\s+([0-9]+)M",
        "lookups_m": r"BTree #Lookups:\s+([0-9]+)M",
        "allocator_mb": r"Allocator:\s+([0-9]+)\s+MB",
        "lookup_seconds": r"got .* in ([0-9]+) seconds",
    }
    for key, pattern in patterns.items():
        match = re.search(pattern, text)
        if match:
            row[key] = match.group(1)
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


def write_summary(case_dir, experiment_root, summary_dir):
    summary_dir.mkdir(parents=True, exist_ok=True)
    host_meta = parse_key_values(experiment_root / "host.meta")
    exp_meta = parse_key_values(case_dir.parent / "experiment.meta")
    before_meta = parse_key_values(case_dir / "before.meta")
    time_row = parse_time(case_dir / "time.txt")
    btree_row = parse_btree_stdout(case_dir / "stdout.txt")
    deltas = vmstat_deltas(case_dir)
    rows = load_windows(case_dir / "fault_latency_windows")
    totals = aggregate_windows(rows)

    write_totals_csv(totals, summary_dir / "btree_fault_latency_histogram_totals.csv")
    write_tail_csv(rows, summary_dir / "btree_fault_latency_window_tail.csv")

    local_best = max_tail_window(rows, "local_large_vma_pages")
    remote_best = max_tail_window(rows, "remote_pages")
    demoted = deltas["pgdemote_direct"] + deltas["pgdemote_kswapd"]

    lines = [
        "# BTree fault latency histogram summary",
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
        f"- binary: `{exp_meta.get('btree', 'NA')}`",
        f"- OpenMP threads: `{exp_meta.get('omp_threads', 'NA')}`",
        f"- elements: `{btree_row.get('elements_m', 'NA')}`M, lookups: `{btree_row.get('lookups_m', 'NA')}`M",
        f"- allocator footprint printed by benchmark: `{btree_row.get('allocator_mb', 'NA')}` MB",
        "",
        "## 결과",
        "",
        f"- wall time: `{time_row['elapsed_wall_time']}`",
        f"- benchmark lookup phase seconds: `{btree_row.get('lookup_seconds', 'NA')}`",
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
        f"- local large-VMA max `>8192ms`: window `{local_best[1]}`, end `{local_best[2] / 1000.0:.1f}` s, `{local_best[4]:,}/{local_best[3]:,}` pages ({local_best[0]:.4f}%)",
        f"- remote max `>8192ms`: window `{remote_best[1]}`, end `{remote_best[2] / 1000.0:.1f}` s, `{remote_best[4]:,}/{remote_best[3]:,}` pages ({remote_best[0]:.4f}%)",
        "",
        "## Artifacts",
        "",
        f"- raw case dir: `{case_dir}`",
        f"- window CSV: `{summary_dir / 'btree_fault_latency_windows.csv'}`",
        f"- aggregate CSV: `{summary_dir / 'btree_fault_latency_histogram_totals.csv'}`",
        f"- tail CSV: `{summary_dir / 'btree_fault_latency_window_tail.csv'}`",
    ]
    output = summary_dir / "btree_fault_latency_summary_ko.md"
    output.write_text("\n".join(lines) + "\n")
    return output


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("case_dir", type=Path)
    parser.add_argument("--experiment-root", type=Path, required=True)
    parser.add_argument("--summary-dir", type=Path, required=True)
    args = parser.parse_args()

    if not args.case_dir.exists():
        raise SystemExit(f"missing case directory: {args.case_dir}")
    summary = write_summary(args.case_dir, args.experiment_root, args.summary_dir)
    print(summary)


if __name__ == "__main__":
    main()
