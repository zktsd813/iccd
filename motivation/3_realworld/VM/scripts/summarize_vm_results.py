#!/usr/bin/env python3
"""Summarize VM32 local-size real-world experiment results."""

from __future__ import annotations

import argparse
import csv
import re
from pathlib import Path


PAGE_SIZE = 4096
GIB = 1024**3


FIELDS = [
    "local_size_gib",
    "workload",
    "config",
    "returncode",
    "elapsed_s",
    "max_rss_kb",
    "promoted_GiB",
    "demoted_GiB",
    "numa_hint_faults",
    "numa_pte_updates",
    "pgpromote_candidate",
    "pgpromote_candidate_nrl",
    "pgpromote_candidate_demoted",
    "pgpromote_success",
    "pgdemote_kswapd",
    "pgdemote_direct",
    "before_numa_balancing",
    "after_numa_balancing",
    "before_migration_enabled",
    "after_migration_enabled",
    "before_lru_gen_enabled",
    "after_lru_gen_enabled",
    "before_demotion_enabled",
    "after_demotion_enabled",
    "before_demotion_target",
    "after_demotion_target",
    "before_thp_enabled",
    "after_thp_enabled",
    "before_thp_defrag",
    "after_thp_defrag",
    "thp_mode",
    "thp_defrag",
    "before_scan_size_mb",
    "after_scan_size_mb",
    "before_scan_period_min_ms",
    "after_scan_period_min_ms",
    "before_local_fault_rate",
    "after_local_fault_rate",
    "before_local_fault_scan_size_mb",
    "after_local_fault_scan_size_mb",
    "before_local_fault_scan_period_ms",
    "after_local_fault_scan_period_ms",
    "avg_trial_s",
    "read_s",
    "graph500_teps",
    "ycsb_throughput_ops",
    "redis_last_ops_per_sec",
    "silo_agg_throughput_ops",
    "faster_ops_sec",
    "gapbs_graph_mode",
    "gapbs_graph_scale",
    "gapbs_graph_path",
    "graph_build_included",
    "pr_trials",
    "bc_trials",
    "pr_iterations",
    "bc_iterations",
    "silo_scale_factor",
    "silo_ops_per_worker",
    "silo_threads",
    "liblinear_dataset",
    "liblinear_solver",
    "liblinear_threads",
    "controller_enabled",
    "controller_policy",
    "controller_window_sec",
    "controller_cycle_window_min_sec",
    "controller_cycle_window_max_sec",
    "controller_effective_window_sec",
    "controller_local_rate",
    "controller_local_fault_scan_period_ms",
    "controller_local_fault_scan_size_mb",
    "controller_min_local_pages",
    "controller_min_remote_pages",
    "controller_start_consecutive",
    "controller_start_capacity_margin_pct",
    "controller_stop_capacity_ratio_threshold",
    "controller_windows",
    "controller_off_events",
    "controller_on_events",
    "controller_first_stop_elapsed_s",
    "controller_first_stop_window",
    "controller_first_stop_reason",
    "controller_final_state",
    "controller_last_arbitration",
    "controller_csv",
    "command",
    "placement",
    "result_dir",
]


def read_kv(path: Path) -> dict[str, str]:
    vals: dict[str, str] = {}
    if not path.exists():
        return vals
    for line in path.read_text(errors="replace").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        vals[key] = value
    return vals


def read_vmstat(path: Path) -> dict[str, int]:
    vals: dict[str, int] = {}
    if not path.exists():
        return vals
    for line in path.read_text(errors="replace").splitlines():
        fields = line.split()
        if len(fields) != 2:
            continue
        try:
            vals[fields[0]] = int(fields[1])
        except ValueError:
            pass
    return vals


def vmstat_delta(case_dir: Path, key: str) -> int:
    before = read_vmstat(case_dir / "before.vmstat")
    after = read_vmstat(case_dir / "after.vmstat")
    return after.get(key, 0) - before.get(key, 0)


def parse_time_max_rss(path: Path) -> str:
    if not path.exists():
        return ""
    text = path.read_text(errors="replace")
    match = re.search(r"Maximum resident set size \(kbytes\):\s*([0-9]+)", text)
    return match.group(1) if match else ""


