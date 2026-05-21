#!/usr/bin/env bash
set -euo pipefail

OUTROOT="${OUTROOT:-/root/bc-ours179-window10-20}"
RUNNER="${RUNNER:-/root/scripts/run_local_util_adapt_experiment.sh}"
GRAPH="${GRAPH:-/root/gapbs_graphs/kron_g28.sg}"
TRIALS="${TRIALS:-8}"
TIMEOUT_SEC="${TIMEOUT_SEC:-3600}"
OMP_THREADS="${OMP_THREADS:-32}"

mkdir -p "${OUTROOT}"

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "${OUTROOT}/orchestrator.log"
}

require_file() {
  local path="$1"
  if [[ ! -e "${path}" ]]; then
    log "missing required file: ${path}"
    exit 1
  fi
}

require_file "${RUNNER}"
require_file /root/bc
require_file "${GRAPH}"
chmod +x "${RUNNER}" /root/bc

if [[ -e /sys/kernel/mm/lru_gen/enabled ]]; then
  echo 0x0007 > /sys/kernel/mm/lru_gen/enabled || true
fi
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null || true

{
  echo "uname=$(uname -a)"
  echo "lru_gen_enabled=$(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null || true)"
  echo "graph=${GRAPH}"
  echo "graph_size_bytes=$(stat -c %s "${GRAPH}")"
  echo "trials=${TRIALS}"
  echo "timeout_sec=${TIMEOUT_SEC}"
  echo "omp_threads=${OMP_THREADS}"
  echo "policy=ours_only"
  echo "workload=bc"
  echo "scan_size_mb=256"
  echo "scan_period_min_ms=1000"
  echo "fast_scan=0"
  echo "hot_threshold_ms=0"
} > "${OUTROOT}/experiment_config.txt"

run_ours() {
  local cap_label="$1"
  local cap_pages="$2"
  local window_sec="$3"
  local outdir="${OUTROOT}/bc-${cap_label}-w${window_sec}/ours"

  mkdir -p "${outdir}"
  log "start workload=bc cap=${cap_label} window=${window_sec}s policy=ours"
  sync || true
  echo 3 > /proc/sys/vm/drop_caches || true

  "${RUNNER}" \
    --outdir "${outdir}" \
    --run-id "bc-${cap_label}-w${window_sec}-ours" \
    --cgroup-name "gapbs_ours179_bc_${cap_label}_w${window_sec}_$$" \
    --policy ours \
    --capacity-node 0 \
    --capacity-pages "${cap_pages}" \
    --node-balancing 2 \
    --kswapd-demotion 1 \
    --global-numa-balancing 0 \
    --global-demotion-enabled 1 \
    --global-demotion-target "0 1" \
    --scan-size-mb 256 \
    --scan-period-min-ms 1000 \
    --fast-scan 0 \
    --hot-threshold-ms 0 \
    --mglru 0x0007 \
    --cpuset-cpus 0-31 \
    --cpuset-mems 0,1 \
    --omp-threads "${OMP_THREADS}" \
    --timeout-sec "${TIMEOUT_SEC}" \
    --window-sec "${window_sec}" \
    --threshold-pct 80 \
    --consecutive 3 \
    --min-pte-updates 1000 \
    --remote-threshold-pct 20 \
    --remote-consecutive 3 \
    --min-hint-faults 1000 \
    --local-fault-sample-pct 10 \
    --eval-lag prev \
    -- \
    /root/bc -f "${GRAPH}" -i1 -n "${TRIALS}"

  log "done workload=bc cap=${cap_label} window=${window_sec}s policy=ours"
}

run_ours 8g 2097152 10
run_ours 16g 4194304 10
run_ours 8g 2097152 20
run_ours 16g 4194304 20

python3 - <<'PY' "${OUTROOT}/summary.csv" "${OUTROOT}"
import csv
import re
import sys
from pathlib import Path

summary = Path(sys.argv[1])
root = Path(sys.argv[2])

def read_kv(path):
    data = {}
    if path.exists():
        for line in path.read_text(errors="replace").splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                data[key.strip()] = value.strip()
    return data

