#!/usr/bin/env bash
set -euo pipefail

OUTROOT="${OUTROOT:-/root/gapbs-pr-bc-cap8-16-rerun}"
RUNNER="${RUNNER:-/root/scripts/run_local_util_adapt_experiment.sh}"
GRAPH="${GRAPH:-/root/gapbs_graphs/kron_g28.sg}"
TRIALS="${TRIALS:-8}"
WINDOW_SEC="${WINDOW_SEC:-5}"
TIMEOUT_SEC="${TIMEOUT_SEC:-3600}"
OMP_THREADS="${OMP_THREADS:-32}"

mkdir -p "${OUTROOT}"

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "${OUTROOT}/orchestrator.log"
}

read_optional() {
  local path="$1"
  [[ -e "${path}" ]] && cat "${path}" || true
}

require_file() {
  local path="$1"
  if [[ ! -e "${path}" ]]; then
    log "missing required file: ${path}"
    exit 1
  fi
}

require_file "${RUNNER}"
require_file /root/pr
require_file /root/bc
require_file "${GRAPH}"
chmod +x "${RUNNER}" /root/pr /root/bc

if [[ -e /sys/kernel/mm/lru_gen/enabled ]]; then
  echo 0x0007 > /sys/kernel/mm/lru_gen/enabled || true
fi
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null || true

{
  echo "uname=$(uname -a)"
  echo "lru_gen_enabled=$(read_optional /sys/kernel/mm/lru_gen/enabled | tr -d '\n')"
  echo "graph=${GRAPH}"
  echo "graph_size_bytes=$(stat -c %s "${GRAPH}")"
  echo "trials=${TRIALS}"
  echo "window_sec=${WINDOW_SEC}"
  echo "timeout_sec=${TIMEOUT_SEC}"
  echo "omp_threads=${OMP_THREADS}"
  echo "scan_size_mb=256"
  echo "scan_period_min_ms=1000"
  echo "fast_scan=0"
  echo "hot_threshold_ms=0"
  echo "off_semantics=node_capacity_only_node_balancing_0_cgroup_demotion_0_global_demotion_0"
} > "${OUTROOT}/experiment_config.txt"

run_case() {
  local workload="$1"
  local cap_label="$2"
  local cap_pages="$3"
  local policy="$4"
  local outdir="${OUTROOT}/${workload}-${cap_label}/${policy}"
  local workload_cmd=()
  local demotion=1
  local global_demotion=1
  local global_target="0 1"

  mkdir -p "${outdir}"

  case "${workload}" in
    pr)
      workload_cmd=(/root/pr -f "${GRAPH}" -i20 -t1e-4 -n "${TRIALS}")
      ;;
    bc)
      workload_cmd=(/root/bc -f "${GRAPH}" -i1 -n "${TRIALS}")
      ;;
    *)
      log "unknown workload ${workload}"
      exit 2
      ;;
  esac

  if [[ "${policy}" == "off" ]]; then
    demotion=0
    global_demotion=0
    global_target=""
  fi

  log "start workload=${workload} cap=${cap_label} policy=${policy}"
  sync || true
  echo 3 > /proc/sys/vm/drop_caches || true

  "${RUNNER}" \
    --outdir "${outdir}" \
    --run-id "${workload}-${cap_label}-${policy}" \
    --cgroup-name "gapbs_${workload}_${cap_label}_${policy}_$$" \
    --policy "${policy}" \
    --capacity-node 0 \
    --capacity-pages "${cap_pages}" \
    --node-balancing 2 \
    --kswapd-demotion "${demotion}" \
    --global-numa-balancing 0 \
    --global-demotion-enabled "${global_demotion}" \
    --global-demotion-target "${global_target}" \
    --scan-size-mb 256 \
    --scan-period-min-ms 1000 \
    --fast-scan 0 \
    --hot-threshold-ms 0 \
    --mglru 0x0007 \
    --cpuset-cpus 0-31 \
    --cpuset-mems 0,1 \
    --omp-threads "${OMP_THREADS}" \
    --timeout-sec "${TIMEOUT_SEC}" \
    --window-sec "${WINDOW_SEC}" \
    --threshold-pct 80 \
    --consecutive 3 \
    --min-pte-updates 1000 \
    --remote-threshold-pct 20 \
    --remote-consecutive 3 \
    --min-hint-faults 1000 \
    --local-fault-sample-pct 10 \
    --eval-lag prev \
    -- \
    "${workload_cmd[@]}"

  log "done workload=${workload} cap=${cap_label} policy=${policy}"
}