def parse_time_elapsed_seconds(path: Path) -> str:
    if not path.exists():
        return ""
    text = path.read_text(errors="replace")
    match = re.search(
        r"^\s*Elapsed \(wall clock\) time \([^)]*\):\s*"
        r"([0-9]+(?::[0-9]+){1,2}(?:\.[0-9]+)?)\s*$",
        text,
        re.MULTILINE,
    )
    if not match:
        return ""
    parts = match.group(1).split(":")
    try:
        if len(parts) == 2:
            seconds = int(parts[0]) * 60 + float(parts[1])
        elif len(parts) == 3:
            seconds = int(parts[0]) * 3600 + int(parts[1]) * 60 + float(parts[2])
        else:
            return ""
    except ValueError:
        return ""
    return f"{seconds:.6f}".rstrip("0").rstrip(".")


def parse_stdout(path: Path) -> dict[str, str]:
    text = path.read_text(errors="replace") if path.exists() else ""
    out = {
        "avg_trial_s": "",
        "read_s": "",
        "graph500_teps": "",
        "ycsb_throughput_ops": "",
        "redis_last_ops_per_sec": "",
        "silo_agg_throughput_ops": "",
        "faster_ops_sec": "",
    }
    match = re.search(r"Average Time:\s*([0-9.]+)", text)
    if match:
        out["avg_trial_s"] = match.group(1)
    match = re.search(r"Read Time:\s*([0-9.]+)", text)
    if match:
        out["read_s"] = match.group(1)
    matches = re.findall(r"\[OVERALL\],\s*Throughput\(ops/sec\),\s*([0-9.]+)", text)
    if matches:
        out["ycsb_throughput_ops"] = matches[-1]
    redis_matches = re.findall(r'"[^"]+","?([0-9.]+)"?', text)
    if redis_matches:
        out["redis_last_ops_per_sec"] = redis_matches[-1]
    teps_matches = re.findall(r"(?:TEPS|teps)[^0-9]*([0-9.eE+-]+)", text)
    if teps_matches:
        out["graph500_teps"] = teps_matches[-1]
    silo_matches = re.findall(r"agg_throughput:\s*([0-9.]+)\s*ops/sec", text)
    if silo_matches:
        out["silo_agg_throughput_ops"] = silo_matches[-1]
    faster_matches = re.findall(r"(?:Total\s+)?(?:Ops/sec|ops/sec)[^0-9]*([0-9,.]+)", text, flags=re.IGNORECASE)
    if faster_matches:
        out["faster_ops_sec"] = faster_matches[-1].replace(",", "")
    return out