def parse_stdout(path):
    read_s = ""
    avg_s = ""
    trials = []
    if path.exists():
        for line in path.read_text(errors="replace").splitlines():
            match = re.search(r"Read Time:\s*([0-9.]+)", line)
            if match:
                read_s = match.group(1)
            match = re.search(r"Trial Time:\s*([0-9.]+)", line)
            if match:
                trials.append(match.group(1))
            match = re.search(r"Average Time:\s*([0-9.]+)", line)
            if match:
                avg_s = match.group(1)
    return read_s, avg_s, trials

def read_vm(path):
    data = {}
    if path.exists():
        for line in path.read_text(errors="replace").splitlines():
            fields = line.split()
            if len(fields) >= 2:
                try:
                    data[fields[0]] = int(fields[1])
                except ValueError:
                    pass
    return data

def delta(case_dir, key):
    before = read_vm(case_dir / "vmstat.before")
    after = read_vm(case_dir / "vmstat.after")
    return after.get(key, 0) - before.get(key, 0)

def stop_info(path):
    if not path.exists():
        return "", "", "", "", ""
    with path.open(newline="") as handle:
        for row in csv.DictReader(handle):
            if row.get("event") in ("off", "stop"):
                return (
                    row.get("elapsed_ms", ""),
                    row.get("window", ""),
                    row.get("stop_reason", ""),
                    row.get("access_pct", ""),
                    row.get("remote_ratio_pct", ""),
                )
    return "", "", "", "", ""

rows = []
for case_dir in sorted(root.glob("bc-*g-w*/ours")):
    name = case_dir.parent.name
    match = re.fullmatch(r"bc-(8g|16g)-w([0-9]+)", name)
    if not match:
        continue
    cap, window_sec = match.groups()
    cfg = read_kv(case_dir / "run_config.txt")
    status = read_kv(case_dir / "status.txt")
    read_s, avg_s, trials = parse_stdout(case_dir / "workload.stdout.log")
    stop_ms, stop_window, stop_reason, stop_local_pct, stop_remote_pct = stop_info(case_dir / "controller.csv")
    row = {
        "workload": "bc",
        "cap": cap,
        "window_sec": window_sec,
        "policy": "ours",
        "returncode": status.get("returncode", ""),
        "elapsed_s": status.get("elapsed_s", ""),
        "read_s": read_s,
        "avg_trial_s": avg_s,
        "stop_ms": stop_ms,
        "stop_window": stop_window,
        "stop_reason": stop_reason,
        "stop_local_pct": stop_local_pct,
        "stop_remote_pct": stop_remote_pct,
        "capacity_pages": cfg.get("capacity_pages", ""),
        "kswapd_demotion_on": cfg.get("kswapd_demotion_on", ""),
        "global_demotion_enabled": cfg.get("global_demotion_enabled", ""),
        "numa_hint_faults": delta(case_dir, "numa_hint_faults"),
        "pgpromote_success": delta(case_dir, "pgpromote_success"),
        "pgdemote_kswapd": delta(case_dir, "pgdemote_kswapd"),
        "pgdemote_direct": delta(case_dir, "pgdemote_direct"),
    }
    for idx, value in enumerate(trials, 1):
        row[f"trial{idx}_s"] = value
    rows.append(row)

fields = [
    "workload", "cap", "window_sec", "policy", "returncode",
    "elapsed_s", "read_s", "avg_trial_s", "stop_ms", "stop_window",
    "stop_reason", "stop_local_pct", "stop_remote_pct", "capacity_pages",
    "kswapd_demotion_on", "global_demotion_enabled", "numa_hint_faults",
    "pgpromote_success", "pgdemote_kswapd", "pgdemote_direct",
] + [f"trial{i}_s" for i in range(1, 9)]

summary.parent.mkdir(parents=True, exist_ok=True)
with summary.open("w", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=fields)
    writer.writeheader()
    writer.writerows(rows)
PY

log "all BC window cases complete; summary=${OUTROOT}/summary.csv"