for workload in pr bc; do
  for cap in 8g 16g; do
    case "${cap}" in
      8g) cap_pages=2097152 ;;
      16g) cap_pages=4194304 ;;
    esac
    for policy in off on ours; do
      run_case "${workload}" "${cap}" "${cap_pages}" "${policy}"
    done
  done
done

python3 - <<'PY' "${OUTROOT}/summary.csv" "${OUTROOT}"
import csv
import re
import sys
from pathlib import Path

summary = Path(sys.argv[1])
root = Path(sys.argv[2])

def read_kv(path):
    data = {}
    if not path.exists():
        return data
    for line in path.read_text(errors="replace").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            data[k.strip()] = v.strip()
    return data

def parse_stdout(path):
    read_s = ""
    avg_s = ""
    trials = []
    if not path.exists():
        return read_s, avg_s, trials
    for line in path.read_text(errors="replace").splitlines():
        m = re.search(r"Read Time:\s*([0-9.]+)", line)
        if m:
            read_s = m.group(1)
        m = re.search(r"Trial Time:\s*([0-9.]+)", line)
        if m:
            trials.append(m.group(1))
        m = re.search(r"Average Time:\s*([0-9.]+)", line)
        if m:
            avg_s = m.group(1)
    return read_s, avg_s, trials

def vmstat_delta(before, after, key):
    def read(path):
        vals = {}
        if not path.exists():
            return vals
        for line in path.read_text(errors="replace").splitlines():
            fields = line.split()
            if len(fields) >= 2:
                try:
                    vals[fields[0]] = int(fields[1])
                except ValueError:
                    pass
        return vals
    b = read(before)
    a = read(after)
    return a.get(key, 0) - b.get(key, 0)

def controller_stop(path):
    if not path.exists():
        return "", "", "", "", ""
    rows = list(csv.DictReader(path.open()))
    for row in rows:
        if row.get("event") == "stop":
            return (
                row.get("elapsed_ms", ""),
                row.get("window", ""),
                row.get("stop_reason", ""),
                row.get("access_pct", ""),
                row.get("remote_pct", ""),
            )
    return "", "", "", "", ""

rows = []
for case_dir in sorted(root.glob("*-*g/*")):
    parts = case_dir.parent.name.split("-")
    if len(parts) < 2:
        continue
    workload = parts[0]
    cap = parts[1]
    policy = case_dir.name
    status = read_kv(case_dir / "status.txt")
    cfg = read_kv(case_dir / "run_config.txt")
    read_s, avg_s, trials = parse_stdout(case_dir / "workload.stdout.log")
    stop_ms, stop_window, stop_reason, local_pct, remote_pct = controller_stop(case_dir / "controller.csv")
    rows.append({
        "workload": workload,
        "cap": cap,
        "policy": policy,
        "returncode": status.get("returncode", ""),
        "elapsed_s": status.get("elapsed_s", ""),
        "read_s": read_s,
        "avg_trial_s": avg_s,
        "stop_ms": stop_ms,
        "stop_window": stop_window,
        "stop_reason": stop_reason,
        "stop_local_pct": local_pct,
        "stop_remote_pct": remote_pct,
        "capacity_pages": cfg.get("capacity_pages", ""),
        "node_balancing_on": cfg.get("node_balancing_on", ""),
        "kswapd_demotion_on": cfg.get("kswapd_demotion_on", ""),
        "global_demotion_enabled": cfg.get("global_demotion_enabled", ""),
        "numa_hint_faults": vmstat_delta(case_dir / "vmstat.before", case_dir / "vmstat.after", "numa_hint_faults"),
        "pgpromote_success": vmstat_delta(case_dir / "vmstat.before", case_dir / "vmstat.after", "pgpromote_success"),
        "pgdemote_kswapd": vmstat_delta(case_dir / "vmstat.before", case_dir / "vmstat.after", "pgdemote_kswapd"),
        "pgdemote_direct": vmstat_delta(case_dir / "vmstat.before", case_dir / "vmstat.after", "pgdemote_direct"),
        **{f"trial{i+1}_s": v for i, v in enumerate(trials)},
    })

fieldnames = [
    "workload", "cap", "policy", "returncode", "elapsed_s", "read_s", "avg_trial_s",
    "stop_ms", "stop_window", "stop_reason", "stop_local_pct", "stop_remote_pct",
    "capacity_pages", "node_balancing_on", "kswapd_demotion_on", "global_demotion_enabled",
    "numa_hint_faults", "pgpromote_success", "pgdemote_kswapd", "pgdemote_direct",
]
for i in range(1, 9):
    fieldnames.append(f"trial{i}_s")

with summary.open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(rows)
PY

log "all cases complete; summary=${OUTROOT}/summary.csv"