def parse_controller_csv(case_dir: Path) -> dict[str, str]:
    path = case_dir / "controller" / "controller.csv"
    out = {
        "controller_windows": "",
        "controller_effective_window_sec": "",
        "controller_off_events": "",
        "controller_on_events": "",
        "controller_first_stop_elapsed_s": "",
        "controller_first_stop_window": "",
        "controller_first_stop_reason": "",
        "controller_final_state": "",
        "controller_last_arbitration": "",
        "controller_csv": str(path) if path.exists() else "",
    }
    if not path.exists():
        return out

    rows: list[dict[str, str]] = []
    with path.open(newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(row)

    if not rows:
        return out

    sample_rows = [row for row in rows if row.get("event") not in ("start", "exit")]
    off_rows = [row for row in rows if row.get("event") == "off"]
    on_rows = [row for row in rows if row.get("event") == "on"]
    final = sample_rows[-1] if sample_rows else rows[-1]

    windows = 0
    for row in sample_rows:
        try:
            windows = max(windows, int(row.get("window", "") or 0))
        except ValueError:
            pass

    effective_window_sec = ""
    if len(sample_rows) >= 2:
        try:
            first_ms = int(sample_rows[0].get("elapsed_ms", "") or 0)
            last_ms = int(sample_rows[-1].get("elapsed_ms", "") or 0)
            effective_window_sec = f"{(last_ms - first_ms) / (len(sample_rows) - 1) / 1000.0:.3f}"
        except ValueError:
            pass

    out.update(
        {
            "controller_windows": str(windows),
            "controller_effective_window_sec": effective_window_sec,
            "controller_off_events": str(len(off_rows)),
            "controller_on_events": str(len(on_rows)),
            "controller_final_state": final.get("controller_state", ""),
            "controller_last_arbitration": final.get("arbitration", ""),
        }
    )
    if off_rows:
        first = off_rows[0]
        out["controller_first_stop_window"] = first.get("window", "")
        out["controller_first_stop_reason"] = first.get("stop_reason", "")
        try:
            out["controller_first_stop_elapsed_s"] = (
                f"{int(first.get('elapsed_ms', '') or 0) / 1000.0:.3f}"
            )
        except ValueError:
            out["controller_first_stop_elapsed_s"] = ""
    return out


def local_size_from_name(name: str) -> str:
    match = re.match(r"local([0-9]+)$", name)
    return match.group(1) if match else ""


def iter_case_dirs(guest_results: Path) -> list[tuple[str, str, str, Path]]:
    cases: list[tuple[str, str, str, Path]] = []
    for first_dir in sorted(p for p in guest_results.iterdir() if p.is_dir()):
        local_size = local_size_from_name(first_dir.name)
        if local_size:
            config_dirs = sorted(p for p in first_dir.iterdir() if p.is_dir())
        else:
            config_dirs = [first_dir]
        for config_dir in config_dirs:
            config = config_dir.name
            for workload_dir in sorted(p for p in config_dir.iterdir() if p.is_dir()):
                if (workload_dir / "status.txt").exists() or (workload_dir / "run.config").exists():
                    cases.append((local_size, config, workload_dir.name, workload_dir))
    return cases


def summarize_case(local_size: str, config: str, workload: str, case_dir: Path) -> dict[str, str]:
    status = read_kv(case_dir / "status.txt")
    run_config = read_kv(case_dir / "run.config")
    before = read_kv(case_dir / "before.meta")
    after = read_kv(case_dir / "after.meta")
    controller = parse_controller_csv(case_dir)
    controller_enabled = run_config.get("controller_enabled", "0") == "1"
    stdout_path = case_dir / "controller" / "stdout.txt" if controller_enabled else case_dir / "workload.stdout.log"
    if not stdout_path.exists():
        stdout_path = case_dir / "workload.stdout.log"
    time_path = case_dir / "controller" / "time.txt" if controller_enabled else case_dir / "time.txt"
    if not time_path.exists():
        time_path = case_dir / "time.txt"
    stdout_metrics = parse_stdout(stdout_path)

    promoted_pages = vmstat_delta(case_dir, "pgpromote_success")
    demote_kswapd = vmstat_delta(case_dir, "pgdemote_kswapd")
    demote_direct = vmstat_delta(case_dir, "pgdemote_direct")
    demoted_pages = demote_kswapd + demote_direct

    row = {field: "" for field in FIELDS}
    row.update(
        {
            "workload": workload,
            "local_size_gib": run_config.get("local_size_gib", local_size),
            "config": config,
            "returncode": status.get("returncode", ""),
            "elapsed_s": (
                parse_time_elapsed_seconds(time_path)
                or status.get("elapsed_s", "")
            ),
            "max_rss_kb": parse_time_max_rss(time_path),
            "promoted_GiB": f"{promoted_pages * PAGE_SIZE / GIB:.6f}",
            "demoted_GiB": f"{demoted_pages * PAGE_SIZE / GIB:.6f}",
            "numa_hint_faults": str(vmstat_delta(case_dir, "numa_hint_faults")),
            "numa_pte_updates": str(vmstat_delta(case_dir, "numa_pte_updates")),
            "pgpromote_candidate": str(vmstat_delta(case_dir, "pgpromote_candidate")),
            "pgpromote_candidate_nrl": str(vmstat_delta(case_dir, "pgpromote_candidate_nrl")),
            "pgpromote_candidate_demoted": str(vmstat_delta(case_dir, "pgpromote_candidate_demoted")),
            "pgpromote_success": str(promoted_pages),
            "pgdemote_kswapd": str(demote_kswapd),
            "pgdemote_direct": str(demote_direct),
            "before_numa_balancing": before.get("numa_balancing", ""),
            "after_numa_balancing": after.get("numa_balancing", ""),
            "before_migration_enabled": before.get("migration_enabled", ""),
            "after_migration_enabled": after.get("migration_enabled", ""),
            "before_lru_gen_enabled": before.get("lru_gen_enabled", ""),
            "after_lru_gen_enabled": after.get("lru_gen_enabled", ""),
            "before_demotion_enabled": before.get("demotion_enabled", ""),
            "after_demotion_enabled": after.get("demotion_enabled", ""),
            "before_demotion_target": before.get("demotion_target", ""),
            "after_demotion_target": after.get("demotion_target", ""),
            "before_thp_enabled": before.get("thp_enabled", ""),
            "after_thp_enabled": after.get("thp_enabled", ""),
            "before_thp_defrag": before.get("thp_defrag", ""),
            "after_thp_defrag": after.get("thp_defrag", ""),
            "thp_mode": run_config.get("thp_mode", ""),
            "thp_defrag": run_config.get("thp_defrag", ""),
            "before_scan_size_mb": before.get("scan_size_mb", ""),
            "after_scan_size_mb": after.get("scan_size_mb", ""),
            "before_scan_period_min_ms": before.get("scan_period_min_ms", ""),
            "after_scan_period_min_ms": after.get("scan_period_min_ms", ""),
            "before_local_fault_rate": before.get("local_fault_rate", ""),
            "after_local_fault_rate": after.get("local_fault_rate", ""),
            "before_local_fault_scan_size_mb": before.get("local_fault_scan_size_mb", ""),
            "after_local_fault_scan_size_mb": after.get("local_fault_scan_size_mb", ""),
            "before_local_fault_scan_period_ms": before.get("local_fault_scan_period_ms", ""),
            "after_local_fault_scan_period_ms": after.get("local_fault_scan_period_ms", ""),
            "command": run_config.get("command", ""),
            "placement": run_config.get("placement", ""),
            "gapbs_graph_mode": run_config.get("gapbs_graph_mode", ""),
            "gapbs_graph_scale": run_config.get("gapbs_graph_scale", ""),
            "gapbs_graph_path": run_config.get("gapbs_graph_path", ""),
            "graph_build_included": run_config.get("graph_build_included", ""),
            "pr_trials": run_config.get("pr_trials", ""),
            "bc_trials": run_config.get("bc_trials", ""),
            "pr_iterations": run_config.get("pr_iterations", ""),
            "bc_iterations": run_config.get("bc_iterations", ""),
            "silo_scale_factor": run_config.get("silo_scale_factor", ""),
            "silo_ops_per_worker": run_config.get("silo_ops_per_worker", ""),
            "silo_threads": run_config.get("silo_threads", ""),
            "liblinear_dataset": run_config.get("liblinear_dataset", ""),
            "liblinear_solver": run_config.get("liblinear_solver", ""),
            "liblinear_threads": run_config.get("liblinear_threads", ""),
            "controller_enabled": run_config.get("controller_enabled", "0"),
            "controller_policy": run_config.get("controller_policy", ""),
            "controller_window_sec": run_config.get("controller_window_sec", ""),
            "controller_cycle_window_min_sec": run_config.get("controller_cycle_window_min_sec", ""),
            "controller_cycle_window_max_sec": run_config.get("controller_cycle_window_max_sec", ""),
            "controller_local_rate": run_config.get("controller_local_rate", ""),
            "controller_local_fault_scan_period_ms": run_config.get("controller_local_fault_scan_period_ms", ""),
            "controller_local_fault_scan_size_mb": run_config.get("controller_local_fault_scan_size_mb", ""),
            "controller_min_local_pages": run_config.get("controller_min_local_pages", ""),
            "controller_min_remote_pages": run_config.get("controller_min_remote_pages", ""),
            "controller_start_consecutive": run_config.get("controller_start_consecutive", ""),
            "controller_start_capacity_margin_pct": run_config.get(
                "controller_start_capacity_margin_pct", ""
            ),
            "controller_stop_capacity_ratio_threshold": run_config.get("controller_stop_capacity_ratio_threshold", ""),
            "result_dir": str(case_dir),
        }
    )
    row.update(stdout_metrics)
    row.update(controller)
    return row


def write_csv(rows: list[dict[str, str]], out: Path) -> None:
    with out.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)


def fmt_cell(value: str, default: str = "") -> str:
    return value if value not in ("", None) else default


def write_markdown(rows: list[dict[str, str]], out: Path) -> None:
    failed = [r for r in rows if r.get("returncode") not in ("", "0")]
    with out.open("w") as f:
        f.write("# VM32 Local-Size Summary\n\n")
        f.write(f"Rows: {len(rows)}\n\n")
        f.write(f"Failed or timed out: {len(failed)}\n\n")
        f.write(
            "| Local GiB | Workload | Config | RC | Elapsed s | Max RSS KiB | Promote GiB | "
            "Demote GiB | Hint Faults | PTE Updates | Promote Candidate | "
            "Promote Success |\n"
        )
        f.write(
            "| ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n"
        )
        for row in rows:
            f.write(
                "| {local} | {workload} | {config} | {rc} | {elapsed} | {rss} | "
                "{promote} | {demote} | {hints} | {pte} | "
                "{candidate} | {success} |\n".format(
                    local=fmt_cell(row["local_size_gib"], "NA"),
                    workload=row["workload"],
                    config=row["config"],
                    rc=fmt_cell(row["returncode"], "NA"),
                    elapsed=fmt_cell(row["elapsed_s"], "NA"),
                    rss=fmt_cell(row["max_rss_kb"], "NA"),
                    promote=fmt_cell(row["promoted_GiB"], "NA"),
                    demote=fmt_cell(row["demoted_GiB"], "NA"),
                    hints=fmt_cell(row["numa_hint_faults"], "NA"),
                    pte=fmt_cell(row["numa_pte_updates"], "NA"),
                    candidate=fmt_cell(row["pgpromote_candidate"], "NA"),
                    success=fmt_cell(row["pgpromote_success"], "NA"),
                )
            )
        if failed:
            f.write("\n## Failures\n\n")
            for row in failed:
                f.write(
                    f"- local{row.get('local_size_gib', '')}/{row['config']}/{row['workload']}: rc={row.get('returncode', '')}, "
                    f"dir={row.get('result_dir', '')}\n"
                )
        controller_rows = [r for r in rows if r.get("controller_enabled") == "1"]
        if controller_rows:
            f.write("\n## Controller Events\n\n")
            f.write(
                "| Local GiB | Workload | Config | Windows | Off Events | On Events | "
                "First Stop s | First Stop Window | Reason | Final State |\n"
            )
            f.write(
                "| ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | --- | --- |\n"
            )
            for row in controller_rows:
                f.write(
                    "| {local} | {workload} | {config} | {windows} | {off} | {on} | "
                    "{stop_s} | {stop_window} | {reason} | {state} |\n".format(
                        local=fmt_cell(row["local_size_gib"], "NA"),
                        workload=row["workload"],
                        config=row["config"],
                        windows=fmt_cell(row["controller_windows"], "NA"),
                        off=fmt_cell(row["controller_off_events"], "NA"),
                        on=fmt_cell(row["controller_on_events"], "NA"),
                        stop_s=fmt_cell(row["controller_first_stop_elapsed_s"], "NA"),
                        stop_window=fmt_cell(row["controller_first_stop_window"], "NA"),
                        reason=fmt_cell(row["controller_first_stop_reason"], "NA"),
                        state=fmt_cell(row["controller_final_state"], "NA"),
                    )
                )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--guest-results", required=True, type=Path)
    parser.add_argument("--outdir", required=True, type=Path)
    args = parser.parse_args()

    if not args.guest_results.exists():
        raise SystemExit(f"guest results not found: {args.guest_results}")

    args.outdir.mkdir(parents=True, exist_ok=True)
    rows = [
        summarize_case(local_size, config, workload, case_dir)
        for local_size, config, workload, case_dir in iter_case_dirs(args.guest_results)
    ]
    rows.sort(key=lambda r: (int(r["local_size_gib"] or 0), r["workload"], r["config"]))

    write_csv(rows, args.outdir / "summary.csv")
    write_markdown(rows, args.outdir / "summary.md")
    print(args.outdir / "summary.csv")
    print(args.outdir / "summary.md")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
